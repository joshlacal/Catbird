import Foundation
import Observation
import Petrel

struct ScenePostComposerRequest: Identifiable {
  let id: UUID
  let initialText: String?
  let parentPost: AppBskyFeedDefs.PostView?
  let quotedPost: AppBskyFeedDefs.PostView?

  init(
    id: UUID = UUID(),
    initialText: String? = nil,
    parentPost: AppBskyFeedDefs.PostView? = nil,
    quotedPost: AppBskyFeedDefs.PostView? = nil
  ) {
    self.id = id
    self.initialText = initialText
    self.parentPost = parentPost
    self.quotedPost = quotedPost
  }
}

/// Navigation and presentation state for one authenticated account in one scene.
@MainActor
@Observable
final class SceneNavigationContext {
  let accountDID: String
  let sceneID: UUID
  let navigationManager: AppNavigationManager
  let urlHandler: URLHandler

  var pendingSearchRequest: AppState.SearchRequest?
  var tabTappedAgain: Int?
  var postComposerRequest: ScenePostComposerRequest?
  private(set) var isInvalidated = false

  @ObservationIgnored private weak var appState: AppState?

  init(appState: AppState, sceneID: UUID) {
    self.appState = appState
    self.accountDID = appState.userDID
    self.sceneID = sceneID
    self.navigationManager = AppNavigationManager()
    self.urlHandler = URLHandler()
    self.urlHandler.configure(with: appState, navigationManager: self.navigationManager)
  }

  func presentPostComposer(
    initialText: String? = nil,
    parentPost: AppBskyFeedDefs.PostView? = nil,
    quotedPost: AppBskyFeedDefs.PostView? = nil
  ) {
    guard !isInvalidated, let appState, appState.userDID == accountDID else { return }
    if let quotedPost {
      appState.feedFeedbackManager.trackQuote(postURI: quotedPost.uri)
    }
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
    urlHandler.invalidate()
    navigationManager.tabSelection = nil
    pendingSearchRequest = nil
    tabTappedAgain = nil
    postComposerRequest = nil
    appState = nil
  }
}
