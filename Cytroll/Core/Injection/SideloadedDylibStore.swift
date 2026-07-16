import Foundation
import Combine

/// A tweak dylib the user picked directly (e.g. via Files), not installed
/// through apt/TweakInject. Cytroll copies it into its own managed
/// storage — so the originally-picked file (often a security-scoped,
/// possibly-temporary URL) isn't needed afterward — then treats it
/// exactly like an apt-installed tweak for injection purposes via
/// `asTweakInfo`: same `AppInjectionManager` pipeline, same
/// `InjectionRecord` tracking, same multi-tweak-per-app rebuild logic.
public struct SideloadedDylib: Identifiable, Codable, Hashable {
    public var id: String { "sideload_\(uuid)" }
    public let uuid: String
    public var name: String
    public let managedDylibPath: String
    public let addedAt: Date

    public init(uuid: String = UUID().uuidString, name: String, managedDylibPath: String, addedAt: Date = Date()) {
        self.uuid = uuid
        self.name = name
        self.managedDylibPath = managedDylibPath
        self.addedAt = addedAt
    }

    /// Sideloaded dylibs never ship a MobileSubstrate `Filter` plist, so
    /// `filterBundleIDs` stays empty on purpose — there's no "candidate
    /// apps" auto-match for these; the target app is always picked
    /// explicitly by the user, same as real TrollFools.
    public var asTweakInfo: TweakInfo {
        TweakInfo(id: id, name: name, isEnabled: true, dylibPath: managedDylibPath, filterBundleIDs: [])
    }
}

/// JSON-backed registry of `SideloadedDylib`s at
/// `RootlessPaths.sideloadedDylibsFile`. Managed dylib files live under
/// `RootlessPaths.sideloadedDylibsDir/<uuid>/`.
public final class SideloadedDylibStore: ObservableObject {
    public static let shared = SideloadedDylibStore()

    @Published public private(set) var items: [SideloadedDylib] = []

    private let ioQueue = DispatchQueue(label: "com.cytroll.sideloadedDylibStore")
    private let fm = FileManager.default

    private init() {
        load()
    }

    private func load() {
        ioQueue.sync {
            guard let data = fm.contents(atPath: RootlessPaths.sideloadedDylibsFile),
                  let decoded = try? JSONDecoder().decode([SideloadedDylib].self, from: data) else {
                return
            }
            DispatchQueue.main.async { self.items = decoded }
        }
    }

    private func persist(_ items: [SideloadedDylib]) {
        if !fm.fileExists(atPath: RootlessPaths.cytrollStateDir) {
            try? fm.createDirectory(atPath: RootlessPaths.cytrollStateDir, withIntermediateDirectories: true)
        }
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: URL(fileURLWithPath: RootlessPaths.sideloadedDylibsFile), options: .atomic)
    }

    /// Copies `sourceURL` (typically a security-scoped URL from
    /// `.fileImporter`) into Cytroll's own managed storage and registers
    /// it. Does real file I/O — call off the main thread.
    @discardableResult
    public func add(from sourceURL: URL, displayName: String?) -> Result<SideloadedDylib, Error> {
        let uuid = UUID().uuidString
        let dir = RootlessPaths.sideloadedDylibsDir + "/" + uuid
        let destPath = dir + "/" + sourceURL.lastPathComponent

        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
            if fm.fileExists(atPath: destPath) { try fm.removeItem(atPath: destPath) }
            try fm.copyItem(at: sourceURL, to: URL(fileURLWithPath: destPath))
        } catch {
            try? fm.removeItem(atPath: dir)
            return .failure(error)
        }

        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = trimmedName.isEmpty ? sourceURL.deletingPathExtension().lastPathComponent : trimmedName
        let item = SideloadedDylib(uuid: uuid, name: name, managedDylibPath: destPath)

        ioQueue.sync {
            var current = self.items
            current.append(item)
            self.persist(current)
            DispatchQueue.main.async { self.items = current }
        }
        return .success(item)
    }

    /// Removes a sideloaded dylib's registration and managed file, first
    /// auto-restoring any app it's currently injected into (same
    /// "never leave a dangling dylib reference" contract apt-tweak
    /// removal already gets via `TweakInjectionManager`/
    /// `AppInjectionManager.reconcileAfterTweakChanges`).
    public func remove(_ item: SideloadedDylib) {
        ioQueue.sync {
            var current = self.items
            current.removeAll { $0.id == item.id }
            self.persist(current)
            DispatchQueue.main.async { self.items = current }
        }

        let related = InjectionRecordStore.shared.records(forTweakID: item.id)
        if !related.isEmpty {
            AppInjectionManager.shared.restoreAll(related)
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let dir = (item.managedDylibPath as NSString).deletingLastPathComponent
            try? self.fm.removeItem(atPath: dir)
        }
    }

    public func item(withID id: String) -> SideloadedDylib? {
        items.first { $0.id == id }
    }
}
