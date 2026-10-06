import Foundation
import Observation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Device capability is refreshed outside view/menu construction.
enum CopilotAvailability {
  enum Status: Equatable, Sendable {
    case available
    case disabled
    case requiresNewerOS
    case appleIntelligenceNotEnabled
    case modelNotReady
    case deviceNotEligible
  }

  @MainActor
  private static let shared = CopilotAvailabilityStore(
    featureEnabled: { IntelligenceFeatureFlags.copilotEnabled },
    readModelStatus: { modelStatus() }
  )

  @MainActor static var isAvailable: Bool { status == .available }
  @MainActor static var status: Status { shared.status }
  @MainActor static var unavailableMessage: String? { unavailableMessage(for: status) }

  @MainActor static func refresh() { shared.refresh() }
  @MainActor static func setApplicationActive(_ isActive: Bool) {
    shared.setApplicationActive(isActive)
  }

  private static func modelStatus() -> Status {
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

  static func unavailableMessage(for status: Status) -> String? {
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

@MainActor
@Observable
final class CopilotAvailabilityStore {
  // Conservative until the application becomes active; initialization never probes the OS.
  private var cachedStatus: CopilotAvailability.Status = .modelNotReady
  @ObservationIgnored private let featureEnabled: () -> Bool
  @ObservationIgnored private let readModelStatus: () -> CopilotAvailability.Status
  @ObservationIgnored private let retryDelay: Duration
  @ObservationIgnored private var isApplicationActive = false
  @ObservationIgnored private var retryTask: Task<Void, Never>?

  var status: CopilotAvailability.Status {
    let cached = cachedStatus
    return featureEnabled() ? cached : .disabled
  }

  init(
    featureEnabled: @escaping () -> Bool,
    readModelStatus: @escaping () -> CopilotAvailability.Status,
    retryDelay: Duration = .seconds(30)
  ) {
    self.featureEnabled = featureEnabled
    self.readModelStatus = readModelStatus
    self.retryDelay = retryDelay
  }

  deinit { retryTask?.cancel() }

  func setApplicationActive(_ isActive: Bool) {
    guard isActive != isApplicationActive else { return }
    isApplicationActive = isActive
    if isActive {
      refresh()
    } else {
      retryTask?.cancel()
      retryTask = nil
    }
  }

  func refresh() {
    let updated: CopilotAvailability.Status = featureEnabled() ? readModelStatus() : .disabled
    if updated != cachedStatus { cachedStatus = updated }
    scheduleModelDownloadRetry()
  }

  private func scheduleModelDownloadRetry() {
    retryTask?.cancel()
    retryTask = nil
    guard isApplicationActive, status == .modelNotReady else { return }
    let delay = retryDelay
    retryTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: delay) } catch { return }
      guard let self, self.isApplicationActive else { return }
      self.retryTask = nil
      self.refresh()
    }
  }
}
