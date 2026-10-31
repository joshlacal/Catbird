import Foundation
import Observation

/// The Follow button's write state for one profile screen.
///
/// The button flips on tap and the write runs behind it. The state lives on the screen's view
/// model, not in ProfileHeader's `@State`, because the header sits in a recycled list cell
/// whose state resets whenever the cell is reused or the screen comes back from a push.
///
/// After a successful write the header reloads `refreshDelay` later so the counts and
/// `viewer.following` catch up. If the AppView has not indexed the write by then, that reload
/// still shows the old relationship; for `holdDuration` after the write the button keeps what
/// the user chose, so it cannot flip back and invite a second follow record.
@MainActor
@Observable
final class ProfileFollowWrites {
  static let holdDuration: TimeInterval = 5
  static let refreshDelay: Duration = .milliseconds(500)

  /// Bumped when a write ends, so a header rebuilt during the write re-reads the button state.
  private(set) var revision = 0
  /// A follow or unfollow write is in flight; taps are ignored until it ends.
  @ObservationIgnored private(set) var isWriteInFlight = false
  @ObservationIgnored private var intent: Intent?
  @ObservationIgnored private var refreshTask: Task<Void, Never>?

  /// Starts a write, or returns false while another is still in flight. A header reload still
  /// waiting from an earlier write is cancelled; this write schedules its own.
  func begin(following: Bool, now: Date = Date()) -> Bool {
    guard !isWriteInFlight else { return false }
    isWriteInFlight = true
    intent = Intent(isFollowing: following, since: now)
    cancelPendingRefresh()
    return true
  }

  /// Ends the write. A success holds the chosen state for `holdDuration` from now; a failure
  /// drops it, so the button goes back to what the profile says.
  func end(success: Bool, now: Date = Date()) {
    isWriteInFlight = false
    if success, let intent {
      self.intent = Intent(isFollowing: intent.isFollowing, since: now)
    } else {
      intent = nil
    }
    revision &+= 1
  }

  /// What the button shows, given whether the loaded profile says the viewer follows it.
  func isFollowing(serverSays: Bool, now: Date = Date()) -> Bool {
    guard let intent else { return serverSays }
    if isWriteInFlight { return intent.isFollowing }
    let heldFor: TimeInterval = now.timeIntervalSince(intent.since)
    // Drop the hold once the AppView has caught up, or once it has run out.
    if serverSays == intent.isFollowing || heldFor >= Self.holdDuration {
      self.intent = nil
      return serverSays
    }
    return intent.isFollowing
  }

  /// Runs `refresh` after `refreshDelay`, replacing any reload still waiting.
  func scheduleRefresh(_ refresh: @escaping @MainActor () async -> Void) {
    refreshTask?.cancel()
    refreshTask = Task {
      try? await Task.sleep(for: Self.refreshDelay)
      guard !Task.isCancelled else { return }
      await refresh()
    }
  }

  func cancelPendingRefresh() {
    refreshTask?.cancel()
    refreshTask = nil
  }

  isolated deinit {
    refreshTask?.cancel()
  }

  private struct Intent {
    let isFollowing: Bool
    let since: Date
  }
}
