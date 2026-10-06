import Foundation
import Observation
import Petrel

struct ScenePostComposerRequest: Identifiable {
  let id: UUID
  let initialText: String?
  let parentPost: AppBskyFeedDefs.PostView?
  let quotedPost: AppBskyFeedDefs.PostView?
  let editingClaim: ComposerDraftClaim?

  init(
    id: UUID = UUID(),
    initialText: String? = nil,
    parentPost: AppBskyFeedDefs.PostView? = nil,
    quotedPost: AppBskyFeedDefs.PostView? = nil,
    editingClaim: ComposerDraftClaim? = nil
  ) {
    self.id = id
    self.initialText = initialText
    self.parentPost = parentPost
    self.quotedPost = quotedPost
    self.editingClaim = editingClaim
  }
}

/// A request to open the Settings sheet at a specific screen (for example from a bsky.app/settings link).
struct SceneSettingsRequest: Identifiable {
  let id = UUID()
  let route: SettingsRoute
}

/// Navigation and presentation state for one authenticated account in one scene.
@MainActor
@Observable
final class SceneNavigationContext {
  let accountDID: String
  let sceneID: UUID
  /// Distinguishes replacement account contexts for asynchronous service lifecycle updates.
  let activityRegistrationID = UUID()
  let navigationManager: AppNavigationManager
  let urlHandler: URLHandler
  let composerEditingSession: SceneComposerEditingSession
  let feedViewportStore = FeedViewportStore()

  var pendingSearchRequest: AppState.SearchRequest?
  var tabTappedAgain: Int?
  var postComposerRequest: ScenePostComposerRequest?
  var settingsRequest: SceneSettingsRequest?
  private(set) var isInvalidated = false

  @ObservationIgnored private weak var appState: AppState?

  init(
    appState: AppState,
    sceneID: UUID,
    composerEditingSession: SceneComposerEditingSession? = nil
  ) {
    if let composerEditingSession {
      precondition(composerEditingSession.sceneID == sceneID)
      precondition(composerEditingSession.accountDID == appState.userDID)
    }
    self.appState = appState
    self.accountDID = appState.userDID
    self.sceneID = sceneID
    self.composerEditingSession = composerEditingSession
      ?? SceneComposerEditingSession(appState: appState, sceneID: sceneID)
    self.navigationManager = AppNavigationManager()
    self.urlHandler = URLHandler()
    self.urlHandler.configure(with: appState, navigationManager: self.navigationManager)
    // Settings destinations open the Settings sheet rather than being pushed into a tab's stack.
    self.navigationManager.settingsPresenter = { [weak self] route in
      self?.presentSettings(route)
    }
  }

  func presentSettings(_ route: SettingsRoute) {
    guard !isInvalidated, let appState, appState.userDID == accountDID else { return }
    settingsRequest = SceneSettingsRequest(route: route)
  }

  func presentPostComposer(
    initialText: String? = nil,
    parentPost: AppBskyFeedDefs.PostView? = nil,
    quotedPost: AppBskyFeedDefs.PostView? = nil
  ) {
    guard !isInvalidated, let appState, appState.userDID == accountDID else { return }
    postComposerRequest = ScenePostComposerRequest(
      initialText: initialText,
      parentPost: parentPost,
      quotedPost: quotedPost
    )
  }

  /// Retire an account's scene context before replacing or disconnecting it.
  func invalidate() {
    guard !isInvalidated else { return }
    isInvalidated = true
    composerEditingSession.invalidate()
    PendingChatShareStore.shared.discard(sceneID: sceneID, accountDID: accountDID)
    ChatDraftHandoff.shared.invalidate(sceneID: sceneID, accountDID: accountDID)
    urlHandler.invalidate()
    navigationManager.tabSelection = nil
    navigationManager.settingsPresenter = nil
    settingsRequest = nil
    pendingSearchRequest = nil
    tabTappedAgain = nil
    postComposerRequest = nil
    appState = nil
  }
}
