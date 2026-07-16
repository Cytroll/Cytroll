import Foundation

public final class JailbreakUtilities {
    public static let shared = JailbreakUtilities()
    private let bridge = CytrollCoreBridge.shared

    private init() {}

    public func respring() {
        _ = bridge.executeCommand(executable: RootlessPaths.sbreload, arguments: [])
    }

    public func userspaceReboot() {
        _ = bridge.executeCommand(executable: RootlessPaths.launchctl, arguments: ["reboot", "userspace"])
    }

    public func uicache() {
        _ = bridge.executeCommand(executable: RootlessPaths.uicache, arguments: ["-a"])
    }

    public func setTweaksEnabled(_ enabled: Bool) {
        let fm = FileManager.default
        let safeModePath = RootlessPaths.disableTweaksFlag

        do {
            if enabled {
                if fm.fileExists(atPath: safeModePath) {
                    try fm.removeItem(atPath: safeModePath)
                }
            } else if !fm.fileExists(atPath: safeModePath) {
                fm.createFile(atPath: safeModePath, contents: nil, attributes: nil)
            }
        } catch {
            print("Cytroll: Failed to toggle tweaks - \(error)")
        }
    }

    public func areTweaksEnabled() -> Bool {
        !FileManager.default.fileExists(atPath: RootlessPaths.disableTweaksFlag)
    }

    public func removeEnvironment(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let success = self.bridge.executeCommand(
                executable: "/bin/rm",
                arguments: ["-rf", RootlessPaths.prefix]
            )
            DispatchQueue.main.async { completion(success) }
        }
    }
}
