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

  var uri: String { postState.currentPostBox.value.uri.uriString() }
  var cid: CID { postState.currentPostBox.value.cid }

  /// - Parameter post: The shadow-merged post, so the menu's bookmark item and the view model's
  ///   like and repost state start from what the row shows.
  init(post: AppBskyFeedDefs.PostView, appState: AppState) {
    let state = PostState(postBox: EquatableBox(post), currentUserDid: appState.userDID)
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
    menuViewModel.onToggleBookmark = {
      Task {
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
    reconciliation = Task {
      if let merged = await viewModel.start(post: post), merged != state.currentPost {
        state.currentPost = merged
      }
    }
  }

  /// Waits until the interaction view model reflects the shadow state.
  func reconciled() async {
    await reconciliation?.value
  }

  /// Stops the reconciliation and any thread summary still streaming.
  func cancel() {
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
