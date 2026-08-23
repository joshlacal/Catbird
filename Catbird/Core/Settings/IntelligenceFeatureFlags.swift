import Foundation

/// Independent rollout gates let Catbird ship the deterministic pieces without
/// coupling them to model availability or Private Cloud Compute.
enum IntelligenceFeatureFlags {
    private static let defaults = UserDefaults.standard

    static var copilotEnabled: Bool { value("copilot", default: true) }
    static var smartFilterStructuralRulesEnabled: Bool { value("smartFilters.structural", default: true) }
    static var smartFilterSemanticRulesEnabled: Bool { value("smartFilters.semantic", default: true) }
    static var privateCloudComputeEnabled: Bool { value("copilot.pcc", default: true) }

    private static func value(_ name: String, default defaultValue: Bool) -> Bool {
        let key = "feature.intelligence.\(name)"
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}
