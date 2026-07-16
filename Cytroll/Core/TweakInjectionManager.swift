import Foundation
import Combine

public struct TweakInfo: Identifiable, Hashable {
    public let id: String
    public let name: String
    public var isEnabled: Bool
    public let dylibPath: String
}

public final class TweakInjectionManager: ObservableObject {
    public static let shared = TweakInjectionManager()

    @Published public private(set) var installedTweaks: [TweakInfo] = []
    @Published public private(set) var isProcessing: Bool = false

    private let coreBridge = CytrollCoreBridge.shared
    private let console = ConsoleManager.shared

    private init() {
        refreshTweaks()
    }

    public func refreshTweaks() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let fm = FileManager.default
            var targetPath = RootlessPaths.tweakInjectDir

            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: targetPath, isDirectory: &isDir) || !isDir.boolValue {
                targetPath = RootlessPaths.mobileSubstrateDir
            }

            guard let files = try? fm.contentsOfDirectory(atPath: targetPath) else { return }

            var tweaksDict = [String: TweakInfo]()

            for file in files where file.hasSuffix(".dylib") || file.hasSuffix(".disabled") {
                let isEnabled = file.hasSuffix(".dylib")
                let baseName = file
                    .replacingOccurrences(of: ".dylib", with: "")
                    .replacingOccurrences(of: ".disabled", with: "")
                let path = targetPath + "/" + file

                if tweaksDict[baseName] == nil {
                    tweaksDict[baseName] = TweakInfo(
                        id: baseName, name: baseName, isEnabled: isEnabled, dylibPath: path
                    )
                }
            }

            let sorted = Array(tweaksDict.values).sorted { $0.name.lowercased() < $1.name.lowercased() }
            DispatchQueue.main.async { self.installedTweaks = sorted }
        }
    }

    public func toggleTweak(_ tweak: TweakInfo, enable: Bool, completion: @escaping (Bool) -> Void) {
        guard !isProcessing else { return }
        isProcessing = true

        console.log(enable ? "Enabling tweak: \(tweak.name)" : "Disabling tweak: \(tweak.name)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let basePath = tweak.dylibPath
                .replacingOccurrences(of: ".dylib", with: "")
                .replacingOccurrences(of: ".disabled", with: "")
            let targetDylib = enable ? "\(basePath).dylib" : "\(basePath).disabled"

            let currentPlist = tweak.dylibPath
                .replacingOccurrences(of: ".dylib", with: ".plist")
                .replacingOccurrences(of: ".disabled", with: ".plist")
            let targetPlist = "\(basePath).plist"

            let successDylib = self.coreBridge.executeCommand(
                executable: "/bin/mv", arguments: [tweak.dylibPath, targetDylib]
            )
            if FileManager.default.fileExists(atPath: currentPlist) {
                _ = self.coreBridge.executeCommand(
                    executable: "/bin/mv", arguments: [currentPlist, targetPlist]
                )
            }

            DispatchQueue.main.async {
                if successDylib {
                    self.console.log("Tweak \(enable ? "enabled" : "disabled").")
                    self.refreshTweaks()
                } else {
                    self.console.log("Failed to toggle tweak: \(tweak.name)")
                }
                self.isProcessing = false
                completion(successDylib)
            }
        }
    }
}
