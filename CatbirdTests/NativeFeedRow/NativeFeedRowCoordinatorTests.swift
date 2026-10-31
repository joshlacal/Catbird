#if os(iOS)
import Foundation
import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird

@MainActor
@Suite("Native feed row coordinator", .serialized)
struct NativeFeedRowCoordinatorTests {
  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal { .none }
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }

  /// A coordinator for a signed-in account that is not connected to any server.
  @MainActor
  private final class Fixture {
    let appState: AppState
    let sceneContext: SceneNavigationContext
    let coordinator: NativeFeedRowCoordinator
    let traits = UITraitCollection { traits in
      traits.horizontalSizeClass = .compact
      traits.displayScale = 3
    }

    init() async throws {
      let client = await ATProtoClient(baseURL: try #require(URL(string: "https://native-row-coordinator.invalid")))
      appState = AppState(userDID: "did:plc:nativerowcoordinator", client: client, regulatoryChecker: NoAgePrompt())
      sceneContext = SceneNavigationContext(appState: appState, sceneID: UUID())
      coordinator = NativeFeedRowCoordinator(
        navigationPath: .constant(NavigationPath()), appState: appState, sceneContext: sceneContext)
    }

    /// Begins and applies a snapshot of `posts`, as the controller does for an update it applies.
    func show(_ posts: [CachedFeedViewPost]) {
      let byID = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
      coordinator.beginSnapshot(posts: byID, signatures: byID.mapValues(FeedPostContentSignature.init), traits: traits)
      coordinator.didApplySnapshot()
    }

    func tearDown() {
      sceneContext.invalidate()
      appState.cleanup()
    }
  }

  @Test("A blank display name shows the handle alone and no badge, as the hosted header does")
  func blankDisplayNameHidesBadge() async throws {
    let fixture = try await Fixture()
    defer { fixture.tearDown() }
    let named = try FeedRowTestPosts.cachedPost(
      displayName: "Alice Rivera", postKey: "named", authorDID: VerificationBadge.selfVerifiedDID)
    let blank = try FeedRowTestPosts.cachedPost(
      displayName: "   ", postKey: "blank", authorDID: VerificationBadge.selfVerifiedDID)
    fixture.show([named, blank])

    let namedRow = try #require(fixture.coordinator.nativeRow(forPostID: named.id))
    #expect(namedRow.displayName == "Alice Rivera")
    #expect(namedRow.verification == .regular)
    #expect(namedRow.handle == "@author.test")

    let blankRow = try #require(fixture.coordinator.nativeRow(forPostID: blank.id))
    #expect(blankRow.displayName.isEmpty)
    #expect(blankRow.verification == nil)
    let content = try #require(fixture.coordinator.content(for: blankRow, width: 402))
    #expect(content.layout.badgeFrame == nil)
    #expect(content.layout.handleFrame?.minX == content.layout.nameFrame.minX)
  }

  @Test("Hiding verification badges removes the badge and the space reserved for it")
  func hiddenBadges() async throws {
    let fixture = try await Fixture()
    defer { fixture.tearDown() }
    let post = try FeedRowTestPosts.cachedPost(displayName: "Alice Rivera", authorDID: VerificationBadge.selfVerifiedDID)
    fixture.show([post])
    let shown = try #require(fixture.coordinator.nativeRow(forPostID: post.id))
    #expect(try #require(fixture.coordinator.content(for: shown, width: 402)).layout.badgeFrame != nil)

    fixture.appState.preferencesManager.hideVerificationBadges = true
    fixture.show([post])
    let hidden = try #require(fixture.coordinator.nativeRow(forPostID: post.id))
    #expect(hidden.verification == nil)
    let content = try #require(fixture.coordinator.content(for: hidden, width: 402))
    #expect(content.verification == nil)
    #expect(content.layout.badgeFrame == nil)
  }

  @Test("A post whose row kind changes needs a reload, not a reconfigure")
  func kindChangeNeedsReload() async throws {
    let fixture = try await Fixture()
    defer {
      UserDefaults.standard.removeObject(forKey: "nativeFeedRowsDisabled")
      fixture.tearDown()
    }
    let post = try FeedRowTestPosts.cachedPost()
    fixture.show([post])
    #expect(fixture.coordinator.nativeRow(forPostID: post.id) != nil)
    fixture.coordinator.recordDequeue(postID: post.id, native: true)
    #expect(!fixture.coordinator.cellKindChanges(postID: post.id))

    UserDefaults.standard.set(true, forKey: "nativeFeedRowsDisabled")
    fixture.show([post])
    guard case .hosted(.disabled)? = fixture.coordinator.decision(forPostID: post.id) else {
      Issue.record("The switch must send the post to the hosted row")
      return
    }
    #expect(fixture.coordinator.cellKindChanges(postID: post.id))
    fixture.coordinator.recordDequeue(postID: post.id, native: false)
    #expect(!fixture.coordinator.cellKindChanges(postID: post.id))
  }

  @Test("Links are drawn as the hosted row's Text draws them for each link style", arguments: [
    (PostLinkPresentationStyle.color, PostLinkPresentationStyle.color, true),
    (.both, .both, true),
    (.disabled, .color, false),
    (.underline, .both, false),
  ])
  func linkPresentationMatchesHostedText(
    style: PostLinkPresentationStyle, drawnStyle: PostLinkPresentationStyle, usesAccent: Bool
  ) {
    let accent = UIColor.systemBlue
    let tint = UIColor.systemOrange
    let presentation = NativeFeedRowCoordinator.linkPresentation(for: style, accent: accent, tint: tint)
    #expect(presentation.style == drawnStyle)
    #expect(presentation.color == (usesAccent ? accent : tint))
  }

  @Test("Rows are laid out for the regular size class's centered content width")
  func regularWidthCentersContent() async throws {
    let fixture = try await Fixture()
    defer { fixture.tearDown() }
    let post = try FeedRowTestPosts.cachedPost()
    let regular = UITraitCollection { traits in
      traits.horizontalSizeClass = .regular
      traits.displayScale = 2
    }
    let byID = [post.id: post]
    fixture.coordinator.beginSnapshot(posts: byID, signatures: byID.mapValues(FeedPostContentSignature.init), traits: regular)
    let row = try #require(fixture.coordinator.nativeRow(forPostID: post.id))
    let layout = try #require(fixture.coordinator.content(for: row, width: 1000)).layout
    #expect(layout.width == 1000)
    #expect(layout.avatarFrame.minX == 200 + FeedRowMetrics.rowHorizontal + FeedRowMetrics.avatarColumnInset + 3)
    #expect(layout.dividerFrame.width == 1000)
  }

  /// The hosted row's environment font follows the trait collection, which `FontManager` caps at
  /// the app's Dynamic Type limit; the system's own setting can be larger.
  @Test("Row typography follows the collection view's content size, not the system's")
  func typographyFollowsTraitContentSize() async throws {
    let fixture = try await Fixture()
    defer { fixture.tearDown() }
    let post = try FeedRowTestPosts.cachedPost()
    let capped = fixture.traits.modifyingTraits { $0.preferredContentSizeCategory = .accessibilityMedium }
    let byID = [post.id: post]
    fixture.coordinator.beginSnapshot(posts: byID, signatures: byID.mapValues(FeedPostContentSignature.init), traits: capped)
    let typography = try #require(fixture.coordinator.typography)
    #expect(typography.separatorLineHeight == FeedRowTypography.separatorLineHeight(contentSize: .accessibilityMedium))
    #expect(typography.optionsGlyphSize == FeedRowTypography.optionsGlyphSize(contentSize: .accessibilityMedium))

    let larger = capped.modifyingTraits { $0.preferredContentSizeCategory = .accessibilityExtraLarge }
    #expect(fixture.coordinator.updateTraits(larger))
    let updated = try #require(fixture.coordinator.typography)
    #expect(updated.separatorLineHeight == FeedRowTypography.separatorLineHeight(contentSize: .accessibilityExtraLarge))
    #expect(updated.optionsGlyphSize == FeedRowTypography.optionsGlyphSize(contentSize: .accessibilityExtraLarge))
  }

  // MARK: - Post Models

  /// The options menu creates the models through its real call site.
  @Test("Menu models reconcile against the feed payload, so a decision made elsewhere stays", arguments: [true, false])
  func modelsKeepDecisionsMadeElsewhere(like: Bool) async throws {
    let fixture = try await Fixture()
    defer { fixture.tearDown() }
    let post = try FeedRowTestPosts.cachedPost(
      postKey: like ? "decidedunlike" : "decidedunrepost", liked: like, reposted: !like)
    fixture.show([post])
    let row = try #require(fixture.coordinator.nativeRow(forPostID: post.id))
    let uri = row.post.uri.uriString()
    let manager = fixture.appState.postShadowManager
    // Unliked (or un-reposted) elsewhere; the feed still holds the old payload.
    if like {
      await manager.setLiked(postUri: uri, isLiked: false)
    } else {
      await manager.setReposted(postUri: uri, isReposted: false)
    }
    // The row's live stream delivers the shadow-merged post, as it does for a row on screen.
    for await merged in await fixture.coordinator.shadowUpdates(for: row)(uri) {
      #expect(like ? merged.viewer?.like == nil : merged.viewer?.repost == nil)
      break
    }

    _ = fixture.coordinator.actions(for: row).optionsMenu(row.post)
    let models = try #require(fixture.coordinator.activeMenuModels)
    await models.reconciled()
    let merged = await manager.mergeShadow(post: row.post)
    if like {
      #expect(merged.viewer?.like == nil)
      #expect(!models.postViewModel.isLiked)
    } else {
      #expect(merged.viewer?.repost == nil)
      #expect(!models.postViewModel.isReposted)
    }
  }

  @Test("The action bar's like reconciles against the feed payload, so an unlike made elsewhere stays")
  func likeKeepsUnlikeMadeElsewhere() async throws {
    let fixture = try await Fixture()
    defer { fixture.tearDown() }
    let post = try FeedRowTestPosts.cachedPost(postKey: "actionbarunlike", liked: true)
    fixture.show([post])
    let row = try #require(fixture.coordinator.nativeRow(forPostID: post.id))
    let uri = row.post.uri.uriString()
    let manager = fixture.appState.postShadowManager
    await manager.setLiked(postUri: uri, isLiked: false)
    for await _ in await fixture.coordinator.shadowUpdates(for: row)(uri) { break }

    // The tap likes the post again from the unliked state the viewer sees. This account cannot
    // write, so the like is refused; the unlike made elsewhere must survive either way.
    fixture.coordinator.actions(for: row).actionBar(row.post).toggleLike()
    let models = try #require(fixture.coordinator.existingPostModels(forURI: uri))
    // The tap's own write and its revert re-decide the shadow, so the outcome alone cannot tell
    // which post the models started from: the feed payload (still liked), not the merged copy.
    #expect(models.contextMenuViewModel.post.viewer?.like != nil)
    await models.reconciled()
    try await Task.sleep(for: .milliseconds(500))
    let merged = await manager.mergeShadow(post: row.post)
    #expect(merged.viewer?.like == nil)
    #expect(!models.postViewModel.isLiked)
  }

  // MARK: - Pruning

  @Test("Live counts, models and the menu target are kept while the post is in the snapshot")
  func pruningFollowsSnapshotPosts() async throws {
    let fixture = try await Fixture()
    defer { fixture.tearDown() }
    let post = try FeedRowTestPosts.cachedPost(postKey: "pruning")
    fixture.show([post])
    let row = try #require(fixture.coordinator.nativeRow(forPostID: post.id))
    let uri = row.post.uri.uriString()
    for await _ in await fixture.coordinator.shadowUpdates(for: row)(uri) { break }
    _ = fixture.coordinator.actions(for: row).optionsMenu(row.post)
    let models = try #require(fixture.coordinator.existingPostModels(forURI: uri))
    #expect(fixture.coordinator.activeMenuModels === models)
    #expect(fixture.coordinator.mergedPost(forURI: uri) != nil)

    // A settings change empties the decision cache; the next applied snapshot still holds the post.
    fixture.appState.preferencesManager.hideVerificationBadges = true
    fixture.show([post])
    #expect(fixture.coordinator.mergedPost(forURI: uri) != nil)
    #expect(fixture.coordinator.existingPostModels(forURI: uri) === models)
    #expect(fixture.coordinator.activeMenuModels === models)

    // Once the post leaves the snapshot, all three go.
    fixture.show([])
    #expect(fixture.coordinator.mergedPost(forURI: uri) == nil)
    #expect(fixture.coordinator.existingPostModels(forURI: uri) == nil)
    #expect(fixture.coordinator.activeMenuModels == nil)
  }

  // MARK: - Settings

  @Test("A snapshot whose settings inputs did not change does not rebuild the settings")
  func unchangedSettingsAreNotRebuilt() async throws {
    let fixture = try await Fixture()
    defer { fixture.tearDown() }
    let post = try FeedRowTestPosts.cachedPost()
    fixture.show([post])
    let resolved = fixture.coordinator.settingsResolutionCount
    fixture.show([post])
    fixture.show([post])
    #expect(fixture.coordinator.settingsResolutionCount == resolved)
    #expect(fixture.coordinator.nativeRow(forPostID: post.id) != nil)

    fixture.appState.preferencesManager.hideVerificationBadges = true
    fixture.show([post])
    #expect(fixture.coordinator.settingsResolutionCount == resolved + 1)
  }

  // MARK: - Width

  @Test("A reported cell width is used for later layouts and requests one reconfigure")
  func reportedWidthRequestsOneReconfigure() async throws {
    let fixture = try await Fixture()
    defer { fixture.tearDown() }
    let post = try FeedRowTestPosts.cachedPost()
    fixture.show([post])
    let collectionView = UICollectionView(
      frame: CGRect(x: 0, y: 0, width: 402, height: 800), collectionViewLayout: UICollectionViewFlowLayout())
    fixture.coordinator.collectionView = collectionView
    var requests = 0
    fixture.coordinator.onNeedsReconfigure = { requests += 1 }
    let row = try #require(fixture.coordinator.nativeRow(forPostID: post.id))
    let actions = fixture.coordinator.actions(for: row)

    actions.layoutWidthChanged(row.post, 390)
    #expect(requests == 1)
    #expect(fixture.coordinator.layoutWidth(forBoundsWidth: 402) == 390)
    #expect(fixture.coordinator.takeReconfigureRequest(postID: post.id))

    // The same report again (its reconfigure already asked for) is not a new request.
    actions.layoutWidthChanged(row.post, 390)
    #expect(requests == 1)
    #expect(!fixture.coordinator.takeReconfigureRequest(postID: post.id))
    #expect(fixture.coordinator.layoutWidth(forBoundsWidth: 402) == 390)

    // Under new bounds the same width is a new report, and is asked for again.
    collectionView.frame.size.width = 500
    actions.layoutWidthChanged(row.post, 390)
    #expect(requests == 2)
    #expect(fixture.coordinator.takeReconfigureRequest(postID: post.id))
    #expect(fixture.coordinator.layoutWidth(forBoundsWidth: 500) == 390)
  }

  // MARK: - Presentation Host

  @Test("The presentation host sits in the window at zero size, hidden from VoiceOver and touches")
  func presentationHostIsInvisible() async throws {
    let fixture = try await Fixture()
    defer { fixture.tearDown() }
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
    let controller = UIViewController()
    window.rootViewController = controller
    window.isHidden = false
    defer {
      window.isHidden = true
      window.rootViewController = nil
    }
    fixture.coordinator.installPresentationHost(in: controller)
    window.layoutIfNeeded()

    let host = try #require(controller.children.compactMap { $0 as? UIHostingController<AnyView> }.first)
    #expect(host.view.window === window)
    #expect(host.view.superview === controller.view)
    #expect(host.view.frame.size == .zero)
    #expect(host.view.accessibilityElementsHidden)
    #expect(!host.view.isAccessibilityElement)
    #expect(!host.view.isUserInteractionEnabled)
  }

  // MARK: - Live Counts

  @Test("The merged post stream finishes when its source finishes")
  func mergedStreamFinishesWithSource() async throws {
    let post = try FeedRowTestPosts.cachedPost().feedViewPost.post
    let (source, continuation) = AsyncStream<Int>.makeStream()
    let merged = NativeFeedRowCoordinator.mergedPosts(of: source, merge: { post }, onMerged: { _ in })
    continuation.yield(1)
    continuation.yield(2)
    continuation.finish()
    let received = await Self.withTimeout {
      var count = 0
      for await element in merged where element.uri == post.uri { count += 1 }
      return count
    }
    #expect(received == 2)
  }

  @Test("The merged post stream stops listening to its source when the consumer stops")
  func mergedStreamCancelsSource() async throws {
    let post = try FeedRowTestPosts.cachedPost().feedViewPost.post
    let (source, continuation) = AsyncStream<Int>.makeStream()
    let (terminations, terminated) = AsyncStream<Void>.makeStream()
    continuation.onTermination = { _ in
      terminated.yield()
      terminated.finish()
    }
    let merged = NativeFeedRowCoordinator.mergedPosts(of: source, merge: { post }, onMerged: { _ in })
    let consumer = Task {
      for await _ in merged {}
    }
    continuation.yield(1)
    consumer.cancel()
    let sourceTerminated = await Self.withTimeout {
      for await _ in terminations { return true }
      return false
    }
    #expect(sourceTerminated == true)
  }

  /// `operation`'s result, or `nil` if it has not finished within two seconds, so a stream that
  /// never ends fails the test instead of hanging it.
  private static func withTimeout<Result: Sendable>(
    _ operation: @escaping @Sendable () async -> Result
  ) async -> Result? {
    await withTaskGroup(of: Result?.self) { group in
      group.addTask { await operation() }
      group.addTask {
        try? await Task.sleep(for: .seconds(2))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }
}
#endif
