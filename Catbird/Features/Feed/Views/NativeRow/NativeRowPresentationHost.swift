#if os(iOS)
import Observation
import OSLog
import Petrel
import SwiftUI

private let nativeRowModelsLogger = Logger(subsystem: "blue.catbird", category: "NativeFeedRow")

// MARK: - Native Row Post Models

/// The objects `PostView` owns for one post, created for a native feed row the first time the
/// row's options menu or action bar needs them: the state the menu's items and the presentations
/// read, the context menu's actions, the post's interaction view model, and the action bar's view
/// model. They are wired exactly as `PostView.setupPost` wires them, so the menu and the bar
/// behave as on the hosted row.
@MainActor
final class NativeRowPostModels {
  let postState: PostState
  let contextMenuViewModel: PostContextMenuViewModel
  let postViewModel: PostViewModel
  let actionViewModel: ActionButtonViewModel
  /// Reconciles the interaction view model with the shadow state, as `PostView` does when a row
  /// appears. Actions that toggle state wait for it, so a like or repost never starts from stale state.
  private var reconciliation: Task<Void, Never>?
  private var sourcePost: AppBskyFeedDefs.PostView?
  private var revision = 0
  private var isCancelled = false

  var uri: String { postState.currentPostBox.value.uri.uriString() }
  var cid: CID { postState.currentPostBox.value.cid }

  /// - Parameters:
  ///   - post: The feed payload the row was configured with. The view models and their
  ///     reconciliation with the shadow start from it, as `PostView.setupPost` does: reconciling
  ///     against a shadow-merged copy would read the shadow's own like or repost decision as the
  ///     server having caught up, retire it, and bring back a like or repost undone elsewhere.
  ///   - displayed: The shadow-merged copy the row shows; the menu's state starts from it.
  init(post: AppBskyFeedDefs.PostView, displayed: AppBskyFeedDefs.PostView, appState: AppState) {
    let state = PostState(postBox: EquatableBox(displayed), currentUserDid: appState.userDID)
    let viewModel = PostViewModel(post: post, appState: appState, visibilityContext: .public)
    let menuViewModel = PostContextMenuViewModel(
      appState: appState, post: post, allowsThreadSummary: false, visibilityContext: .public)
    postState = state
    postViewModel = viewModel
    contextMenuViewModel = menuViewModel
    actionViewModel = ActionButtonViewModel(
      postId: post.uri.uriString(), postViewModel: viewModel, appState: appState)

    menuViewModel.onReportPost = { state.showingReportView = true }
    menuViewModel.onAddAuthorToList = { state.showingAddToListSheet = true }
    menuViewModel.onToggleBookmark = { [weak self] in
      Task { [weak self] in
        guard let self else { return }
        await self.reconciled()
        do {
          try await viewModel.toggleBookmark()
        } catch {
          nativeRowModelsLogger.error("Failed to toggle bookmark: \(error.localizedDescription, privacy: .public)")
          if let message = UserFacingError.message(for: error, action: "update your bookmarks") {
            appState.toastManager.show(ToastItem(message: message, icon: "exclamationmark.triangle.fill"))
          }
        }
      }
    }
#if canImport(FoundationModels)
    menuViewModel.onSummarizeThread = {
      PostThreadSummarizer.summarize(state: state, appState: appState)
    }
#endif
    refresh(post: post, displayed: displayed, appState: appState)
  }

  /// Keeps presentation objects, but replaces their payload when the server refreshes viewer state.
  /// Each raw payload reconciles after the previous one, so an old actor hop cannot run after a
  /// newer reconciliation and acknowledge a fresh optimistic decision against stale server state.
  func refresh(post: AppBskyFeedDefs.PostView, displayed: AppBskyFeedDefs.PostView, appState: AppState) {
    guard !isCancelled, sourcePost != post else { return }
    let isRefresh = sourcePost != nil
    sourcePost = post
    revision += 1
    let requestedRevision = revision
    if isRefresh {
      postState.currentPost = displayed
      contextMenuViewModel.configure(appState: appState, post: displayed, visibilityContext: .public)
      postViewModel.configure(post: displayed, appState: appState, visibilityContext: .public)
    }
    let previous = reconciliation
    reconciliation = Task { [weak self] in
      await previous?.value
      guard let self, !self.isCancelled, !Task.isCancelled, self.revision == requestedRevision else { return }
      let merged = await appState.postShadowManager.reconcileAndMergeShadow(post: post, authoritative: isRefresh)
      guard !self.isCancelled, !Task.isCancelled, self.revision == requestedRevision else { return }
      self.postViewModel.configure(post: merged, appState: appState, visibilityContext: .public)
      self.postState.currentPost = merged
      self.contextMenuViewModel.configure(appState: appState, post: merged, visibilityContext: .public)
    }
  }

  /// Waits through any refresh that arrived while the previous reconciliation suspended.
  func reconciled() async {
    while !isCancelled {
      let waitingFor = revision
      await reconciliation?.value
      if waitingFor == revision { return }
    }
  }

  /// Stops the reconciliation and any thread summary still streaming.
  func cancel() {
    isCancelled = true
    reconciliation?.cancel()
    postState.threadSummaryTask?.cancel()
    postState.threadSummaryTask = nil
  }
}

// MARK: - Presentation Model

/// What the native rows of one feed are presenting: the options-menu presentations of the post
/// whose menu was opened last, and a share sheet.
@MainActor
@Observable
final class NativeRowPresentationModel {
  /// The post whose menu opened last. Its `PostState` flags drive the sheets and alerts.
  private(set) var active: NativeRowPostModels?
  /// The post a share destination was chosen for.
  private(set) var sharePost: EquatableBox<AppBskyFeedDefs.PostView>?
  var shareDestination: PostShareDestination?

  /// Makes `models` the post whose presentations are shown. Ignored while another post's sheet or
  /// alert is up, which a menu cannot open over anyway.
  func activate(_ models: NativeRowPostModels) {
    guard active !== models else { return }
    if let active, active.postState.hasPresentation { return }
    active = models
  }

  /// Shows the chat or system share sheet for `post`.
  func share(_ post: AppBskyFeedDefs.PostView, destination: PostShareDestination) {
    sharePost = EquatableBox(post)
    shareDestination = destination
  }

  /// Forgets the active post if it is not presenting anything, for example after it left the feed.
  func deactivate(unless keep: (NativeRowPostModels) -> Bool) {
    guard let active, !active.postState.hasPresentation, !keep(active) else { return }
    self.active = nil
  }
}

// MARK: - Presentation Host

/// The invisible SwiftUI view that presents native rows' sheets and alerts. A feed controller
/// hosts it once, at zero size and hidden from accessibility, so the options menu's Report, Add to
/// List, Block, Mute, Delete, Interaction Settings, Labels, Copilot and thread-summary items and the
/// share menu present exactly what the hosted row presents (`PostPresentationsModifier`,
/// `postShareSheet`).
///
/// The environment must provide `AppState` and `SceneNavigationContext`.
struct NativeRowPresentationHost: View {
  @Environment(AppState.self) private var appState
  @Bindable var model: NativeRowPresentationModel

  var body: some View {
    ZStack {
      if let active = model.active {
        Color.clear
          .modifier(PostPresentationsModifier(
            postState: active.postState, contextMenuViewModel: active.contextMenuViewModel,
            viewModel: active.postViewModel, visibilityContext: .public))
          .id(ObjectIdentifier(active))
      }
      if let sharePost = model.sharePost {
        Color.clear
          .postShareSheet(destination: $model.shareDestination, post: sharePost, appState: appState)
      }
    }
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}
#endif
