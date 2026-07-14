import Foundation
import Combine

public final class PackagesViewModel: ObservableObject {
    @Published public private(set) var packages: [Package] = []
    @Published public var searchQuery: String = ""
    
    public init() {
        loadPackagesFromBackend()
    }
    
    public var filteredPackages: [Package] {
        if searchQuery.isEmpty {
            return packages
        } else {
            return packages.filter { 
                $0.name.localizedCaseInsensitiveContains(searchQuery) || 
                $0.id.localizedCaseInsensitiveContains(searchQuery) 
            }
        }
    }
    
    public func loadPackagesFromBackend() {
        // Background parsing to ensure UI does not freeze during heavy IO parsing
        DispatchQueue.global(qos: .userInitiated).async {
            // Load installed packages from the dpkg status file natively
            var loaded = DpkgStatusParser.shared.parseInstalledPackages()
            
            // Add packages from the APT repos natively
            let repoPackages = AptIndexParser.shared.parseRepoPackages()
            loaded.append(contentsOf: repoPackages)
            
            // Remove duplicates by ID (e.g., if a package is both installed and in a repo)
            var uniqueDict = [String: Package]()
            for pkg in loaded {
                uniqueDict[pkg.id] = pkg
            }
            let uniquePackages = Array(uniqueDict.values)
            
            // If the status file doesn't exist (e.g. running on simulator), fallback to safe mock data
            let finalData = uniquePackages.isEmpty ? self.getFallbackMockData() : uniquePackages
            
            DispatchQueue.main.async {
                self.packages = finalData.sorted { $0.name.lowercased() < $1.name.lowercased() }
            }
        }
    }
    
    private func getFallbackMockData() -> [Package] {
        return [
            Package(id: "org.coolstar.sileo", name: "Sileo", version: "2.5", author: "Sileo Team", architecture: "iphoneos-arm64", description: "A modern, fast, and beautiful package manager."),
            Package(id: "com.spark.snowboard", name: "SnowBoard", version: "1.5.21", author: "SparkDev", architecture: "iphoneos-arm64", description: "A lightweight spiritual successor to WinterBoard."),
            Package(id: "space.ellekit.mac", name: "ElleKit", version: "1.0", author: "evelyne", architecture: "iphoneos-arm64", description: "A modern tweak injector for iOS 15+ rootless.")
        ]
    }
}
