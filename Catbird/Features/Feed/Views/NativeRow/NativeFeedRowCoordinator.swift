#if os(iOS)
import OSLog
import Petrel
import SwiftUI
import UIKit

private let coordinatorLogger = Logger(subsystem: "blue.catbird", category: "NativeFeedRow")

// MARK: - Native Feed Row Coordinator

/// The feed controller's half of native rows: decides which posts render natively, builds what a
/// `NativeFeedPostCell` draws and does, prepares layouts ahead of display, and hosts the sheets and
/// alerts the rows' menus present. One per feed controller.
///
/// Decisions and prepared rows are computed once per post and kept while the post's content
/// signature and the row settings (moderation policy, fonts, link style, badge preference, theme
/// colours, size class) stay the same. The controller calls `beginSnapshot` before every snapshot it
/// applies, so cells configured between snapshots read the settings that snapshot captured.
@MainActor
final class NativeFeedRowCoordinator {
  /// How one post renders.
  enum Decision {
    case native(Row)
    case hosted(NativeFeedRowSupport.Reason)
  }

  /// A post the native cell supports, with everything that does not change with the clock or the
  /// width already resolved.
  struct Row {
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
  /// Created the first time a row's menu or action bar needs them, per post URI.
  private var postModels: [String: NativeRowPostModels] = [:]
  /// The width cells actually have when it differs from the collection view's width, keyed by the
  /// collection view's width (reported through `NativeFeedRowActions.layoutWidthChanged`).
  private var cellWidths: [CGFloat: CGFloat] = [:]
  private var pendingReconfigure: Set<String> = []
  private var preparations: [UUID: Task<Void, Never>] = [:]
  private var settingsObserver: UIKitStateObserver<AppState>?
  private var policyObserver: NSObjectProtocol?
  private var observedFingerprint: SettingsFingerprint?

  /// The collection view native rows are laid out in.
  weak var collectionView: UICollectionView?
  /// Asks the controller for a snapshot that reconfigures the posts `takeReconfigureRequest` reports.
  var onNeedsReconfigure: (() -> Void)?
  /// Asks the controller to reconfigure every row because a setting rows read changed.
  var onSettingsChanged: (() -> Void)?

  init(navigationPath: Binding<NavigationPath>, appState: AppState, sceneContext: SceneNavigationContext) {
    self.navigationPath = navigationPath
    self.appState = appState
    self.sceneContext = sceneContext
    layoutStore = FeedRowLayoutStore()
  }

  isolated deinit {
    preparations.values.forEach { $0.cancel() }
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
      resolveSettings()
      decisions.removeAll()
      mergedPosts.removeAll()
      postModels.values.forEach { $0.cancel() }
      postModels.removeAll()
      startObservingSettings()
    }
    if accountChanged || sceneChanged { refreshPresentationHost() }
  }

  // MARK: - Snapshots

  /// Captures the posts and row settings of the snapshot about to be applied. Decisions for posts
  /// whose content or settings changed are recomputed on next use.
  func beginSnapshot(
    posts: [String: CachedFeedViewPost], signatures: [String: FeedPostContentSignature], traits: UITraitCollection
  ) {
    self.traits = traits
    resolveSettings()
    self.posts = posts
    self.signatures = signatures
    decisions = decisions.filter { posts[$0.key] != nil }
    dequeuedAsNative = dequeuedAsNative.filter { posts[$0.key] != nil }
    pendingReconfigure = pendingReconfigure.filter { posts[$0] != nil }

    let uris = Set(posts.values.compactMap { try? $0.feedViewPost.post.uri.uriString() })
    mergedPosts = mergedPosts.filter { uris.contains($0.key) }
    for (uri, models) in postModels where !uris.contains(uri) {
      models.cancel()
      postModels[uri] = nil
    }
    presentationModel.deactivate { uris.contains($0.uri) }
  }

  /// How the post with `postID` renders in the current snapshot.
  func decision(forPostID postID: String) -> Decision? {
    guard let cached = posts[postID], let signature = signatures[postID], let settings else { return nil }
    if let entry = decisions[postID], entry.signature == signature { return entry.decision }
    let decision = Self.decide(postID: postID, cached: cached, signature: signature, settings: settings)
    decisions[postID] = (signature, decision)
    return decision
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

  func content(for row: Row, width: CGFloat) -> NativeFeedRowContent? {
    guard let settings else { return nil }
    let timeText = shortTimeAgoString(from: row.createdAt)
    let layout = layoutStore.layout(for: layoutInput(for: row, width: width, timeText: timeText, settings: settings))
    let displayed = mergedPosts[row.post.uri.uriString()] ?? row.post
    return NativeFeedRowContent(
      post: row.post, layout: layout, text: row.text, displayName: row.displayName, handle: row.handle,
      timeText: timeText, timeAccessibilityLabel: formatTimeAgo(from: row.createdAt, forAccessibility: true),
      verification: row.verification, actionBarState: actionBarState(for: displayed, settings: settings),
      metadataColor: settings.colors.metadata)
  }

  private func layoutInput(
    for row: Row, width: CGFloat, timeText: String, settings: Settings
  ) -> FeedRowLayoutInput {
    FeedRowLayoutInput(
      postID: row.postID, width: width, typography: settings.typography, displayName: row.displayName,
      handle: row.handle, timeText: timeText, verificationSymbol: row.verification?.symbolName, text: row.text,
      contentSignature: row.signature, maxContentWidth: settings.maxContentWidth,
      displayScale: settings.displayScale)
  }

  private func actionBarState(for post: AppBskyFeedDefs.PostView, settings: Settings) -> FeedActionBarState {
    FeedActionBarState(
      postURI: post.uri.uriString(), replyCount: post.replyCount ?? 0,
      isReplyDisabled: post.viewer?.replyDisabled ?? false, repostCount: post.repostCount ?? 0,
      isReposted: post.viewer?.repost != nil, isQuoteDisabled: post.viewer?.embeddingDisabled ?? false,
      likeCount: post.likeCount ?? 0, isLiked: post.viewer?.like != nil, isShareEnabled: isValidShareOrigin,
      canSendViaChat: appState.isAuthenticated, canCopyLink: ActionButtonViewModel.shareURL(for: post) != nil,
      reduceMotion: settings.reduceMotion, fonts: settings.actionBarFonts)
  }

  // MARK: - Layout Preparation

  /// Computes layouts for the native rows among `postIDs` off the main actor, so their cells find
  /// them cached when they are configured.
  func prepareLayouts(forPostIDs postIDs: [String], boundsWidth: CGFloat) {
    guard let settings, boundsWidth > 0 else { return }
    let width = layoutWidth(forBoundsWidth: boundsWidth)
    let inputs = postIDs.compactMap { nativeRow(forPostID: $0) }.map { row in
      layoutInput(for: row, width: width, timeText: shortTimeAgoString(from: row.createdAt), settings: settings)
    }
    guard !inputs.isEmpty else { return }
    let id = UUID()
    preparations[id] = Task { [weak self, layoutStore] in
      await layoutStore.prepare(inputs)
      self?.preparations[id] = nil
    }
  }

  /// Cancels layout preparation, for example when the feed is replaced.
  func cancelPreparation() {
    preparations.values.forEach { $0.cancel() }
    preparations.removeAll()
  }

  /// Drops every cached layout; fonts, text size or the width changed.
  func invalidateLayouts(includingCellWidths: Bool = false) {
    layoutStore.invalidateAll()
    if includingCellWidths { cellWidths.removeAll() }
  }

  /// A native cell is sized to a width its layout was not computed for. Records the width cells
  /// have, so every later layout (prepared or configured) uses it, and schedules a reconfigure of
  /// the item. The cell reports a width at most once per configuration and only when its layout
  /// differs from it, so a reconfigure that applies a layout for the reported width ends the
  /// exchange: insets that keep cells narrower than the collection view cannot cause a loop.
  private func cellWidthChanged(postID: String, to width: CGFloat) {
    guard let boundsWidth = collectionView?.bounds.width, boundsWidth > 0, width > 0 else { return }
    cellWidths[boundsWidth] = abs(width - boundsWidth) < 0.01 ? nil : width
    if pendingReconfigure.insert(postID).inserted { onNeedsReconfigure?() }
  }

  // MARK: - Actions

  func actions(for row: Row) -> NativeFeedRowActions {
    let postID = row.postID
    return NativeFeedRowActions(
      openPost: { [weak self] post in self?.openPost(post) },
      openProfile: { [weak self] did in self?.navigationPath.wrappedValue.append(NavigationDestination.profile(did)) },
      openLink: { [weak self] url in self?.openLink(url) },
      actionBar: { [weak self] post in self?.actionBarActions(for: post) ?? Self.inertActionBarActions },
      optionsMenu: { [weak self] post in self?.optionsMenu(for: post) ?? [] },
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
  private func actionBarActions(for post: AppBskyFeedDefs.PostView) -> FeedActionBarActions {
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
        let models = self.models(for: self.displayedPost(uri: uri, fallback: post))
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
        let models = self.models(for: self.displayedPost(uri: uri, fallback: post))
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
  private func optionsMenu(for post: AppBskyFeedDefs.PostView) -> [UIMenuElement] {
    let models = models(for: displayedPost(uri: post.uri.uriString(), fallback: post))
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

  /// The post's models, created on first use and replaced when the post's record changed (a new
  /// CID) while nothing is presented for it.
  private func models(for post: AppBskyFeedDefs.PostView) -> NativeRowPostModels {
    let uri = post.uri.uriString()
    if let existing = postModels[uri], existing.cid == post.cid || existing.postState.hasPresentation {
      return existing
    }
    postModels[uri]?.cancel()
    let created = NativeRowPostModels(post: post, appState: appState)
    postModels[uri] = created
    return created
  }

  // MARK: - Live Counts

  /// For each shadow change of the post, its shadow-merged copy; finishes when the shadow stream
  /// finishes or the consumer stops listening.
  func shadowUpdates(for row: Row) -> @Sendable (String) async -> AsyncStream<AppBskyFeedDefs.PostView> {
    let manager = appState.postShadowManager
    let post = row.post
    return { [weak self] uri in
      AsyncStream { continuation in
        let task = Task {
          for await _ in await manager.shadowUpdates(forUri: uri) {
            guard !Task.isCancelled else { break }
            let merged = await manager.mergeShadow(post: post)
            guard !Task.isCancelled else { break }
            await self?.record(merged: merged, uri: uri)
            continuation.yield(merged)
          }
          continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }
  }

  private func record(merged: AppBskyFeedDefs.PostView, uri: String) {
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
  /// drops every decision and layout that depended on the old ones, and asks for a reconfigure.
  private func settingsDidChange() {
    resolveSettings()
    decisions.removeAll(keepingCapacity: true)
    layoutStore.invalidateAll()
    onSettingsChanged?()
  }

  private func resolveSettings() {
    guard let traits else { return }
    let resolved = Settings.resolve(appState: appState, traits: traits)
    guard resolved != settings else { return }
    settings = resolved
    decisions.removeAll(keepingCapacity: true)
  }

  // MARK: - Deciding

  private static func decide(
    postID: String, cached: CachedFeedViewPost, signature: FeedPostContentSignature, settings: Settings
  ) -> Decision {
    guard let item = try? cached.feedViewPost else { return .hosted(.decodeFailed) }
    let moderation = PostModerationPresentation.make(
      post: item.post, policy: settings.policy, surface: .contentList, listFilterExemptDID: nil)
    if case .hosted(let reason) = NativeFeedRowSupport.classify(cached, moderation: moderation, settings: settings.support) {
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
    return .native(Row(
      postID: postID, post: item.post, createdAt: feedPost.createdAt.date, displayName: isBlank ? "" : name,
      handle: "@\(author.handle.description)",
      verification: isBlank
        ? nil : VerificationBadge.kind(for: author.verification, did: author.did, hideBadges: settings.hideBadges),
      text: text, signature: signature))
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
  fileprivate struct Settings: Equatable {
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
          fontManager: fontManager, boldText: fontManager.effectiveBoldText || legibilityBold),
        linkStyle: PostLinkPresentationStyle.resolve(
          highlightLinks: appSettings.highlightLinks, linkStyle: appSettings.linkStyle),
        hideBadges: appState.preferencesManager.hideVerificationBadges,
        maxContentWidth: traits.horizontalSizeClass == .compact ? nil : FeedRowMetrics.maxRegularWidthContent,
        displayScale: traits.displayScale,
        colors: RowColors(themeManager: appState.themeManager, increaseContrast: appSettings.effectiveIncreaseContrast),
        actionBarFonts: .resolved(fontManager: fontManager, boldText: legibilityBold || appSettings.effectiveBoldText),
        reduceMotion: appSettings.effectiveReduceMotion)
    }
  }

  /// The row's text colours, resolved from the theme as the hosted row resolves them: body text in
  /// the theme's primary text colour, metadata in the theme's secondary text colour. Light and dark
  /// variants are captured, and the trait collection picks one.
  fileprivate struct RowColors: Equatable {
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

  /// The app settings `Settings.resolve` reads that can change while the feed is on screen. Dynamic
  /// Type and the theme reach the controller through its trait and theme observers.
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
