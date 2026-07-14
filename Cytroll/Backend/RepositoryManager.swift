import Foundation
import Combine

public final class RepositoryManager: ObservableObject {
    public static let shared = RepositoryManager()
    
    @Published public private(set) var sources: [Source] = []
    
    private init() {
        loadDefaultSources()
    }
    
    private func loadDefaultSources() {
        // Production-like mock sources
        self.sources = [
            Source(name: "Chariz", url: "https://repo.chariz.com/", packageCount: 540),
            Source(name: "Havoc", url: "https://havoc.app/", packageCount: 890),
            Source(name: "BigBoss", url: "http://apt.thebigboss.org/repofiles/cydia/", packageCount: 15430),
            Source(name: "ElleKit", url: "https://ellekit.space/", packageCount: 3)
        ]
    }
    
    public func addSource(url: String) {
        // Safe addition mock
        let newSource = Source(name: "New Repository", url: url)
        sources.append(newSource)
    }
}
