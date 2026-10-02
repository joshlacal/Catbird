import SwiftUI

/// Serializes store calls while each replacement context gets an unrepeatable identity.
/// A delayed old-context phase can run only before that context is unregistered.
@MainActor
final class SceneFeedActivityRegistration {
  typealias Register = @MainActor (UUID, ScenePhase) async -> Void
  typealias Unregister = @MainActor (UUID) async -> Void

  private let register: Register
  private let update: Register
  private let unregister: Unregister
  private var registrationID: UUID?
  private var pending: Task<Void, Never>?
  private var isDisconnected = false

  init(
    register: @escaping Register = { await FeedStateStore.shared.registerScene($0, phase: $1) },
    update: @escaping Register = { await FeedStateStore.shared.updateScenePhase($1, for: $0) },
    unregister: @escaping Unregister = { await FeedStateStore.shared.unregisterScene($0) }
  ) {
    self.register = register
    self.update = update
    self.unregister = unregister
  }

  func replace(with newID: UUID?, phase: ScenePhase) {
    guard !isDisconnected, registrationID != newID else { return }
    let oldID = registrationID
    registrationID = newID
    let previous = pending
    let register = register
    let unregister = unregister
    pending = Task { @MainActor in
      await previous?.value
      if let oldID { await unregister(oldID) }
      if let newID { await register(newID, phase) }
    }
  }

  func update(phase: ScenePhase) {
    guard !isDisconnected, let registrationID else { return }
    let previous = pending
    let update = update
    pending = Task { @MainActor in
      await previous?.value
      await update(registrationID, phase)
    }
  }

  func disconnect() {
    guard !isDisconnected else { return }
    replace(with: nil, phase: .background)
    isDisconnected = true
  }

  func waitForPendingUpdates() async {
    await pending?.value
  }
}
