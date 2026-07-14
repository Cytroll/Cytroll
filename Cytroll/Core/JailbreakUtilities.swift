import Foundation

public final class JailbreakUtilities {
    public static let shared = JailbreakUtilities()
    private let bridge = CytrollCoreBridge.shared
    
    private init() {}
    
    /// Reloads the SpringBoard to apply new tweaks quickly.
    public func respring() {
        // sbreload is the standard rootless way to respring smoothly.
        _ = bridge.executeCommand(executable: "/var/jb/usr/bin/sbreload", arguments: [])
    }
    
    /// Fully restarts the userspace for deep environment changes.
    public func userspaceReboot() {
        _ = bridge.executeCommand(executable: "/var/jb/bin/launchctl", arguments: ["reboot", "userspace"])
    }
    
    /// Refreshes the icon cache so newly installed apps appear on the Home Screen.
    public func uicache() {
        _ = bridge.executeCommand(executable: "/var/jb/usr/bin/uicache", arguments: ["-a"])
    }
    
    /// Enables or disables Tweak Injection globally (Safe Mode equivalent).
    public func setTweaksEnabled(_ enabled: Bool) {
        let fm = FileManager.default
        let safeModePath = "/var/jb/.disable_tweaks"
        
        do {
            if enabled {
                if fm.fileExists(atPath: safeModePath) {
                    try fm.removeItem(atPath: safeModePath)
                }
            } else {
                if !fm.fileExists(atPath: safeModePath) {
                    fm.createFile(atPath: safeModePath, contents: nil, attributes: nil)
                }
            }
        } catch {
            print("Cytroll: Failed to toggle tweaks - \(error)")
        }
    }
    
    /// Checks if Tweak Injection is currently enabled.
    public func areTweaksEnabled() -> Bool {
        return !FileManager.default.fileExists(atPath: "/var/jb/.disable_tweaks")
    }
    
    /// The Nuclear Option: Completely removes the jailbreak environment.
    public func removeEnvironment(completion: @escaping (Bool) -> Void) {
        // Run on background thread to prevent UI freezing during heavy IO operations
        DispatchQueue.global(qos: .userInitiated).async {
            // Unmount developer image / clean var/jb securely
            // Use rm -rf with highest TrollStore root privileges via our bridge
            let success = self.bridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", "/var/jb"])
            
            DispatchQueue.main.async {
                completion(success)
            }
        }
    }
}
