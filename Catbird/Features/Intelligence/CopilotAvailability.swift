import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether Ask Catbird can run on this device right now.
///
/// Ask Catbird runs entirely on Apple's on-device language model, so entry points
/// are only offered when the OS ships Foundation Models and the model reports itself
/// as available (eligible hardware, Apple Intelligence turned on, model downloaded).
enum CopilotAvailability {
  enum Status: Equatable {
    case available
    case disabled
    case requiresNewerOS
    case appleIntelligenceNotEnabled
    case modelNotReady
    case deviceNotEligible
  }

  static var isAvailable: Bool { status == .available }

  static var status: Status {
    guard IntelligenceFeatureFlags.copilotEnabled else { return .disabled }
    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *) {
      switch SystemLanguageModel.default.availability {
      case .available:
        return .available
      case .unavailable(.appleIntelligenceNotEnabled):
        return .appleIntelligenceNotEnabled
      case .unavailable(.modelNotReady):
        return .modelNotReady
      case .unavailable:
        return .deviceNotEligible
      }
    }
    return .requiresNewerOS
    #else
    return .deviceNotEligible
    #endif
  }

  /// A short explanation for when Ask Catbird can't be used, or nil when it can.
  static var unavailableMessage: String? {
    switch status {
    case .available:
      return nil
    case .appleIntelligenceNotEnabled:
      return "Turn on Apple Intelligence in Settings to use Ask Catbird."
    case .modelNotReady:
      return "Apple Intelligence is still getting ready. Try again later."
    case .requiresNewerOS:
      return "Ask Catbird requires iOS 26 or later."
    case .disabled, .deviceNotEligible:
      return "Ask Catbird isn’t available on this device."
    }
  }
}
