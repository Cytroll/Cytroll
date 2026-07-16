import Foundation
import Combine

/// Persistent preferences for Cytroll Care (auto re-inject, etc.).
public final class CytrollCareSettings: ObservableObject {
    public static let shared = CytrollCareSettings()

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let autoReinject = "cytroll.care.autoReinject"
    }

    @Published public var autoReinjectEnabled: Bool {
        didSet { defaults.set(autoReinjectEnabled, forKey: Keys.autoReinject) }
    }

    private init() {
        if defaults.object(forKey: Keys.autoReinject) == nil {
            autoReinjectEnabled = true
        } else {
            autoReinjectEnabled = defaults.bool(forKey: Keys.autoReinject)
        }
    }
}
