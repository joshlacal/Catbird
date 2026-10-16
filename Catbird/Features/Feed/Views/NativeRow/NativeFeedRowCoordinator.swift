#if os(iOS)
import OSLog
import Petrel
import SwiftUI
import UIKit

private let coordinatorLogger = Logger(subsystem: "blue.catbird", category: "NativeFeedRow")

// MARK: - Native Feed Row Coordinator

/// The feed controller's half of native rows: decides which posts render natively, builds what a
/// `NativeFeedPostCell` draws and does, prepares rows ahead of display, and hosts the sheets and
/// alerts the rows' menus present. One per feed controller.
///
/// Decisions and prepared rows are computed once per post and kept while the post's content
/// signature and the row settings (moderation policy, fonts, link style, badge preference, theme
/// colours, size class) stay the same. The controller calls `beginSnapshot` before every snapshot it
/// applies, so cells configured between snapshots read the settings that snapshot captured.
///
/// Rows about to scroll in are prepared off the main actor (`prepareRows`): their decisions, the
/// attributed text, header and count strings, layouts and time strings. Configuring a prepared
/// row then only looks these up. What stays on the main actor, and why:
/// - reading the SwiftData post and its decoded entry (`NativeFeedRowSupport.Entry`), since the
///   model belongs to the main actor;
/// - the relative time text, computed again at configuration so a row whose minute ticked over
///   since it was prepared shows the new time (it then gets a layout for the new text);
/// - the action bar's state, which reads live counts, the share origin and the signed-in account;
/// - the header labels' attributed strings: `FeedPostHeaderLineView.configure` builds three short
///   ones from the prepared name, handle and time strings as it fills its labels, which are views
///   and belong to the main actor; they are cheap, and carrying them through the preparation would
///   only move their construction, not the label updates.
///
/// `preparer` holds the preparation queue and batches; the coordinator is its source of posts and
/// signatures and stores what it prepares.
@MainActor
final class NativeFeedRowCoordinator {
  /// How one post renders.
  enum Decision: Sendable {
    case native(Row)
    case hosted(NativeFeedRowSupport.Reason)
  }

  /// A post the native cell supports, with everything that does not change with the clock or the
  /// width already resolved.
  /// `@unchecked Sendable`: an immutable value; the attributed text, with its fonts and colours,
  /// is never mutated after `decide` builds it, so a row decided off the main actor can be handed
  /// to it.
  struct Row: @unchecked Sendable {
    let postID: String
    let post: AppBskyFeedDefs.PostView
    let createdAt: Date
    /// Empty when the author's display name is blank (`PostHeaderView` then shows only the handle).
    let displayName: String
    let handle: String
    /// `nil` for a blank display name and when badges are hidden, as on the hosted row.
    let verification: VerificationBadgeKind?
    let text: NSAttributedString
    let signature: FeedPostContentSignature
    /// The post's reply, repost and like counts as the action bar draws them.
    let counts: FeedActionBarCounts
    /// Whether the post has a share link (`ActionButtonViewModel.shareURL`); its author and URI
    /// do not change with live counts.
    let canCopyLink: Bool
    /// The author's avatar (`finalAvatarURL()`).
    let avatarURL: URL?
  }

  // MARK: - State

  private let navigationPath: Binding<NavigationPath>
  private var appState: AppState
  private var sceneContext: SceneNavigationContext
  private var feedInteractionTarget: FeedInteractionTarget?

  let layoutStore: FeedRowLayoutStore
  private let presentationModel = NativeRowPresentationModel()
  private var presentationHost: UIHostingController<AnyView>?

  private var settings: Settings?
  /// The collection view's traits at the last snapshot, to re-resolve settings when they change.
  private var traits: UITraitCollection?
  private var posts: [String: CachedFeedViewPost] = [:]
  private var signatures: [String: FeedPostContentSignature] = [:]
  private var decisions: [String: (signature: FeedPostContentSignature, decision: Decision)] = [:]
  /// Whether each post item's cell was last dequeued as a native cell. A reconfigure must dequeue
  /// the same kind of cell, so items whose kind changes are reloaded instead.
  private var dequeuedAsNative: [String: Bool] = [:]
  /// The latest shadow-merged post per URI, from the rows' live-count streams.
  private var mergedPosts: [String: AppBskyFeedDefs.PostView] = [:]
  /// The feed items (post IDs) whose rows recorded live counts or created models for each URI;
  /// both are kept while one of these items is in the snapshot.
  private var rowPostIDsByURI: [String: Set<String>] = [:]
  /// Created the first time a row's menu or action bar needs them, per post URI.
  private var postModels: [String: NativeRowPostModels] = [:]
  /// The width cells actually have when it differs from the collection view's width, keyed by the
  /// collection view's width (reported through `NativeFeedRowActions.layoutWidthChanged`).
  private var cellWidths: [CGFloat: CGFloat] = [:]
  private var pendingReconfigure: Set<String> = []
  /// The width each post last asked to be reconfigured for, per collection view width (see
  /// `cellWidthChanged`).
  private var requestedCellWidths: [WidthRequest: CGFloat] = [:]
  private var settingsObserver: UIKitStateObserver<AppState>?
  private var policyObserver: NSObjectProtocol?
  private var observedFingerprint: SettingsFingerprint?
  /// The inputs the current settings were resolved from.
  private var settingsInputs: SettingsInputs?
  /// How many times the row settings were resolved; settings are rebuilt only when an input changed.
  private(set) var settingsResolutionCount = 0

  // MARK: - Preparation State

  /// Prepares rows off the main actor ahead of display (`prepareRows`).
  let preparer: NativeFeedRowPreparer
  /// Each native post's time strings as last computed, by preparation or configuration.
  private var rowTimes: [String: NativeFeedRowPreparation.RowTime] = [:]
  /// How many decisions were made on the main actor, because no preparation had made them yet.
  private(set) var mainActorDecisionCount = 0
  /// How the current feed's posts render, for the device's reason distribution.
  let decisionCounter = NativeFeedRowDecisionCounter()

  /// The collection view native rows are laid out in.
  weak var collectionView: UICollectionView?
  /// Asks the controller for a snapshot that reconfigures the posts `takeReconfigureRequest` reports.
  var onNeedsReconfigure: (() -> Void)?
  /// Asks the controller to reconfigure every row because a setting rows read changed.
  var onSettingsChanged: (() -> Void)?

  /// `prepareBatch` prepares each batch of rows; the default runs on a background thread.
  init(
    navigationPath: Binding<NavigationPath>, appState: AppState, sceneContext: SceneNavigationContext,
    prepareBatch: @escaping NativeFeedRowPreparer.Runner = { await NativeFeedRowPreparation.run($0) }
  ) {
    self.navigationPath = navigationPath
    self.appState = appState
    self.sceneContext = sceneContext
    layoutStore = FeedRowLayoutStore()
    preparer = NativeFeedRowPreparer(run: prepareBatch)
    preparer.delegate = self
  }

  isolated deinit {
    postModels.values.forEach { $0.cancel() }
    if let policyObserver { NotificationCenter.default.removeObserver(policyObserver) }
  }

  // MARK: - Environment

  /// Points rows at the account, scene and feed the controller currently shows.
  func update(appState: AppState, sceneContext: SceneNavigationContext, feedInteractionTarget: FeedInteractionTarget?) {
    let accountChanged = appState !== self.appState
    let sceneChanged = sceneContext !== self.sceneContext
    self.appState = appState
    self.sceneContext = sceneContext
    self.feedInteractionTarget = feedInteractionTarget
    if accountChanged {
      resolveSettingsIfNeeded()
      preparer.discardAll()
      decisionCounter.reset()
      decisions.removeAll()
      rowTimes.removeAll()
      mergedPosts.removeAll()
      rowPostIDsByURI.removeAll()
      postModels.values.forEach { $0.cancel() }
      postModels.removeAll()
      startObservingSettings()
    }
    if accountChanged || sceneChanged { refreshPresentationHost() }
  }

  // MARK: - Snapshots

  /// Captures the posts and row settings of the update about to be evaluated, on every update,
  /// including those that end up applying no snapshot; it therefore only stores what the item
  /// provider reads and rebuilds the settings only when one of their inputs changed. Decisions for
  /// posts whose content or settings changed are recomputed on next use.
  func beginSnapshot(
    posts: [String: CachedFeedViewPost], signatures: [String: FeedPostContentSignature], traits: UITraitCollection
  ) {
    self.traits = traits
    resolveSettingsIfNeeded()
    self.posts = posts
    self.signatures = signatures
  }

  /// Forgets what belonged to posts that left the feed, once a snapshot without them is applied:
  /// their decisions, dequeue records, pending reconfigures, live counts, models and menu target.
  /// Live counts and models are kept by the feed items that recorded them, so neither a cleared
  /// decision cache nor a post that is not decoded affects them.
  func didApplySnapshot() {
    decisions = decisions.filter { posts[$0.key] != nil }
    dequeuedAsNative = dequeuedAsNative.filter { posts[$0.key] != nil }
    pendingReconfigure = pendingReconfigure.filter { posts[$0] != nil }
    requestedCellWidths = requestedCellWidths.filter { posts[$0.key.postID] != nil }
    rowTimes = rowTimes.filter { posts[$0.key] != nil }
    preparer.snapshotDidChange()

    guard !rowPostIDsByURI.isEmpty else { return }
    rowPostIDsByURI = rowPostIDsByURI.compactMapValues { postIDs in
      let remaining = postIDs.filter { posts[$0] != nil }
      return remaining.isEmpty ? nil : remaining
    }
    let uris = Set(rowPostIDsByURI.keys)
    mergedPosts = mergedPosts.filter { uris.contains($0.key) }
    for (uri, models) in postModels where !uris.contains(uri) {
      models.cancel()
      postModels[uri] = nil
    }
    presentationModel.deactivate { uris.contains($0.uri) }
  }

  /// The collection view's traits changed outside a snapshot (a size class or display scale
  /// change). Returns whether the row settings changed, in which case visible rows need new layouts.
  func updateTraits(_ traits: UITraitCollection) -> Bool {
    self.traits = traits
    return resolveSettingsIfNeeded()
  }

  /// How the post with `postID` renders in the current snapshot.
  func decision(forPostID postID: String) -> Decision? {
    guard let cached = posts[postID], let signature = signatures[postID], let settings else { return nil }
    if let entry = decisions[postID], entry.signature == signature { return entry.decision }
    let decision = Self.decide(
      postID: postID, entry: NativeFeedRowSupport.Entry(cached), signature: signature, settings: settings)
    mainActorDecisionCount += 1
    record(decision, forPostID: postID, signature: signature)
    return decision
  }

  private func record(_ decision: Decision, forPostID postID: String, signature: FeedPostContentSignature) {
    decisions[postID] = (signature, decision)
    decisionCounter.record(NativeFeedRowDecisionCounter.Outcome(decision))
  }

  /// The prepared row for `postID`, if it renders natively.
  func nativeRow(forPostID postID: String) -> Row? {
    if case .native(let row)? = decision(forPostID: postID) { return row }
    return nil
  }

  /// Records which kind of cell the item was dequeued as.
  func recordDequeue(postID: String, native: Bool) {
    dequeuedAsNative[postID] = native
  }

  /// Whether reconfiguring the item would need a different kind of cell than it has, in which case
  /// the item must be reloaded rather than reconfigured.
  func cellKindChanges(postID: String) -> Bool {
    guard let wasNative = dequeuedAsNative[postID] else { return false }
    return wasNative != (nativeRow(forPostID: postID) != nil)
  }

  /// Whether a native row asked to be reconfigured since the last snapshot; clears the request.
  func takeReconfigureRequest(postID: String) -> Bool {
    pendingReconfigure.remove(postID) != nil
  }

  // MARK: - Row Content

  /// The width native rows are laid out at for a collection view of `boundsWidth`.
  func layoutWidth(forBoundsWidth boundsWidth: CGFloat) -> CGFloat {
    cellWidths[boundsWidth] ?? boundsWidth
  }

  var typography: FeedRowTypography? { settings?.typography }

  /// What a native cell shows for `row` at `width`. For a prepared row this only looks up what the
  /// preparation computed; the time text is computed again, so a minute that ticked over since
  /// shows (with a layout for the new text).
  func content(for row: Row, width: CGFloat) -> NativeFeedRowContent? {
    guard let settings else { return nil }
    let time = currentTime(for: row)
    let layout = layoutStore.layout(
      for: Self.layoutInput(for: row, width: width, timeText: time.text, settings: settings))
    preparer.markConfigured(postID: row.postID, signature: row.signature, width: width)
    let displayed = mergedPosts[row.post.uri.uriString()] ?? row.post
    return NativeFeedRowContent(
      post: row.post, layout: layout, text: row.text, displayName: row.displayName, handle: row.handle,
      timeText: time.text, timeAccessibilityLabel: time.accessibilityLabel,
      verification: row.verification, actionBarState: actionBarState(for: displayed, row: row, settings: settings),
      metadataColor: settings.colors.metadata, actionBarCounts: row.counts, avatarURL: row.avatarURL)
  }

  /// The row's time strings now: the last ones computed for it while they still hold, new ones
  /// otherwise.
  private func currentTime(for row: Row) -> NativeFeedRowPreparation.RowTime {
    let timeText = shortTimeAgoString(from: row.createdAt)
    if let known = rowTimes[row.postID], known.isCurrent(createdAt: row.createdAt, timeText: timeText) {
      return known
    }
    let time = NativeFeedRowPreparation.RowTime(
      createdAt: row.createdAt, text: timeText,
      accessibilityLabel: formatTimeAgo(from: row.createdAt, forAccessibility: true))
    rowTimes[row.postID] = time
    return time
  }

  nonisolated static func layoutInput(
    for row: Row, width: CGFloat, timeText: String, settings: Settings
  ) -> FeedRowLayoutInput {
    FeedRowLayoutInput(
      postID: row.postID, width: width, typography: settings.typography, displayName: row.displayName,
      handle: row.handle, timeText: timeText, verificationSymbol: row.verification?.symbolName, text: row.text,
      contentSignature: row.signature, maxContentWidth: settings.maxContentWidth,
      displayScale: settings.displayScale)
  }

  /// The action bar's state for `post`, the row's post or its shadow-merged copy (same author and
  /// URI, so the row's share link applies).
  private func actionBarState(for post: AppBskyFeedDefs.PostView, row: Row, settings: Settings) -> FeedActionBarState {
    FeedActionBarState(
      postURI: post.uri.uriString(), replyCount: post.replyCount ?? 0,
      isReplyDisabled: post.viewer?.replyDisabled ?? false, repostCount: post.repostCount ?? 0,
      isReposted: post.viewer?.repost != nil, isQuoteDisabled: post.viewer?.embeddingDisabled ?? false,
      likeCount: post.likeCount ?? 0, isLiked: post.viewer?.like != nil, isShareEnabled: isValidShareOrigin,
      canSendViaChat: appState.isAuthenticated, canCopyLink: row.canCopyLink,
      reduceMotion: settings.reduceMotion, fonts: settings.actionBarFonts)
  }

  // MARK: - Preparation

  /// Prepares the rows of `postIDs` off the main actor for a collection view `boundsWidth` wide:
  /// decisions, attributed text, header and count strings, layouts and time strings, so the cells
  /// that show them only look them up. Posts already prepared for their content, the current
  /// settings and this width are skipped. The main actor never waits for the work: a cell
  /// configured before its row is prepared builds the row itself, and the preparation's result for
  /// it is then not needed.
  func prepareRows(forPostIDs postIDs: [String], boundsWidth: CGFloat) {
    guard settings != nil, boundsWidth > 0 else { return }
    preparer.prepare(postIDs, width: layoutWidth(forBoundsWidth: boundsWidth))
  }

  /// The controller shows another feed: preparation stops, what was prepared is forgotten and the
  /// decision counts start over. Cached decisions and layouts stay; they are keyed by everything
  /// they depend on.
  func feedDidReset() {
    preparer.discardAll()
    decisionCounter.reset()
  }

  /// Drops every cached layout and what was prepared; fonts, text size or the width changed.
  func invalidateLayouts(includingCellWidths: Bool = false) {
    preparer.discardAll()
    layoutStore.invalidateAll()
    if includingCellWidths {
      cellWidths.removeAll()
      requestedCellWidths.removeAll()
    }
  }

  /// A native cell is sized to a width its layout was not computed for. Records the width cells
  /// have, so every later layout (prepared or configured) uses it, and asks once per post and width
  /// for a reconfigure of the item. A reconfigure that applies a layout for the reported width ends
  /// the exchange; a post reporting the same width again is not asked for twice, so insets that
  /// keep cells narrower than the collection view cannot cause a loop.
  private func cellWidthChanged(postID: String, to width: CGFloat) {
    guard let boundsWidth = collectionView?.bounds.width, boundsWidth > 0, width > 0 else { return }
    cellWidths[boundsWidth] = abs(width - boundsWidth) < 0.01 ? nil : width
    let request = WidthRequest(postID: postID, boundsWidth: boundsWidth)
    guard requestedCellWidths[request] != width else { return }
    requestedCellWidths[request] = width
    if pendingReconfigure.insert(postID).inserted { onNeedsReconfigure?() }
  }

  // MARK: - Actions

  func actions(for row: Row) -> NativeFeedRowActions {
    let postID = row.postID
    return NativeFeedRowActions(
      openPost: { [weak self] post in self?.openPost(post) },
      openProfile: { [weak self] did in self?.navigationPath.wrappedValue.append(NavigationDestination.profile(did)) },
      openLink: { [weak self] url in self?.openLink(url) },
      actionBar: { [weak self] post in
        self?.actionBarActions(for: post, postID: postID) ?? Self.inertActionBarActions
      },
      optionsMenu: { [weak self] post in self?.optionsMenu(for: post, postID: postID) ?? [] },
      layoutWidthChanged: { [weak self] _, width in self?.cellWidthChanged(postID: postID, to: width) })
  }

  private func openPost(_ post: AppBskyFeedDefs.PostView) {
    ThreadManager.storePrefillPost(post, userDID: appState.userDID)
    navigationPath.wrappedValue.append(NavigationDestination.post(post.uri))
  }

  private func openLink(_ url: URL) {
    switch sceneContext.urlHandler.outcome(for: url) {
    case .openInSystem: UIApplication.shared.open(url)
    case .handled, .discarded: break
    }
  }

  private var isValidShareOrigin: Bool {
    !sceneContext.isInvalidated && sceneContext.accountDID == appState.userDID
  }

  /// The handlers `ActionButtonsView.actionBarActions` builds for the hosted row.
  private func actionBarActions(for post: AppBskyFeedDefs.PostView, postID: String) -> FeedActionBarActions {
    let uri = post.uri.uriString()
    return FeedActionBarActions(
      reply: { [weak self] in
        guard let self, self.isValidShareOrigin else { return }
        let displayed = self.displayedPost(uri: uri, fallback: post)
        self.appState.feedFeedbackManager.trackReply(postURI: displayed.uri, target: self.feedInteractionTarget)
        self.sceneContext.presentPostComposer(initialText: nil, parentPost: displayed, quotedPost: nil)
      },
      toggleRepost: { [weak self] in
        guard let self else { return }
        PlatformHaptics.medium()
        let models = self.postModels(for: post, postID: postID)
        let target = self.feedInteractionTarget
        Task { [weak self] in
          await models.reconciled()
          let wasReposted = models.postViewModel.isReposted
          do {
            try await models.actionViewModel.toggleRepost(feedInteractionTarget: target)
          } catch {
            coordinatorLogger.error("Error toggling repost: \(error.localizedDescription, privacy: .public)")
            self?.showFailureToast(for: error, action: wasReposted ? "remove your repost" : "repost this post")
          }
        }
      },
      quote: { [weak self] in
        guard let self, self.isValidShareOrigin else { return }
        let displayed = self.displayedPost(uri: uri, fallback: post)
        self.appState.feedFeedbackManager.trackQuote(postURI: displayed.uri, target: self.feedInteractionTarget)
        self.sceneContext.presentPostComposer(initialText: nil, parentPost: nil, quotedPost: displayed)
      },
      toggleLike: { [weak self] in
        guard let self else { return }
        PlatformHaptics.medium()
        let models = self.postModels(for: post, postID: postID)
        let target = self.feedInteractionTarget
        Task { [weak self] in
          await models.reconciled()
          let wasLiked = models.postViewModel.isLiked
          do {
            try await models.actionViewModel.toggleLike(feedInteractionTarget: target)
          } catch {
            coordinatorLogger.error("Error toggling like: \(error.localizedDescription, privacy: .public)")
            self?.showFailureToast(for: error, action: wasLiked ? "remove your like" : "like this post")
          }
        }
      },
      sendViaChat: { [weak self] in
        guard let self, self.isValidShareOrigin else { return }
        self.presentationModel.share(
          self.displayedPost(uri: uri, fallback: post),
          destination: PostShareDestination(kind: .chat, sceneContext: self.sceneContext))
      },
      copyLink: { [weak self] in
        guard let self, self.isValidShareOrigin, let url = ActionButtonViewModel.shareURL(for: post) else { return }
        PostShareDestination.copyLink(url, appState: self.appState)
      },
      moreSharing: { [weak self] in
        guard let self, self.isValidShareOrigin else { return }
        self.presentationModel.share(
          self.displayedPost(uri: uri, fallback: post),
          destination: PostShareDestination(kind: .native, sceneContext: self.sceneContext))
      })
  }

  private static let inertActionBarActions = FeedActionBarActions(
    reply: {}, toggleRepost: {}, quote: {}, toggleLike: {}, sendViaChat: {}, copyLink: {}, moreSharing: {})

  private func showFailureToast(for error: Error, action: String) {
    guard let message = UserFacingError.message(for: error, action: action) else { return }
    appState.toastManager.show(ToastItem(message: message, icon: "exclamationmark.triangle.fill"))
  }

  /// The options menu for `post`. Opening it makes the post's models the ones the presentation
  /// host presents for, so the menu's sheets and alerts belong to this post.
  private func optionsMenu(for post: AppBskyFeedDefs.PostView, postID: String) -> [UIMenuElement] {
    let models = postModels(for: post, postID: postID)
    presentationModel.activate(models)
    let context = PostOptionsMenuContext(
      postState: models.postState, contextMenuViewModel: models.contextMenuViewModel,
      viewModel: models.postViewModel, appState: appState, feedInteractionTarget: feedInteractionTarget,
      visibilityContext: .public)
    return PostOptionsMenuBuilder.elements(post: models.postState.currentPost, context: context)
  }

  private func displayedPost(uri: String, fallback: AppBskyFeedDefs.PostView) -> AppBskyFeedDefs.PostView {
    guard let merged = mergedPosts[uri], merged.cid == fallback.cid else { return fallback }
    return merged
  }

  /// The models of the post a row shows, created on first use from the feed payload `post` the
  /// row was configured with (never the shadow-merged copy; see `NativeRowPostModels`), and
  /// replaced when the post's record changed (a new CID) while nothing is presented for it.
  func postModels(for post: AppBskyFeedDefs.PostView, postID: String) -> NativeRowPostModels {
    let uri = post.uri.uriString()
    rowPostIDsByURI[uri, default: []].insert(postID)
    if let existing = postModels[uri], existing.cid == post.cid || existing.postState.hasPresentation {
      return existing
    }
    postModels[uri]?.cancel()
    let created = NativeRowPostModels(
      post: post, displayed: displayedPost(uri: uri, fallback: post), appState: appState)
    postModels[uri] = created
    return created
  }

  /// The models created for the post at `uri`, if any.
  func existingPostModels(forURI uri: String) -> NativeRowPostModels? {
    postModels[uri]
  }

  /// The models whose sheets and alerts the presentation host shows: the post whose menu opened last.
  var activeMenuModels: NativeRowPostModels? { presentationModel.active }

  // MARK: - Live Counts

  /// For each shadow change of the post, its shadow-merged copy; finishes when the shadow stream
  /// finishes or the consumer stops listening.
  func shadowUpdates(for row: Row) -> @Sendable (String) async -> AsyncStream<AppBskyFeedDefs.PostView> {
    let manager = appState.postShadowManager
    let post = row.post
    let postID = row.postID
    return { [weak self] uri in
      Self.mergedPosts(
        of: await manager.shadowUpdates(forUri: uri), merge: { await manager.mergeShadow(post: post) },
        onMerged: { [weak self] merged in await self?.record(merged: merged, uri: uri, postID: postID) })
    }
  }

  /// For each element of `source`, the post `merge` returns, after `onMerged` saw it. Finishes when
  /// `source` finishes, and stops listening to `source` when the consumer stops listening.
  nonisolated static func mergedPosts<Element: Sendable>(
    of source: AsyncStream<Element>, merge: @escaping @Sendable () async -> AppBskyFeedDefs.PostView,
    onMerged: @escaping @Sendable (AppBskyFeedDefs.PostView) async -> Void
  ) -> AsyncStream<AppBskyFeedDefs.PostView> {
    AsyncStream { continuation in
      let task = Task {
        for await _ in source {
          guard !Task.isCancelled else { break }
          let merged = await merge()
          guard !Task.isCancelled else { break }
          await onMerged(merged)
          continuation.yield(merged)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// The latest shadow-merged copy a row's live stream delivered for the post at `uri`.
  func mergedPost(forURI uri: String) -> AppBskyFeedDefs.PostView? {
    mergedPosts[uri]
  }

  private func record(merged: AppBskyFeedDefs.PostView, uri: String, postID: String) {
    rowPostIDsByURI[uri, default: []].insert(postID)
    mergedPosts[uri] = merged
  }

  // MARK: - Presentation Host

  /// Adds the invisible view that presents native rows' sheets and alerts to `controller`.
  func installPresentationHost(in controller: UIViewController) {
    guard presentationHost == nil else { return }
    let host = UIHostingController(rootView: presentationRootView())
    host.view.backgroundColor = .clear
    host.view.isUserInteractionEnabled = false
    host.view.accessibilityElementsHidden = true
    host.view.isAccessibilityElement = false
    host.view.frame = .zero
    host.view.autoresizingMask = []
    controller.addChild(host)
    controller.view.insertSubview(host.view, at: 0)
    host.didMove(toParent: controller)
    presentationHost = host
  }

  private func refreshPresentationHost() {
    presentationHost?.rootView = presentationRootView()
  }

  private func presentationRootView() -> AnyView {
    AnyView(
      NativeRowPresentationHost(model: presentationModel)
        .trackingModerationPolicy(of: appState)
        .applyAppStateEnvironment(appState)
        .environment(sceneContext)
        .environment(\.fontManager, appState.fontManager))
  }

  // MARK: - Settings Observation

  /// Reconfigures every row when a setting native rows read changes: the moderation policy, the
  /// badge preference, link style, languages, reading time, motion, contrast, bold text and the font
  /// settings (`FontManager.generation`).
  func startObservingSettings() {
    settingsObserver?.stopObserving()
    observedFingerprint = SettingsFingerprint(appState: appState)
    settingsObserver = UIKitStateObserver(
      observing: appState, tracking: { _ = SettingsFingerprint(appState: $0) }
    ) { [weak self] appState in
      guard let self else { return }
      let fingerprint = SettingsFingerprint(appState: appState)
      guard fingerprint != self.observedFingerprint else { return }
      self.observedFingerprint = fingerprint
      self.settingsDidChange()
    }
    if policyObserver == nil {
      // `FeedModel` only re-filters the posts on a policy change. A post that stays in the feed but
      // gains a label must move from its native cell to the hosted row (and back).
      policyObserver = NotificationCenter.default.addObserver(
        forName: .moderationPolicyDidChange, object: nil, queue: .main
      ) { [weak self] notification in
        let accountDID = notification.userInfo?["accountDID"] as? String
        MainActor.assumeIsolated {
          guard let self, accountDID == nil || accountDID == self.appState.userDID else { return }
          self.settingsDidChange()
        }
      }
    }
  }

  /// Re-resolves the settings now, so cells configured before the next snapshot already use them,
  /// drops every decision, layout and preparation that depended on the old ones, and asks for a
  /// reconfigure.
  private func settingsDidChange() {
    resolveSettingsIfNeeded()
    preparer.discardAll()
    decisions.removeAll(keepingCapacity: true)
    layoutStore.invalidateAll()
    onSettingsChanged?()
  }

  /// Rebuilds the settings when one of their inputs changed since they were last resolved, and
  /// returns whether the settings changed.
  @discardableResult
  private func resolveSettingsIfNeeded() -> Bool {
    guard let traits else { return false }
    let inputs = SettingsInputs(appState: appState, traits: traits)
    guard inputs != settingsInputs || settings == nil else { return false }
    settingsInputs = inputs
    let resolved = Settings.resolve(appState: appState, traits: traits)
    settingsResolutionCount += 1
    guard resolved != settings else { return false }
    settings = resolved
    preparer.discardAll()
    decisions.removeAll(keepingCapacity: true)
    return true
  }

  // MARK: - Deciding

  /// How the post renders under `settings`, with everything its native row draws. A pure function
  /// of its arguments, run on the main actor or by a preparation.
  nonisolated static func decide(
    postID: String, entry: NativeFeedRowSupport.Entry, signature: FeedPostContentSignature, settings: Settings
  ) -> Decision {
    guard let item = entry.item else { return .hosted(.decodeFailed) }
    let moderation = PostModerationPresentation.make(
      post: item.post, policy: settings.policy, surface: .contentList, listFilterExemptDID: nil)
    if case .hosted(let reason) = NativeFeedRowSupport.classify(entry, moderation: moderation, settings: settings.support) {
      return .hosted(reason)
    }
    guard case .knownType(let record) = item.post.record, let feedPost = record as? AppBskyFeedPost else {
      return .hosted(.recordNotPost)
    }
    let author = item.post.author
    let name = author.displayName ?? author.handle.description
    let isBlank = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let link = settings.colors.linkPresentation(for: settings.linkStyle)
    let text = FeedPostTextBuilder.build(
      post: feedPost, typography: settings.typography, linkStyle: link.style,
      textColor: settings.colors.text, linkColor: link.color)
    let post = item.post
    return .native(Row(
      postID: postID, post: post, createdAt: feedPost.createdAt.date, displayName: isBlank ? "" : name,
      handle: "@\(author.handle.description)",
      verification: isBlank
        ? nil : VerificationBadge.kind(for: author.verification, did: author.did, hideBadges: settings.hideBadges),
      text: text, signature: signature,
      counts: FeedActionBarCounts(
        replyCount: post.replyCount ?? 0, repostCount: post.repostCount ?? 0, likeCount: post.likeCount ?? 0,
        fonts: settings.actionBarFonts),
      canCopyLink: ActionButtonViewModel.shareURL(for: post) != nil, avatarURL: author.finalAvatarURL()))
  }
}

// MARK: - Preparation Source

extension NativeFeedRowCoordinator: NativeFeedRowPreparerDelegate {
  var preparationSettings: Settings? { settings }

  func preparationSignature(forPostID postID: String) -> FeedPostContentSignature? {
    posts[postID] == nil ? nil : signatures[postID]
  }

  func preparationIsSettled(postID: String, signature: FeedPostContentSignature) -> Bool {
    guard let entry = decisions[postID], entry.signature == signature, case .hosted = entry.decision else {
      return false
    }
    return true
  }

  func preparationEntry(
    forPostID postID: String, signature: FeedPostContentSignature
  ) -> NativeFeedRowPreparation.Entry? {
    guard let cached = posts[postID] else { return nil }
    if let entry = decisions[postID], entry.signature == signature {
      return .decided(postID: postID, signature: signature, decision: entry.decision)
    }
    return .classify(postID: postID, signature: signature, source: NativeFeedRowSupport.Entry(cached))
  }

  func store(_ prepared: NativeFeedRowPreparation.Prepared) {
    if decisions[prepared.postID]?.signature != prepared.signature {
      record(prepared.decision, forPostID: prepared.postID, signature: prepared.signature)
    }
    if let layout = prepared.layout { layoutStore.insert(layout) }
    if let time = prepared.time { rowTimes[prepared.postID] = time }
  }
}

// MARK: - Width Requests

extension NativeFeedRowCoordinator {
  /// A feed item's report of the width its cell has, under one collection view width.
  fileprivate struct WidthRequest: Hashable {
    let postID: String
    let boundsWidth: CGFloat
  }
}

// MARK: - Link Presentation

extension NativeFeedRowCoordinator {
  /// How `FeedPostTextBuilder` draws links so they look as the hosted row's `Text` draws them for
  /// the user's `style`. `applyingPostBodyLinkAccent` colours links `accent` for the colour styles
  /// and clears their colour otherwise, and SwiftUI draws a link run without a colour of its own in
  /// the tint: with highlighting off the hosted row's links are still tinted, and with the
  /// underline-only style they are tinted and underlined.
  nonisolated static func linkPresentation(
    for style: PostLinkPresentationStyle, accent: UIColor, tint: UIColor
  ) -> (style: PostLinkPresentationStyle, color: UIColor) {
    switch style {
    case .color, .both: (style, accent)
    case .disabled: (.color, tint)
    case .underline: (.both, tint)
    }
  }
}

// MARK: - Settings

extension NativeFeedRowCoordinator {
  /// The app state native rows read, captured once per snapshot.
  /// A new input must be read here, compared in `SettingsInputs`, and observed through
  /// `SettingsFingerprint` (or a controller observer), or rows will not follow it.
  /// `@unchecked Sendable`: an immutable value whose fonts and colours are immutable and
  /// thread-safe, so rows can be prepared with it off the main actor.
  struct Settings: Equatable, @unchecked Sendable {
    let support: NativeFeedRowSupport.Settings
    let policy: ModerationPolicy
    let typography: FeedRowTypography
    let linkStyle: PostLinkPresentationStyle
    let hideBadges: Bool
    /// `FeedRowMetrics.maxRegularWidthContent` unless the horizontal size class is compact.
    let maxContentWidth: CGFloat?
    let displayScale: CGFloat
    let colors: RowColors
    let actionBarFonts: FeedActionBarFonts
    let reduceMotion: Bool

    @MainActor
    static func resolve(appState: AppState, traits: UITraitCollection) -> Settings {
      let appSettings = appState.appSettings
      let fontManager = appState.fontManager
      let legibilityBold = traits.legibilityWeight == .bold
      return Settings(
        support: NativeFeedRowSupport.Settings(
          isEnabled: NativeFeedRows.isEnabled,
          deviceLanguageCode: Locale.current.language.baseLanguageCode?.lowercased() ?? "en",
          preferredContentLanguages: Set(appSettings.contentLanguages),
          showLanguageIndicators: appSettings.showLanguageIndicators,
          showReadingTimeEstimates: appSettings.showReadingTimeEstimates),
        policy: appState.moderationPolicy,
        // `AppFontModifier` bolds for the app's bold-text setting or the system's legibility weight.
        typography: FeedRowTypography.resolved(
          fontManager: fontManager, boldText: fontManager.effectiveBoldText || legibilityBold,
          contentSize: contentSize(of: traits)),
        linkStyle: PostLinkPresentationStyle.resolve(
          highlightLinks: appSettings.highlightLinks, linkStyle: appSettings.linkStyle),
        hideBadges: appState.preferencesManager.hideVerificationBadges,
        maxContentWidth: traits.horizontalSizeClass == .compact ? nil : FeedRowMetrics.maxRegularWidthContent,
        displayScale: traits.displayScale,
        colors: RowColors(themeManager: appState.themeManager, increaseContrast: appSettings.effectiveIncreaseContrast),
        actionBarFonts: .resolved(fontManager: fontManager, boldText: legibilityBold || appSettings.effectiveBoldText),
        reduceMotion: appSettings.effectiveReduceMotion)
    }

    /// The content size the hosted row's environment has: the trait collection's, which
    /// `FontManager` caps at the app's Dynamic Type limit, or the system's before the collection
    /// view has one.
    @MainActor
    static func contentSize(of traits: UITraitCollection) -> UIContentSizeCategory {
      let category = traits.preferredContentSizeCategory
      return category == .unspecified ? UIApplication.shared.preferredContentSizeCategory : category
    }
  }

  /// The row's text colours, resolved from the theme as the hosted row resolves them: body text in
  /// the theme's primary text colour, metadata in the theme's secondary text colour. Light and dark
  /// variants are captured, and the trait collection picks one.
  /// `@unchecked Sendable`: an immutable value; its `UIColor`s are immutable and thread-safe.
  struct RowColors: Equatable, @unchecked Sendable {
    let key: Key
    let text: UIColor
    let metadata: UIColor
    /// `applyingPostBodyLinkAccent` colours links `AccentTextColor` for the colour styles.
    let accentLink: UIColor
    /// SwiftUI's `Text` draws a link run with no colour of its own in the tint, the app's accent
    /// colour: with highlighting off and with the underline-only style the hosted row's links are
    /// still tinted.
    let tintLink: UIColor

    /// The style and colour that draw links as the hosted row's `Text` does for `style`.
    func linkPresentation(for style: PostLinkPresentationStyle) -> (style: PostLinkPresentationStyle, color: UIColor) {
      NativeFeedRowCoordinator.linkPresentation(for: style, accent: accentLink, tint: tintLink)
    }

    struct Key: Equatable {
      let schemeOverride: ColorScheme?
      let darkThemeMode: ThemeManager.DarkThemeMode
      let increaseContrast: Bool
    }

    @MainActor
    init(themeManager: ThemeManager, increaseContrast: Bool) {
      key = Key(
        schemeOverride: themeManager.colorSchemeOverride, darkThemeMode: themeManager.darkThemeMode,
        increaseContrast: increaseContrast)
      func themed(_ style: TextStyle) -> UIColor {
        let light = UIColor(Color.dynamicText(
          themeManager, style: style, currentScheme: .light, increaseContrast: increaseContrast))
        let dark = UIColor(Color.dynamicText(
          themeManager, style: style, currentScheme: .dark, increaseContrast: increaseContrast))
        return UIColor { $0.userInterfaceStyle == .dark ? dark : light }
      }
      text = themed(.primary)
      metadata = themed(.secondary)
      accentLink = UIColor(named: "AccentTextColor") ?? .link
      tintLink = UIColor(named: "AccentColor") ?? .tintColor
    }

    static func == (lhs: RowColors, rhs: RowColors) -> Bool { lhs.key == rhs.key }
  }

  /// Everything `Settings.resolve` reads, in cheap-to-compare form: the settings are rebuilt (fonts,
  /// colours) only when these change. Checked on every feed update, including skipped ones.
  /// Keep in step with `Settings.resolve` and `SettingsFingerprint`.
  fileprivate struct SettingsInputs: Equatable {
    let fingerprint: SettingsFingerprint
    let isEnabled: Bool
    let deviceLanguageCode: String
    let policyGeneration: UInt64
    let policyAccountDID: String?
    let fontManager: ObjectIdentifier
    let fontBoldText: Bool
    let contentSize: UIContentSizeCategory
    let horizontalSizeClass: UIUserInterfaceSizeClass
    let displayScale: CGFloat
    let legibilityWeight: UILegibilityWeight
    let colorSchemeOverride: ColorScheme?
    let darkThemeMode: ThemeManager.DarkThemeMode

    @MainActor
    init(appState: AppState, traits: UITraitCollection) {
      fingerprint = SettingsFingerprint(appState: appState)
      isEnabled = NativeFeedRows.isEnabled
      deviceLanguageCode = Locale.current.language.baseLanguageCode?.lowercased() ?? "en"
      policyGeneration = appState.moderationPolicy.generation
      policyAccountDID = appState.moderationPolicy.accountDID
      fontManager = ObjectIdentifier(appState.fontManager)
      fontBoldText = appState.fontManager.effectiveBoldText
      contentSize = Settings.contentSize(of: traits)
      horizontalSizeClass = traits.horizontalSizeClass
      displayScale = traits.displayScale
      legibilityWeight = traits.legibilityWeight
      colorSchemeOverride = appState.themeManager.colorSchemeOverride
      darkThemeMode = appState.themeManager.darkThemeMode
    }
  }

  /// The app settings `Settings.resolve` reads that can change while the feed is on screen. Dynamic
  /// Type and the theme reach the controller through its trait and theme observers.
  /// Keep in step with `Settings.resolve` and `SettingsInputs`.
  fileprivate struct SettingsFingerprint: Equatable {
    let hideBadges: Bool
    let highlightLinks: Bool
    let linkStyle: String
    let contentLanguages: [String]
    let showLanguageIndicators: Bool
    let showReadingTimeEstimates: Bool
    let reduceMotion: Bool
    let increaseContrast: Bool
    let boldText: Bool
    let isAuthenticated: Bool
    let fontGeneration: Int

    @MainActor
    init(appState: AppState) {
      let appSettings = appState.appSettings
      hideBadges = appState.preferencesManager.hideVerificationBadges
      highlightLinks = appSettings.highlightLinks
      linkStyle = appSettings.linkStyle
      contentLanguages = appSettings.contentLanguages
      showLanguageIndicators = appSettings.showLanguageIndicators
      showReadingTimeEstimates = appSettings.showReadingTimeEstimates
      reduceMotion = appSettings.effectiveReduceMotion
      increaseContrast = appSettings.effectiveIncreaseContrast
      boldText = appSettings.effectiveBoldText
      isAuthenticated = appState.isAuthenticated
      fontGeneration = appState.fontManager.generation
    }
  }
}
#endif
