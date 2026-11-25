import CatbirdMLSCore
import Foundation
import OSLog
import Petrel
import PetrelCatbird

// MARK: - Loading

extension AppState {
  /// Reads the account's own devices and works out where this device stands.
  ///
  /// Uses the stored device id only: an account with no stored id has no server row to
  /// read, and reading must never mint a new id.
  @MainActor
  func loadDeviceApprovalState(now: Date = Date()) async -> DeviceApprovalState? {
    guard isMLSRuntimeAllowed,
          let deviceId = Self.existingMLSDeviceID(for: userDID),
          let mlsClient = await getMLSAPIClient(),
          let output = try? await mlsClient.getOwnDevices(actorDeviceId: deviceId)
    else {
      return nil
    }
    let encoder = JSONEncoder()
    let rows = output.items.compactMap { item -> OwnDeviceApprovalRow? in
      guard let data = try? encoder.encode(item.device) else { return nil }
      return OwnDeviceApprovalRow(wireDeviceJSON: data)
    }
    return DeviceApprovalState.evaluate(currentDeviceId: deviceId, rows: rows, now: now)
  }
}

// MARK: - Model

/// Drives the device-approval card: loads the state, approves a waiting sibling, and
/// finishes a pending device's self-approval once its hold is over.
@MainActor
@Observable
final class DeviceApprovalModel {
  /// A screen the card opens.
  enum Sheet: String, Identifiable, Sendable {
    case restore
    case devices
    var id: String { rawValue }
  }

  private(set) var state: DeviceApprovalState?
  var presentedSheet: Sheet?
  private(set) var restoreQueued = false
  private(set) var isWorking = false
  private(set) var failure: String?

  private let logger = Logger(subsystem: "blue.catbird", category: "DeviceApproval")

  var copy: DeviceApprovalCopy? {
    guard let state else { return nil }
    return DeviceApprovalCopy.make(for: state, restoreQueued: restoreQueued)
  }

  /// Restarts the self-approval wait whenever the due date or the queued restore changes.
  func selfApprovalKey(accountDID: String) -> String {
    let due = state?.selfApprovalDate?.timeIntervalSince1970 ?? 0
    return "\(accountDID)|\(restoreQueued)|\(due)"
  }

  func refresh(appState: AppState) async {
    let loaded = await appState.loadDeviceApprovalState()
    state = loaded
    restoreQueued = false
    guard let loaded, loaded.isPending,
          let coordinator = await appState.getOrOpenMLSCoordinator(),
          let status = try? await coordinator.labyrinthStatus()
    else {
      return
    }
    restoreQueued = status.pendingDirectoryEpoch != nil
  }

  /// Publishes the queued restore again once the server's hold is over, which approves this
  /// device, then reads the state again.
  func finishSelfApprovalIfDue(appState: AppState, now: Date = Date()) async {
    guard restoreQueued,
          let state, state.isPending,
          let due = state.selfApprovalDate, due <= now,
          let coordinator = await appState.getOrOpenMLSCoordinator()
    else {
      return
    }
    do {
      _ = try await coordinator.flushLabyrinthQueue()
    } catch {
      logger.error("Self-approval publish retry failed: \(error.localizedDescription, privacy: .public)")
    }
    await refresh(appState: appState)
  }

  /// Waits until this device's self-approval is due, then finishes it. Returns at once when
  /// nothing is queued. Cancelled with the view that runs it.
  func waitForSelfApproval(appState: AppState) async {
    guard restoreQueued, let due = state?.selfApprovalDate else { return }
    let delay = due.timeIntervalSinceNow
    if delay > 0 {
      // A minute of slack covers the server's clock running a little behind this one.
      let seconds = min(delay + 60, 7 * 24 * 3600)
      do {
        try await Task.sleep(for: .seconds(seconds))
      } catch {
        return
      }
    }
    await finishSelfApprovalIfDue(appState: appState)
  }

  func approve(_ peer: DeviceApprovalPeer, appState: AppState) async {
    guard !isWorking else { return }
    isWorking = true
    failure = nil
    defer { isWorking = false }
    guard let coordinator = await appState.getOrOpenMLSCoordinator() else {
      failure = "Encrypted chat isn’t ready on this device yet. Try again in a moment."
      return
    }
    do {
      try await coordinator.approveDevice(targetDeviceId: peer.deviceId)
    } catch {
      logger.error("Approving \(String(peer.deviceId.prefix(8)), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
      failure = "Couldn’t approve \(peer.displayName): \(error.localizedDescription)"
    }
    await refresh(appState: appState)
  }
}
