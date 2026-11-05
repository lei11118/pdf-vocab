import Foundation

enum FeatureFlags {
    static let contextReadingEnabledKey = "contextReading.enabled"
    static let mathEnabledKey = "contextReading.mathEnabled"
    static let prefetchEnabledKey = "contextReading.prefetchEnabled"

    static func contextReadingEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: contextReadingEnabledKey)
    }

    static func mathEnabled(in defaults: UserDefaults = .standard) -> Bool {
        contextReadingEnabled(in: defaults) && defaults.bool(forKey: mathEnabledKey)
    }

    static func prefetchEnabled(in defaults: UserDefaults = .standard) -> Bool {
        contextReadingEnabled(in: defaults) && defaults.bool(forKey: prefetchEnabledKey)
    }
}
