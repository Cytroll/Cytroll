import Foundation
import Combine

public final class RepositoryManager: ObservableObject {
    public static let shared = RepositoryManager()
    
    @Published public private(set) var sources: [Source] = []
    
    private let sourcesDir = "/var/jb/etc/apt/sources.list.d"
    private let cytrollSourcesFile = "/var/jb/etc/apt/sources.list.d/cytroll.list"
    private let coreBridge = CytrollCoreBridge.shared
    
    private init() {
        loadSources()
    }
    
    public func loadSources() {
        let fm = FileManager.default
        var loadedSources: [Source] = []
        
        if !fm.fileExists(atPath: sourcesDir) {
            try? fm.createDirectory(atPath: sourcesDir, withIntermediateDirectories: true, attributes: nil)
        }
        
        guard let files = try? fm.contentsOfDirectory(atPath: sourcesDir) else { return }
        
        for file in files {
            let path = "\(sourcesDir)/\(file)"
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            
            if file.hasSuffix(".list") {
                let lines = content.components(separatedBy: .newlines)
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("deb ") || trimmed.hasPrefix("deb-src ") {
                        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                        if parts.count >= 2 {
                            let url = String(parts[1])
                            loadedSources.append(Source(name: URL(string: url)?.host ?? url, url: url))
                        }
                    }
                }
            } else if file.hasSuffix(".sources") {
                // Deb822 format basic parser
                let blocks = content.components(separatedBy: "\n\n")
                for block in blocks {
                    let lines = block.components(separatedBy: .newlines)
                    for line in lines {
                        if line.hasPrefix("URIs: ") {
                            let url = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                            if !url.isEmpty {
                                loadedSources.append(Source(name: URL(string: url)?.host ?? url, url: url))
                            }
                        }
                    }
                }
            }
        }
        
        // Remove duplicates and sort
        var unique = [String: Source]()
        for s in loadedSources { unique[s.url] = s }
        
        DispatchQueue.main.async {
            self.sources = Array(unique.values).sorted(by: { $0.name.lowercased() < $1.name.lowercased() })
        }
    }
    
    public func addSource(url: String) {
        var cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanURL.hasSuffix("/") { cleanURL += "/" }
        
        if sources.contains(where: { $0.url == cleanURL }) {
            ConsoleManager.shared.log("Source \(cleanURL) already exists.")
            return
        }
        
        let newLine = "deb \(cleanURL) ./\n"
        
        let fm = FileManager.default
        if fm.fileExists(atPath: cytrollSourcesFile) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: cytrollSourcesFile)) {
                handle.seekToEndOfFile()
                if let data = newLine.data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            }
        } else {
            try? newLine.write(toFile: cytrollSourcesFile, atomically: true, encoding: .utf8)
        }
        
        ConsoleManager.shared.log("Added source: \(cleanURL). Updating APT...")
        
        // Run APT update using the bridge in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            _ = self.coreBridge.executeCommand(executable: "/var/jb/usr/bin/apt-get", arguments: ["update", "--allow-insecure-repositories"])
            self.loadSources()
        }
    }
}
