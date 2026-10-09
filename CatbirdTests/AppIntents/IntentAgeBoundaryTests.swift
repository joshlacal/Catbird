import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#endif

@testable import Catbird

/// Synthetic passive signals only: these tests never create a real client or
/// request Apple's age-range UI. Build/runtime qualification is tracked in the handoff.
@Suite("Headless intent age boundary")
struct IntentAgeBoundaryTests {
  private let accountA = "did:plc:intent-age-a"
  private let accountB = "did:plc:intent-age-b"

  @Test func explicitNoRequirementAllowsOrdinaryUse() async throws {
    let checker = SequenceAgeChecker([.init(requirement: .none)])
    let provider = IntentClientProvider(regulatoryChecker: checker)
    try await provider.requireCoveredUse(for: accountA)
    #expect(await checker.callCount == 1)
  }

  @Test func unavailableWithoutPriorRequirementAllowsOrdinaryUse() async throws {
    let checker = SequenceAgeChecker([.init(requirement: .unavailable)])
    let provider = IntentClientProvider(regulatoryChecker: checker)
    try await provider.requireCoveredUse(for: accountA)
  }

  @Test func requiredCheckReturnsOpenCatbirdRetryError() async {
    let checker = SequenceAgeChecker([.init(requirement: .ageCheckRequired)])
    let provider = IntentClientProvider(regulatoryChecker: checker)
    do {
      try await provider.requireCoveredUse(for: accountA)
      Issue.record("A headless intent must not satisfy a required age check.")
    } catch let error as IntentError {
      guard case .serviceUnavailable(let message) = error else {
        Issue.record("Expected the actionable age-check retry error.")
        return
      }
      #expect(message == "This shortcut is unavailable under your device’s age requirements. Open Catbird to continue.")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func unavailableRefreshKeepsEarlierRequirement() async {
    let checker = SequenceAgeChecker([
      .init(requirement: .ageCheckRequired), .init(requirement: .unavailable)
    ])
    let provider = IntentClientProvider(regulatoryChecker: checker)
    await #expect(throws: IntentError.self) {
      try await provider.requireCoveredUse(for: accountA)
    }
    await #expect(throws: IntentError.self) {
      try await provider.requireCoveredUse(for: accountA)
    }
  }

  @Test func explicitNoneClearsEarlierRequirement() async throws {
    let checker = SequenceAgeChecker([
      .init(requirement: .ageCheckRequired), .init(requirement: .none)
    ])
    let provider = IntentClientProvider(regulatoryChecker: checker)
    await #expect(throws: IntentError.self) {
      try await provider.requireCoveredUse(for: accountA)
    }
    try await provider.requireCoveredUse(for: accountA)
  }

  @Test func requirementIsIsolatedPerAccount() async throws {
    let checker = SequenceAgeChecker([
      .init(requirement: .ageCheckRequired), .init(requirement: .unavailable),
      .init(requirement: .unavailable)
    ])
    let provider = IntentClientProvider(regulatoryChecker: checker)
    await #expect(throws: IntentError.self) {
      try await provider.requireCoveredUse(for: accountA)
    }
    try await provider.requireCoveredUse(for: accountB)
    await #expect(throws: IntentError.self) {
      try await provider.requireCoveredUse(for: accountA)
    }
  }

  @Test func clientInvalidationDoesNotEraseRequirement() async {
    let checker = SequenceAgeChecker([
      .init(requirement: .ageCheckRequired), .init(requirement: .unavailable)
    ])
    let provider = IntentClientProvider(regulatoryChecker: checker)
    await #expect(throws: IntentError.self) {
      try await provider.requireCoveredUse(for: accountA)
    }
    await provider.invalidateClient(for: accountA)
    await #expect(throws: IntentError.self) {
      try await provider.requireCoveredUse(for: accountA)
    }
  }

  @Test func injectedAdultBandCannotUnlockHeadlessUse() async {
    let checker = SequenceAgeChecker([
      .init(requirement: .ageCheckRequired, ageBand: .adult)
    ])
    let provider = IntentClientProvider(regulatoryChecker: checker)
    await #expect(throws: IntentError.self) {
      try await provider.requireCoveredUse(for: accountA)
    }
  }

  @Test func informationalConsentFlagDoesNotCreateAnAgeRequirement() async throws {
    let checker = SequenceAgeChecker([
      .init(requirement: .none, significantChangeConsentRequired: true)
    ])
    let provider = IntentClientProvider(regulatoryChecker: checker)
    try await provider.requireCoveredUse(for: accountA)
  }

  @Test func defaultClientAdmissionDeniesBeforeAuthBootstrap() async {
    let checker = SequenceAgeChecker([.init(requirement: .ageCheckRequired)])
    let provider = IntentClientProvider(regulatoryChecker: checker)
    do {
      _ = try await provider.client(for: accountA)
      Issue.record("A covered client must not be returned while an age check is required.")
    } catch let error as IntentError {
      guard case .serviceUnavailable = error else {
        Issue.record("Expected age admission denial before any auth bootstrap.")
        return
      }
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(await checker.callCount == 1)
  }

  @Test func concurrentRequestsNeverRunOverlappingPreflightsForOneAccount() async {
    let checker = SequenceAgeChecker(
      Array(repeating: .init(requirement: .ageCheckRequired), count: 16))
    let provider = IntentClientProvider(regulatoryChecker: checker)
    let did = accountA
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<16 {
        group.addTask {
          await #expect(throws: IntentError.self) {
            try await provider.requireCoveredUse(for: did)
          }
        }
      }
    }
    #expect(await checker.maximumConcurrentChecks == 1)
  }
}

private actor SequenceAgeChecker: AgeRegulatoryChecking {
  private var signals: [PlatformAgeSignal]
  private(set) var callCount = 0
  private var activeChecks = 0
  private(set) var maximumConcurrentChecks = 0

  init(_ signals: [PlatformAgeSignal]) { self.signals = signals }

  func preflight() async -> PlatformAgeSignal {
    callCount += 1
    guard !signals.isEmpty else {
      Issue.record("The test requested an unexpected extra passive check.")
      return .init(requirement: .unavailable)
    }
    let signal = signals.removeFirst()
    activeChecks += 1
    maximumConcurrentChecks = max(maximumConcurrentChecks, activeChecks)
    await Task.yield()
    activeChecks -= 1
    return signal
  }

  #if canImport(UIKit)
  @MainActor
  func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? {
    Issue.record("A headless intent must never request native age-range UI.")
    return nil
  }
  #endif
}
