import Foundation
import Combine

public final class RepositoryManager: ObservableObject {
    public static let shared = RepositoryManager()
    
    @Published public private(set) var sources: [Source] = []
    @Published public private(set) var isRefreshing: Bool = false
    
    private var sourcesDir: String { RootlessPaths.sourcesListDir }
    private var cytrollSourcesFile: String { RootlessPaths.cytrollSourcesFile }
    private let coreBridge = CytrollCoreBridge.shared
    
    private init() {
        loadSources()
    }
    
    public func loadSources() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Warms the shared cache on first launch (whoever gets there
            // first pays for the parse); every other consumer just reads
            // the same result instead of re-parsing the same files again.
            PackageIndexStore.shared.ensureLoaded {
                DispatchQueue.global(qos: .userInitiated).async {
                    self?.loadSourcesSync()
                }
            }
        }
    }

    /// Synchronous worker — call only from a background thread. Reads the
    /// sources.list(.d) files, tallies real package counts, and publishes
    /// the result on the main thread before returning.
    private func loadSourcesSync() {
            let fm = FileManager.default
            var loadedSources: [Source] = []

            if !fm.fileExists(atPath: self.sourcesDir) {
                try? fm.createDirectory(atPath: self.sourcesDir, withIntermediateDirectories: true, attributes: nil)
            }

            guard let files = try? fm.contentsOfDirectory(atPath: self.sourcesDir) else { return }

            for file in files {
                let path = "\(self.sourcesDir)/\(file)"
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

            // Remove duplicates by URL
            var uniqueByURL = [String: Source]()
            for s in loadedSources { uniqueByURL[s.url] = s }

            // Real package counts: tally repo packages (from the shared
            // cache — no independent re-parse) by matching host.
            let repoPackages = PackageIndexStore.shared.repoPackagesSnapshot()
            var countsByHost = [String: Int]()
            for pkg in repoPackages {
                guard let sourceURL = pkg.sourceURL, let host = URL(string: sourceURL)?.host else { continue }
                countsByHost[host, default: 0] += 1
            }

            let finalSources = uniqueByURL.values.map { source -> Source in
                let host = URL(string: source.url)?.host ?? source.name
                let count = countsByHost[host] ?? 0
                return Source(name: source.name, url: source.url, iconURL: source.iconURL, packageCount: count)
            }.sorted { $0.name.lowercased() < $1.name.lowercased() }

            DispatchQueue.main.async {
                self.sources = finalSources
            }
    }

    /// Runs a real `apt-get update` through the root helper, then reloads
    /// sources/counts. Used by the pull-to-refresh gesture in Sources tab.
    public func refreshAll(completion: (() -> Void)? = nil) {
        guard !isRefreshing else { completion?(); return }
        isRefreshing = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            ConsoleManager.shared.log("Refreshing APT sources...")
            let success = self.coreBridge.executeAptGet(arguments: ["update", "--allow-insecure-repositories"])
            ConsoleManager.shared.log(success ? "Sources refreshed." : "Failed to refresh sources — check your connection.")

            // `apt-get update` just rewrote the on-disk `_Packages` files,
            // so the shared cache must be force-refreshed (not just
            // ensure-loaded) before recomputing per-source counts.
            PackageIndexStore.shared.refresh {
                self.loadSourcesSync()

                DispatchQueue.main.async {
                    self.isRefreshing = false
                    completion?()
                }
            }
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
            _ = self.coreBridge.executeAptGet(arguments: ["update", "--allow-insecure-repositories"])
            // New source's index just landed on disk — force a re-parse
            // rather than `loadSources()`'s ensure-loaded (which would
            // no-op since the cache is already warm from a prior load).
            PackageIndexStore.shared.refresh {
                self.loadSourcesSync()
            }
        }
    }
}
