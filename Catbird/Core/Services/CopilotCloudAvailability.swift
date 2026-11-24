import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Build capability, deliberately independent of account consent and rollout preferences.
/// The app target requests the managed `com.apple.developer.private-cloud-compute`
/// entitlement in `Catbird.entitlements`, and its provisioning profile must carry it.
/// Foundation Models exposes availability on an instance, so it cannot be used
/// to establish entitlement authorization before constructing that instance.
enum CopilotCloudAvailability {
  static let isProvisionedBuild = true

  static let operatingSystemRequirement = String(
    localized: "Private Cloud Compute requires iOS 27 or macOS 27 or later. You can continue using On Device.",
    comment: "Ask Catbird: Private Cloud Compute needs a newer OS."
  )

  /// Reasons that hold for the whole build or device, checked without contacting Apple.
  static var unavailableReason: String? {
    guard isProvisionedBuild else {
      return String(
        localized: "Private Cloud Compute is not enabled in this version of Catbird. You can continue using On Device.",
        comment: "Ask Catbird: this build is not provisioned for Private Cloud Compute."
      )
    }
    guard IntelligenceFeatureFlags.privateCloudComputeEnabled else {
      return String(
        localized: "Private Cloud Compute is currently disabled. You can continue using On Device.",
        comment: "Ask Catbird: Private Cloud Compute is turned off by a feature flag."
      )
    }
    if #available(iOS 27.0, macOS 27.0, *) {
      return nil
    }
    return operatingSystemRequirement
  }
}

struct CopilotCloudUnavailableError: LocalizedError {
  let reason: String
  var errorDescription: String? { reason }
}

/// A Private Cloud Compute turn that could not run. These are reported to the
/// person, never answered silently by the on-device model instead.
enum CopilotCloudTurnError: LocalizedError, Equatable {
  case deviceNotEligible
  case systemNotReady
  case quotaReached(resetDate: Date?)
  case networkFailure
  case serviceUnavailable
  case unsupportedLanguage

  var errorDescription: String? {
    switch self {
    case .deviceNotEligible:
      String(localized: "This device can't use Private Cloud Compute. Switch to On Device to continue.",
             comment: "Ask Catbird: device is not eligible for Private Cloud Compute.")
    case .systemNotReady:
      String(localized: "Private Cloud Compute isn't ready yet. Check that Apple Intelligence is on, or switch to On Device.",
             comment: "Ask Catbird: Private Cloud Compute is still being set up.")
    case .quotaReached(let resetDate?):
      String(localized: "You've reached the Private Cloud Compute limit until \(resetDate.formatted(date: .abbreviated, time: .shortened)). Switch to On Device to keep going.",
             comment: "Ask Catbird: Private Cloud Compute quota reached, with reset time.")
    case .quotaReached(nil):
      String(localized: "You've reached the Private Cloud Compute limit for now. Switch to On Device to keep going.",
             comment: "Ask Catbird: Private Cloud Compute quota reached.")
    case .networkFailure:
      String(localized: "Private Cloud Compute couldn't be reached. Check your connection and try again, or switch to On Device.",
             comment: "Ask Catbird: network failure reaching Private Cloud Compute.")
    case .serviceUnavailable:
      String(localized: "Private Cloud Compute is temporarily unavailable. Try again shortly, or switch to On Device.",
             comment: "Ask Catbird: Private Cloud Compute service is down.")
    case .unsupportedLanguage:
      String(localized: "Private Cloud Compute doesn't support your current language yet. Switch to On Device to continue.",
             comment: "Ask Catbird: device language is not supported by Private Cloud Compute.")
    }
  }

  var isQuota: Bool {
    if case .quotaReached = self { return true }
    return false
  }
}

/// What the route picker shows about Private Cloud Compute right now.
struct CopilotCloudStatus: Equatable, Sendable {
  enum Quota: Equatable, Sendable {
    case available
    case approachingLimit
    case limitReached(resetDate: Date?)
  }

  /// Nil when the route can be chosen; otherwise the reason shown under the picker.
  let unavailableReason: String?
  let quota: Quota
  let canRequestMoreQuota: Bool

  var isSelectable: Bool { unavailableReason == nil }

  static func unavailable(_ reason: String) -> Self {
    .init(unavailableReason: reason, quota: .available, canRequestMoreQuota: false)
  }

  /// Reads availability, quota and language support. Never sends a prompt.
  static func current() async -> Self {
    if let reason = CopilotCloudAvailability.unavailableReason { return .unavailable(reason) }
    #if canImport(FoundationModels)
    if #available(iOS 27.0, macOS 27.0, *) {
      let model = PrivateCloudComputeLanguageModel()
      if let failure = CopilotCloudTurnError(availability: model.availability) {
        return .unavailable(failure.errorDescription ?? "")
      }
      if let supported = try? await model.supportsLocale(), !supported {
        return .unavailable(CopilotCloudTurnError.unsupportedLanguage.errorDescription ?? "")
      }
      let usage = model.quotaUsage
      let quota: Quota
      switch usage.status {
      case .limitReached: quota = .limitReached(resetDate: usage.resetDate)
      case .belowLimit(let below): quota = below.isApproachingLimit ? .approachingLimit : .available
      }
      return .init(unavailableReason: nil, quota: quota, canRequestMoreQuota: usage.limitIncreaseSuggestion != nil)
    }
    #endif
    return .unavailable(CopilotCloudAvailability.operatingSystemRequirement)
  }

  /// Presents Apple's offer to raise the Private Cloud Compute limit, when one exists.
  @MainActor
  static func showLimitIncreaseSuggestion() {
    #if canImport(FoundationModels)
    if #available(iOS 27.0, macOS 27.0, *), CopilotCloudAvailability.unavailableReason == nil {
      PrivateCloudComputeLanguageModel().quotaUsage.limitIncreaseSuggestion?.show()
    }
    #endif
  }
}

#if canImport(FoundationModels)
@available(iOS 27.0, macOS 27.0, *)
extension CopilotCloudTurnError {
  init?(availability: PrivateCloudComputeLanguageModel.Availability) {
    switch availability {
    case .available: return nil
    case .unavailable(.deviceNotEligible): self = .deviceNotEligible
    case .unavailable(.systemNotReady): self = .systemNotReady
    case .unavailable: self = .systemNotReady
    }
  }

  init(_ error: PrivateCloudComputeLanguageModel.Error) {
    switch error {
    case .quotaLimitReached(let details): self = .quotaReached(resetDate: details.resetDate)
    case .networkFailure: self = .networkFailure
    case .serviceUnavailable: self = .serviceUnavailable
    @unknown default: self = .serviceUnavailable
    }
  }
}
#endif
