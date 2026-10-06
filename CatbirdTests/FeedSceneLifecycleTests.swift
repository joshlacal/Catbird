import Foundation
import SwiftUI
import Testing
@testable import Catbird

@Suite("Shared feed scene lifecycle")
struct FeedSceneLifecycleTests {
  private let start = Date(timeIntervalSince1970: 1_700_000_000)

  @Test("Backgrounding one scene does not suspend another active scene")
  func anotherActiveSceneKeepsLoading() {
    var lifecycle = FeedSceneLifecycle()
    let first = UUID()
    let second = UUID()
    _ = lifecycle.register(first, phase: .active, now: start)
    _ = lifecycle.register(second, phase: .active, now: start)
    #expect(lifecycle.update(.background, for: first, now: start) == nil)
    #expect(lifecycle.phase == .active)
    #expect(lifecycle.phases.count == 2)
  }

  @Test("Foreground inactive scenes preserve work until every scene backgrounds")
  func foregroundInactiveIsNotSuspension() throws {
    var lifecycle = FeedSceneLifecycle()
    let first = UUID()
    let second = UUID()
    _ = lifecycle.register(first, phase: .active, now: start)
    _ = lifecycle.register(second, phase: .inactive, now: start)
    let inactiveTransition = lifecycle.update(.background, for: first, now: start)
    let inactive = try #require(inactiveTransition)
    #expect(inactive.phase == .inactive)
    #expect(inactive.backgroundDuration == nil)
    let backgroundTransition = lifecycle.update(.background, for: second, now: start)
    let background = try #require(backgroundTransition)
    #expect(background.phase == .background)
  }

  @Test("Removing a scene only backgrounds feeds after the last foreground scene disconnects")
  func disconnectRespectsRemainingScenes() throws {
    var lifecycle = FeedSceneLifecycle()
    let first = UUID()
    let second = UUID()
    _ = lifecycle.register(first, phase: .active, now: start)
    _ = lifecycle.register(second, phase: .active, now: start)
    #expect(lifecycle.unregister(first, now: start) == nil)
    #expect(lifecycle.phase == .active)
    #expect(lifecycle.unregister(second, now: start)?.phase == .background)
    #expect(lifecycle.phases.isEmpty)
    #expect(lifecycle.unregister(second, now: start) == nil)
  }

  @Test("Duplicate scene callbacks do not repeat lifecycle effects")
  func duplicateRegistrationAndPhasesAreIdempotent() {
    var lifecycle = FeedSceneLifecycle()
    let scene = UUID()
    #expect(lifecycle.register(scene, phase: .active, now: start) == nil)
    #expect(lifecycle.register(scene, phase: .active, now: start) == nil)
    #expect(lifecycle.update(.active, for: scene, now: start) == nil)
    _ = lifecycle.update(.background, for: scene, now: start)
    let revision = lifecycle.revision
    #expect(lifecycle.update(.background, for: scene, now: start.addingTimeInterval(10)) == nil)
    #expect(lifecycle.revision == revision)
    #expect(lifecycle.phases.count == 1)
  }

  @Test("Delayed callbacks cannot resurrect a disconnected scene")
  func disconnectedSceneMustRegisterAgain() {
    var lifecycle = FeedSceneLifecycle()
    let scene = UUID()
    #expect(lifecycle.update(.active, for: scene, now: start) == nil)
    #expect(lifecycle.phases.isEmpty)
    _ = lifecycle.register(scene, phase: .active, now: start)
    _ = lifecycle.unregister(scene, now: start)
    #expect(lifecycle.update(.active, for: scene, now: start) == nil)
    #expect(lifecycle.phase == .background)
    #expect(lifecycle.phases.isEmpty)
    #expect(lifecycle.register(scene, phase: .active, now: start)?.phase == .active)
  }

  @Test("Temporary inactive state does not create a background refresh interval")
  func temporaryInterruptionDoesNotRefresh() throws {
    var lifecycle = FeedSceneLifecycle()
    let scene = UUID()
    _ = lifecycle.register(scene, phase: .active, now: start)
    _ = lifecycle.update(.inactive, for: scene, now: start)
    let activeTransition = lifecycle.update(.active, for: scene, now: start.addingTimeInterval(90))
    let active = try #require(activeTransition)
    #expect(active.previousPhase == .inactive)
    #expect(active.backgroundDuration == nil)
  }

  @Test("Background duration survives intermediate inactive transitions")
  func backgroundIntervalEndsAtActive() throws {
    var lifecycle = FeedSceneLifecycle()
    let scene = UUID()
    _ = lifecycle.register(scene, phase: .active, now: start)
    _ = lifecycle.update(.background, for: scene, now: start)
    _ = lifecycle.update(.inactive, for: scene, now: start.addingTimeInterval(60))
    _ = lifecycle.update(.background, for: scene, now: start.addingTimeInterval(70))
    _ = lifecycle.update(.inactive, for: scene, now: start.addingTimeInterval(80))
    let activeTransition = lifecycle.update(.active, for: scene, now: start.addingTimeInterval(90))
    let active = try #require(activeTransition)
    #expect(active.backgroundDuration == 90)
    _ = lifecycle.update(.inactive, for: scene, now: start.addingTimeInterval(100))
    let nextActiveTransition = lifecycle.update(.active, for: scene, now: start.addingTimeInterval(110))
    let nextActive = try #require(nextActiveTransition)
    #expect(nextActive.backgroundDuration == nil)
  }

  @Test("A resumed scene invalidates an older background effect before it can cancel loads")
  func resumedSceneRejectsSuspendedBackgroundEffect() throws {
    var lifecycle = FeedSceneLifecycle()
    let scene = UUID()
    _ = lifecycle.register(scene, phase: .active, now: start)
    let backgroundTransition = lifecycle.update(.background, for: scene, now: start)
    let background = try #require(backgroundTransition)
    #expect(lifecycle.isCurrent(background))
    let activeTransition = lifecycle.update(.active, for: scene, now: start.addingTimeInterval(1))
    let active = try #require(activeTransition)
    #expect(!lifecycle.isCurrent(background))
    #expect(lifecycle.isCurrent(active))
    let laterBackgroundTransition = lifecycle.update(.background, for: scene, now: start.addingTimeInterval(2))
    let laterBackground = try #require(laterBackgroundTransition)
    #expect(!lifecycle.isCurrent(background), "Returning to the same phase cannot revive an old effect")
    #expect(!lifecycle.isCurrent(active))
    #expect(lifecycle.isCurrent(laterBackground))
  }

  @Test("Replacing an account context removes the old scene registration")
  func accountContextReplacementKeepsOnlyItsNewRegistration() throws {
    var lifecycle = FeedSceneLifecycle()
    let oldContext = UUID()
    let newContext = UUID()
    _ = lifecycle.register(oldContext, phase: .active, now: start)
    let retiringTransition = lifecycle.unregister(oldContext, now: start)
    let retiring = try #require(retiringTransition)
    _ = lifecycle.register(newContext, phase: .active, now: start)
    #expect(!lifecycle.isCurrent(retiring))
    #expect(lifecycle.update(.background, for: oldContext, now: start) == nil)
    #expect(lifecycle.phases == [newContext: .active])
    #expect(lifecycle.phase == .active)
  }

  @Test("Activation while a background save is suspended never refreshes or resets running work",
        arguments: [TimeInterval(601), TimeInterval(1801)])
  @MainActor
  func activationDuringBackgroundSaveDoesNotResume(backgroundDuration: TimeInterval) async throws {
    let effects = FeedSceneLifecycleEffectsProbe()
    let scene = UUID()
    _ = effects.lifecycle.register(scene, phase: .active, now: start)
    let backgroundTransition = effects.lifecycle.update(.background, for: scene, now: start)
    let background = try #require(backgroundTransition)
    let saveStarted = FeedLifecycleTestGate()
    let finishSave = FeedLifecycleTestGate()
    defer { finishSave.open() }

    let backgroundTask = Task { @MainActor in
      await effects.apply(background) {
        saveStarted.open()
        await finishSave.wait()
      }
    }
    await saveStarted.wait()
    #expect(effects.saveCount == 1)
    #expect(effects.notifications.isEmpty)

    let activeTransition = effects.lifecycle.update(
      .active, for: scene, now: start.addingTimeInterval(backgroundDuration)
    )
    let active = try #require(activeTransition)
    #expect(active.backgroundDuration == backgroundDuration)
    await effects.apply(active)
    #expect(effects.notifications == [.active])
    #expect(effects.resumeDurations.isEmpty,
            "Elapsed time cannot refresh or reset a manager that was never suspended")

    finishSave.open()
    await backgroundTask.value
    #expect(effects.notifications == [.active], "A stale background save cannot suspend resumed scenes")
    #expect(!effects.isSuspended)
    #expect(effects.resumeDurations.isEmpty)
  }

  @Test("An applied background effect resumes once after an intermediate inactive phase")
  @MainActor
  func completedBackgroundEffectResumesOnce() async throws {
    let effects = FeedSceneLifecycleEffectsProbe()
    let scene = UUID()
    _ = effects.lifecycle.register(scene, phase: .active, now: start)
    let backgroundTransition = effects.lifecycle.update(.background, for: scene, now: start)
    let background = try #require(backgroundTransition)
    await effects.apply(background)
    #expect(effects.isSuspended)
    #expect(effects.resumeDurations.isEmpty)

    let inactiveTransition = effects.lifecycle.update(
      .inactive, for: scene, now: start.addingTimeInterval(600)
    )
    let inactive = try #require(inactiveTransition)
    await effects.apply(inactive)
    #expect(effects.isSuspended, "Foreground inactivity must preserve the pending suspension")
    #expect(effects.resumeDurations.isEmpty)

    let activeTransition = effects.lifecycle.update(
      .active, for: scene, now: start.addingTimeInterval(1801)
    )
    let active = try #require(activeTransition)
    await effects.apply(active)
    #expect(effects.notifications == [.background, .inactive, .active])
    #expect(effects.resumeDurations == [1801])
    #expect(!effects.isSuspended)
    #expect(effects.lifecycle.update(.active, for: scene, now: start.addingTimeInterval(1802)) == nil)

    await effects.apply(active)
    #expect(effects.resumeDurations == [1801], "A manager can resume only its actual suspension")
  }

  @Test("Foreground inactivity never requests a loading reset or refresh",
        arguments: [TimeInterval(601), TimeInterval(1801)])
  @MainActor
  func inactiveEffectsPreserveRunningWork(interruptionDuration: TimeInterval) async throws {
    let effects = FeedSceneLifecycleEffectsProbe()
    let scene = UUID()
    _ = effects.lifecycle.register(scene, phase: .active, now: start)
    let inactiveTransition = effects.lifecycle.update(.inactive, for: scene, now: start)
    let inactive = try #require(inactiveTransition)
    await effects.apply(inactive)
    #expect(effects.saveCount == 1)
    #expect(effects.notifications == [.inactive])
    #expect(!effects.isSuspended)
    #expect(effects.resumeDurations.isEmpty)

    let activeTransition = effects.lifecycle.update(
      .active, for: scene, now: start.addingTimeInterval(interruptionDuration)
    )
    let active = try #require(activeTransition)
    #expect(active.backgroundDuration == nil)
    await effects.apply(active)
    #expect(effects.notifications == [.inactive, .active])
    #expect(!effects.isSuspended)
    #expect(effects.resumeDurations.isEmpty)
  }
}

@MainActor
private final class FeedSceneLifecycleEffectsProbe {
  var lifecycle = FeedSceneLifecycle()
  private(set) var saveCount = 0
  private(set) var notifications: [ScenePhase] = []
  private(set) var resumeDurations: [TimeInterval] = []
  private(set) var isSuspended = false

  func apply(_ transition: FeedSceneLifecycle.Transition, save: () async -> Void = {}) async {
    await FeedSceneLifecycleEffects.apply(
      transition,
      isCurrent: { self.lifecycle.isCurrent(transition) },
      save: {
        self.saveCount += 1
        await save()
      },
      notify: { phase in
        self.notifications.append(phase)
        switch phase {
        case .background:
          self.isSuspended = true
          return false
        case .active:
          let resumed = self.isSuspended
          self.isSuspended = false
          return resumed
        case .inactive:
          return false
        @unknown default:
          return false
        }
      },
      resume: { duration in self.resumeDurations.append(duration) }
    )
  }
}

@MainActor
private final class FeedLifecycleTestGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      self.waiters.append(continuation)
    }
  }

  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for continuation in pending {
      continuation.resume()
    }
  }
}
