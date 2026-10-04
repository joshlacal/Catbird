import Foundation
import Observation

enum FeedPreferenceEdit: Equatable, Sendable {
  case replies(Bool), unfollowedReplies(Bool), minimumLikes(Int?), reposts(Bool), quotes(Bool)
}

/// A sparse edit stays pending until the account's server-first transaction succeeds.
@MainActor @Observable
final class FeedPreferenceEditor {
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
    guard !isLoading, !isSaving, pending == nil, isCurrentAccount() else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let value = try await read()
      guard !Task.isCancelled, isCurrentAccount() else { return }
      confirmed = value
      hasLoaded = true
      error = nil
    } catch {
      guard !Task.isCancelled, isCurrentAccount() else { return }
      self.error = "Couldn’t load Bluesky feed preferences. \(error.localizedDescription)"
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
      self.error = "This change hasn’t been confirmed by Bluesky. \(error.localizedDescription)"
    }
  }

  func discardAttempt() {
    guard !isSaving else { return }
    pending = nil
    confirmedAction = nil
    error = nil
  }
}
