import SwiftUI
import XCTest
@testable import Catbird

final class SceneFeedActivityTests: XCTestCase {
  @MainActor
  func testReplacementKeepsDelayedCallbacksOnOldContextAndOrdersRetirement() async {
    let oldID = UUID()
    let newID = UUID()
    var calls: [String] = []
    var releaseFirstRegistration: CheckedContinuation<Void, Never>?
    let registration = SceneFeedActivityRegistration(
      register: { id, phase in
        if id == oldID {
          await withCheckedContinuation { releaseFirstRegistration = $0 }
        }
        calls.append("register:\(id):\(phase)")
      },
      update: { calls.append("update:\($0):\($1)") },
      unregister: { calls.append("unregister:\($0)") }
    )
    registration.replace(with: oldID, phase: .active)
    while releaseFirstRegistration == nil { await Task.yield() }
    registration.update(phase: .inactive)
    registration.replace(with: newID, phase: .active)
    registration.update(phase: .background)
    registration.disconnect()
    releaseFirstRegistration?.resume()
    await registration.waitForPendingUpdates()
    XCTAssertEqual(calls, [
      "register:\(oldID):active", "update:\(oldID):inactive", "unregister:\(oldID)",
      "register:\(newID):active", "update:\(newID):background", "unregister:\(newID)"
    ])
  }

  @MainActor
  func testDisconnectedLifetimeCannotReregisterOrApplyLatePhase() async {
    var calls = 0
    let registration = SceneFeedActivityRegistration(
      register: { _, _ in calls += 1 }, update: { _, _ in calls += 1 },
      unregister: { _ in calls += 1 }
    )
    registration.replace(with: UUID(), phase: .active)
    registration.disconnect()
    registration.update(phase: .active)
    registration.replace(with: UUID(), phase: .active)
    registration.disconnect()
    await registration.waitForPendingUpdates()
    XCTAssertEqual(calls, 2)
  }

  @MainActor
  func testUnauthenticatedAndDuplicateAccountUpdatesDoNotRegisterPhantomContexts() async {
    var calls = 0
    let registration = SceneFeedActivityRegistration(
      register: { _, _ in calls += 1 }, update: { _, _ in calls += 1 },
      unregister: { _ in calls += 1 }
    )
    registration.update(phase: .active)
    registration.replace(with: nil, phase: .active)
    let id = UUID()
    registration.replace(with: id, phase: .active)
    registration.replace(with: id, phase: .active)
    registration.replace(with: nil, phase: .inactive)
    registration.update(phase: .background)
    await registration.waitForPendingUpdates()
    XCTAssertEqual(calls, 2)
  }

  @MainActor
  func testApplicationPhaseAcceptsFirstEventAndOnlyRealTransitions() {
    let observation = SceneApplicationPhaseObservation()
    XCTAssertTrue(observation.accept(.inactive))
    XCTAssertFalse(observation.accept(.inactive))
    XCTAssertTrue(observation.accept(.active))
    XCTAssertFalse(observation.accept(.active))
    XCTAssertTrue(observation.accept(.inactive))
    XCTAssertTrue(observation.accept(.background))
    XCTAssertFalse(observation.accept(.background))
  }
}
