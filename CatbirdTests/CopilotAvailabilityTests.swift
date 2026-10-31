import Foundation
import Observation
import Testing
import os
@testable import Catbird

@MainActor
struct CopilotAvailabilityTests {
  @Test func repeatedMenuReadsDoNotProbeTheModel() {
    var probes = 0
    let store = CopilotAvailabilityStore(featureEnabled: { true }, readModelStatus: {
      probes += 1
      return .available
    })
    for _ in 0..<1_000 { #expect(store.status == .modelNotReady) }
    #expect(probes == 0)
    store.refresh()
    for _ in 0..<1_000 { #expect(store.status == .available) }
    #expect(probes == 1)
  }

  @Test func onlyChangedCapabilitiesInvalidateObservers() {
    var capability: CopilotAvailability.Status = .available
    let store = CopilotAvailabilityStore(featureEnabled: { true }, readModelStatus: { capability })
    store.refresh()
    let changes = OSAllocatedUnfairLock(initialState: 0)
    withObservationTracking { _ = store.status } onChange: {
      changes.withLock { $0 += 1 }
    }
    store.refresh()
    #expect(changes.withLock { $0 } == 0)
    capability = .appleIntelligenceNotEnabled
    store.refresh()
    #expect(store.status == .appleIntelligenceNotEnabled)
    #expect(changes.withLock { $0 } == 1)
  }

  @Test func disabledFeatureSuppressesProbesAndRevokesCachedAvailability() {
    var enabled = false
    var probes = 0
    let store = CopilotAvailabilityStore(featureEnabled: { enabled }, readModelStatus: {
      probes += 1
      return .available
    })
    store.refresh()
    #expect(store.status == .disabled)
    #expect(probes == 0)
    enabled = true
    store.refresh()
    #expect(store.status == .available)
    enabled = false
    #expect(store.status == .disabled)
    #expect(probes == 1)
    store.refresh()
    enabled = true
    #expect(store.status == .disabled)
    store.refresh()
    #expect(store.status == .available)
    #expect(probes == 2)
  }

  @Test func foregroundTransitionsRefreshWithoutRepeatedSceneProbes() {
    var capability: CopilotAvailability.Status = .available
    var probes = 0
    let store = CopilotAvailabilityStore(featureEnabled: { true }, readModelStatus: {
      probes += 1
      return capability
    })
    store.setApplicationActive(false)
    #expect(probes == 0)
    store.setApplicationActive(true)
    store.setApplicationActive(true)
    #expect(probes == 1)
    store.setApplicationActive(false)
    capability = .deviceNotEligible
    store.setApplicationActive(true)
    #expect(store.status == .deviceNotEligible)
    #expect(probes == 2)
    store.setApplicationActive(false)
  }

  @Test func explicitRetryCanRecoverAndRetainUnavailableReasons() {
    var capability: CopilotAvailability.Status = .modelNotReady
    let store = CopilotAvailabilityStore(featureEnabled: { true }, readModelStatus: { capability })
    store.refresh()
    #expect(CopilotAvailability.unavailableMessage(for: store.status) != nil)
    capability = .available
    store.refresh()
    #expect(CopilotAvailability.unavailableMessage(for: store.status) == nil)
    let reasons: [CopilotAvailability.Status] = [.requiresNewerOS, .deviceNotEligible, .appleIntelligenceNotEnabled]
    for reason in reasons {
      capability = reason
      store.refresh()
      #expect(store.status == reason)
      #expect(CopilotAvailability.unavailableMessage(for: store.status) != nil)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func modelDownloadRetriesCentrallyWhileActive() async {
    var probes = 0
    var recovered: CheckedContinuation<Void, Never>?
    let store = CopilotAvailabilityStore(featureEnabled: { true }, readModelStatus: {
      probes += 1
      if probes == 1 { return .modelNotReady }
      recovered?.resume()
      recovered = nil
      return .available
    }, retryDelay: .milliseconds(10))
    await withCheckedContinuation { continuation in
      recovered = continuation
      store.setApplicationActive(true)
    }
    #expect(store.status == .available)
    #expect(probes == 2)
    store.setApplicationActive(false)
  }
}
