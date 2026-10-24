import Foundation

/// Build capability, deliberately independent of account consent and rollout preferences.
/// This target does not request the managed PCC entitlement. Keep the gate closed
/// until Apple grants access and the distribution profile and signed app are verified.
/// Foundation Models exposes availability on an instance, so it cannot be used
/// to establish entitlement authorization before constructing that instance.
enum CopilotCloudAvailability {
    static let isProvisionedBuild = false

    static var unavailableReason: String? {
        guard isProvisionedBuild else {
            return "Private Cloud Compute is not enabled in this version of Catbird. You can continue using On Device."
        }
        guard IntelligenceFeatureFlags.privateCloudComputeEnabled else {
            return "Private Cloud Compute is currently disabled. You can continue using On Device."
        }
        if #available(iOS 27.0, macOS 27.0, *) {
            return nil
        }
        return "Private Cloud Compute requires iOS 27 or macOS 27 or later. You can continue using On Device."
    }
}

struct CopilotCloudUnavailableError: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}
