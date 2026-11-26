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
  private(set) var failure: DeviceApprovalFailure?

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
    var queued = false
    if let loaded, loaded.isPending,
       let coordinator = await appState.getOrOpenMLSCoordinator(),
       let status = try? await coordinator.labyrinthStatus() {
      queued = status.pendingDirectoryEpoch != nil
    }
    // Set both together, so the view never sees a brief "nothing queued" that would restart
    // the self-approval task and publish again in a loop.
    state = loaded
    restoreQueued = queued
  }

  /// When the last automatic publish of the queued restore ran. Automatic tries wait
  /// `autoRetryInterval` between them; Check Again doesn't.
  @ObservationIgnored private var lastAutoFlush: Date?
  @ObservationIgnored private let autoRetryInterval: TimeInterval = 30

  /// Publishes the queued restore again, then reads the state again. A restore made with the
  /// recovery code or passkey proves this device, so the server approves it at once and the
  /// wait banner goes away. A restore with nothing to chain to still waits for the server's
  /// hold, and the publish is just refused again until then.
  ///
  /// - Parameter force: true for the person's own Check Again, which skips the spacing
  ///   between automatic tries.
  func finishQueuedRestore(appState: AppState, force: Bool = false, now: Date = Date()) async {
    guard restoreQueued, let state, state.isPending else { return }
    if !force, let last = lastAutoFlush, now.timeIntervalSince(last) < autoRetryInterval {
      return
    }
    lastAutoFlush = now
    guard let coordinator = await appState.getOrOpenMLSCoordinator() else { return }
    do {
      _ = try await coordinator.flushLabyrinthQueue()
    } catch {
      logger.error("Queued restore publish failed: \(error.localizedDescription, privacy: .public)")
    }
    await refresh(appState: appState)
  }

  /// Publishes a queued restore at once, and if the server still holds it, tries again when
  /// the hold ends. Returns at once when nothing is queued. Cancelled with the view that runs it.
  func waitForSelfApproval(appState: AppState) async {
    guard restoreQueued else { return }
    await finishQueuedRestore(appState: appState)
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
    await finishQueuedRestore(appState: appState, force: true)
  }

  func approve(_ peer: DeviceApprovalPeer, appState: AppState) async {
    guard !isWorking else { return }
    isWorking = true
    failure = nil
    defer { isWorking = false }
    guard let coordinator = await appState.getOrOpenMLSCoordinator() else {
      failure = .notReady
      return
    }
    do {
      try await coordinator.approveDevice(targetDeviceId: peer.deviceId)
    } catch {
      logger.error("Approving \(String(peer.deviceId.prefix(8)), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
      failure = DeviceApprovalFailure(error: error, deviceName: peer.displayName)
    }
    await refresh(appState: appState)
  }
}
