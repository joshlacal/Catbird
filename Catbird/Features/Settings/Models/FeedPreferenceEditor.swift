import Foundation
import Observation
import OSLog

enum FeedPreferenceEdit: Equatable, Sendable {
  case replies(Bool), unfollowedReplies(Bool), minimumLikes(Int?), reposts(Bool), quotes(Bool)
}

/// A sparse edit stays pending until the account's server-first transaction succeeds.
@MainActor @Observable
final class FeedPreferenceEditor {
  private static let logger = Logger(subsystem: "blue.catbird", category: "FeedPreferenceEditor")
  private(set) var confirmed: FeedViewPreference?
  private(set) var hasLoaded = false
  private(set) var isLoading = false
  private(set) var isSaving = false
  private(set) var pending: FeedPreferenceEdit?
  private(set) var error: String?
  private var confirmedAction: (@MainActor () -> Void)?
  private let accountDID: String
  @ObservationIgnored private let isCurrentAccount: @MainActor () -> Bool
  @ObservationIgnored private let read: @MainActor () async throws -> FeedViewPreference?
  @ObservationIgnored private let write: @MainActor (FeedPreferenceEdit, String) async throws -> FeedViewPreference?

  #if DEBUG
  enum DebugLoadRefusal: String, Sendable {
    case alreadyLoading, alreadySaving, pendingEdit, notCurrentAccount
  }
  struct DebugLoadEvent: Sendable {
    enum Phase: Sendable {
      case entered, refused(DebugLoadRefusal), readEntered, finished(refusal: DebugLoadRefusal?)
    }
    let editorID: UUID
    let attemptSequence: UInt64
    let phase: Phase
  }
  typealias DebugLoadObserver = @MainActor @Sendable (DebugLoadEvent) -> Void
  @ObservationIgnored private var debugLoadObserver: DebugLoadObserver?
  @ObservationIgnored private var debugEditorID: UUID?
  @ObservationIgnored private var debugAttemptSequence: UInt64 = 0

  /// Observation attaches to the unchanged production-configured editor.
  convenience init(appState: AppState, observingLoads: @escaping DebugLoadObserver) {
    self.init(appState: appState)
    debugEditorID = UUID()
    debugLoadObserver = observingLoads
  }

  private func beginDebugLoadObservation() -> UInt64? {
    guard debugLoadObserver != nil else { return nil }
    debugAttemptSequence += 1
    emitDebugLoad(debugAttemptSequence, phase: .entered)
    return debugAttemptSequence
  }
  private func emitDebugLoad(_ attempt: UInt64?, phase: DebugLoadEvent.Phase) {
    guard let attempt, let editorID = debugEditorID, let observer = debugLoadObserver else { return }
    observer(DebugLoadEvent(editorID: editorID, attemptSequence: attempt, phase: phase))
  }
  #endif

  convenience init(appState: AppState) {
    let did = appState.userDID
    let revision = AppStateManager.shared.settingsAccountContextRevision
    let clientIdentity = appState.atProtoClient.map(ObjectIdentifier.init)
    self.init(accountDID: did, isCurrentAccount: {
      let manager = AppStateManager.shared
      return manager.lifecycle.isAuthenticated && manager.lifecycle.appState === appState
        && manager.lifecycle.userDID == did && manager.settingsAccountContextRevision == revision
        && appState.atProtoClient.map(ObjectIdentifier.init) == clientIdentity
    }, read: {
      try await appState.preferencesManager.refreshSettingsPreferences().feedViewPref
    }, write: { edit, did in
      let manager = appState.preferencesManager
      switch edit {
      case .replies(let value): try await manager.setFeedViewPreferences(hideReplies: value, expectedAccountDID: did)
      case .unfollowedReplies(let value): try await manager.setFeedViewPreferences(hideRepliesByUnfollowed: value, expectedAccountDID: did)
      case .minimumLikes(let value): try await manager.setFeedViewPreferences(hideRepliesByLikeCount: value, clearReplyLikeThreshold: value == nil, expectedAccountDID: did)
      case .reposts(let value): try await manager.setFeedViewPreferences(hideReposts: value, expectedAccountDID: did)
      case .quotes(let value): try await manager.setFeedViewPreferences(hideQuotePosts: value, expectedAccountDID: did)
      }
      return try await manager.getPreferences().feedViewPref
    })
  }

  init(accountDID: String,
       isCurrentAccount: @escaping @MainActor () -> Bool,
       read: @escaping @MainActor () async throws -> FeedViewPreference?,
       write: @escaping @MainActor (FeedPreferenceEdit, String) async throws -> FeedViewPreference?) {
    self.accountDID = accountDID
    self.isCurrentAccount = isCurrentAccount
    self.read = read
    self.write = write
  }

  func load() async {
    #if DEBUG
    let attempt = beginDebugLoadObservation()
    var refusal: DebugLoadRefusal?
    defer { emitDebugLoad(attempt, phase: .finished(refusal: refusal)) }
    // Keep the original guard's evaluation order and exactly one account proof.
    guard !isLoading else {
      refusal = .alreadyLoading; emitDebugLoad(attempt, phase: .refused(.alreadyLoading)); return
    }
    guard !isSaving else {
      refusal = .alreadySaving; emitDebugLoad(attempt, phase: .refused(.alreadySaving)); return
    }
    guard pending == nil else {
      refusal = .pendingEdit; emitDebugLoad(attempt, phase: .refused(.pendingEdit)); return
    }
    guard isCurrentAccount() else {
      refusal = .notCurrentAccount; emitDebugLoad(attempt, phase: .refused(.notCurrentAccount)); return
    }
    #else
    guard !isLoading, !isSaving, pending == nil, isCurrentAccount() else { return }
    #endif
    isLoading = true
    defer { isLoading = false }
    do {
      #if DEBUG
      emitDebugLoad(attempt, phase: .readEntered)
      #endif
      let value = try await read()
      guard !Task.isCancelled, isCurrentAccount() else { return }
      confirmed = value
      hasLoaded = true
      error = nil
    } catch {
      guard !Task.isCancelled, isCurrentAccount() else { return }
      Self.logger.error("Feed preference load failed: \(error.localizedDescription, privacy: .public)")
      self.error = UserFacingError.message(for: error, action: "load your feed preferences") ?? "Couldn’t load your feed preferences. Try again."
    }
  }

  func submit(_ edit: FeedPreferenceEdit, afterConfirmation: (@MainActor () -> Void)? = nil) async {
    guard hasLoaded, !isSaving, pending == nil, isCurrentAccount() else { return }
    pending = edit
    confirmedAction = afterConfirmation
    await retry()
  }

  func retry() async {
    guard let pending, !isSaving, isCurrentAccount() else { return }
    isSaving = true
    defer { isSaving = false }
    do {
      let value = try await write(pending, accountDID)
      guard !Task.isCancelled, isCurrentAccount() else { return }
      confirmed = value
      confirmedAction?()
      confirmedAction = nil
      self.pending = nil
      error = nil
      NotificationCenter.default.post(name: NSNotification.Name("FeedPreferencesChanged"), object: self,
        userInfo: ["accountDID": accountDID])
    } catch {
      guard !Task.isCancelled, isCurrentAccount() else { return }
      Self.logger.error("Feed preference save failed: \(error.localizedDescription, privacy: .public)")
      self.error = UserFacingError.message(for: error, action: "save this change") ?? "Couldn’t save this change. Try again."
    }
  }

  func discardAttempt() {
    guard !isSaving else { return }
    pending = nil
    confirmedAction = nil
    error = nil
  }
}
