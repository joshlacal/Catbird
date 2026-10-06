import Foundation
import SwiftUI

/// Aggregates scene activity while feed data remains shared by account and feed.
/// A foreground-inactive scene retains work during brief system interruptions.
struct FeedSceneLifecycle {
  struct Transition {
    let previousPhase: ScenePhase
    let phase: ScenePhase
    let revision: UInt64
    /// Present only when an active transition ends an aggregate background interval.
    let backgroundDuration: TimeInterval?
  }

  private(set) var phases: [UUID: ScenePhase] = [:]
  private(set) var phase: ScenePhase = .active
  private(set) var revision: UInt64 = 0
  private var backgroundStartedAt: Date?

  /// Registration belongs to the scene root, rather than an individual feed view.
  mutating func register(_ sceneID: UUID, phase: ScenePhase, now: Date = Date()) -> Transition? {
    phases[sceneID] = phase
    return transitionIfNeeded(now: now)
  }

  /// Ignore delayed callbacks from a disconnected scene until it registers again.
  mutating func update(_ phase: ScenePhase, for sceneID: UUID, now: Date = Date()) -> Transition? {
    guard phases[sceneID] != nil else { return nil }
    phases[sceneID] = phase
    return transitionIfNeeded(now: now)
  }

  mutating func unregister(_ sceneID: UUID, now: Date = Date()) -> Transition? {
    guard phases.removeValue(forKey: sceneID) != nil else { return nil }
    return transitionIfNeeded(now: now)
  }

  /// Async lifecycle effects must recheck this after each suspension.
  func isCurrent(_ transition: Transition) -> Bool {
    transition.revision == revision && transition.phase == phase
  }

  private mutating func transitionIfNeeded(now: Date) -> Transition? {
    let nextPhase: ScenePhase
    if phases.values.contains(.active) {
      nextPhase = .active
    } else if phases.values.contains(where: { $0 != .background }) {
      // Inactive and future foreground phases must not cancel shared loading.
      nextPhase = .inactive
    } else {
      nextPhase = .background
    }
    guard nextPhase != phase else { return nil }

    let previousPhase = phase
    phase = nextPhase
    revision &+= 1
    var backgroundDuration: TimeInterval?
    if nextPhase == .background, backgroundStartedAt == nil {
      backgroundStartedAt = now
    } else if nextPhase == .active, let backgroundStartedAt {
      backgroundDuration = max(0, now.timeIntervalSince(backgroundStartedAt))
      self.backgroundStartedAt = nil
    }
    return Transition(previousPhase: previousPhase, phase: nextPhase,
                      revision: revision, backgroundDuration: backgroundDuration)
  }
}

/// Executes the same lifecycle sequence for the store and bounded race tests.
/// A manager reports resumption only if it actually received a background effect.
@MainActor
enum FeedSceneLifecycleEffects {
  static func apply(
    _ transition: FeedSceneLifecycle.Transition,
    isCurrent: () -> Bool,
    save: () async -> Void,
    notify: (ScenePhase) async -> Bool,
    resume: (TimeInterval) async -> Void
  ) async {
    guard isCurrent() else { return }
    switch transition.phase {
    case .background, .inactive:
      await save()
      guard isCurrent() else { return }
      _ = await notify(transition.phase)
    case .active:
      let resumedSuspendedManagers = await notify(.active)
      guard isCurrent(), resumedSuspendedManagers,
            let duration = transition.backgroundDuration else { return }
      await resume(duration)
    @unknown default:
      break
    }
  }
}
