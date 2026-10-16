#if os(iOS)
import Foundation
import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird

/// Native rows are prepared off the main actor ahead of the scroll position, and a prepared row is
/// exactly the row the main actor would build.
@MainActor
@Suite("Native feed row preparation", .serialized)
struct NativeFeedRowPreparationTests {
  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal { .none }
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }

  /// Two coordinators for one signed-in account that is not connected to any server: the same
  /// settings and fonts, separate caches.
  @MainActor
  private final class Fixture {
    let appState: AppState
    let sceneContext: SceneNavigationContext
    let coordinator: NativeFeedRowCoordinator
    let reference: NativeFeedRowCoordinator
    let traits = UITraitCollection { traits in
      traits.horizontalSizeClass = .compact
      traits.displayScale = 3
    }

    init(_ name: String) async throws {
      let client = await ATProtoClient(baseURL: try #require(URL(string: "https://\(name).invalid")))
      appState = AppState(userDID: "did:plc:\(name)", client: client, regulatoryChecker: NoAgePrompt())
      sceneContext = SceneNavigationContext(appState: appState, sceneID: UUID())
      coordinator = NativeFeedRowCoordinator(
        navigationPath: .constant(NavigationPath()), appState: appState, sceneContext: sceneContext)
      reference = NativeFeedRowCoordinator(
        navigationPath: .constant(NavigationPath()), appState: appState, sceneContext: sceneContext)
    }

    /// Begins and applies a snapshot of `posts` in `coordinator`, as the controller does.
    func show(_ posts: [CachedFeedViewPost], in coordinator: NativeFeedRowCoordinator? = nil) {
      let byID = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
      let target = coordinator ?? self.coordinator
      target.beginSnapshot(posts: byID, signatures: byID.mapValues(FeedPostContentSignature.init), traits: traits)
      target.didApplySnapshot()
    }

    func tearDown() {
      coordinator.feedDidReset()
      reference.feedDidReset()
      sceneContext.invalidate()
      appState.cleanup()
    }
  }

  // MARK: - Equality With the Main Actor

  private func representativePosts() throws -> [CachedFeedViewPost] {
    let text = "Read https://example.test/a and ask @alice.test about it"
    let link = (text as NSString).range(of: "https://example.test/a")
    let mention = (text as NSString).range(of: "@alice.test")
    let facets = [
      AppBskyRichtextFacet(
        index: AppBskyRichtextFacet.ByteSlice(byteStart: link.location, byteEnd: NSMaxRange(link)),
        features: [.appBskyRichtextFacetLink(AppBskyRichtextFacet.Link(uri: URI(uriString: "https://example.test/a")))]),
      AppBskyRichtextFacet(
        index: AppBskyRichtextFacet.ByteSlice(byteStart: mention.location, byteEnd: NSMaxRange(mention)),
        features: [.appBskyRichtextFacetMention(AppBskyRichtextFacet.Mention(did: try DID(didString: "did:plc:alice")))]),
    ]
    return [
      try FeedRowTestPosts.cachedPost(
        text: "A plain post with a few words.", likeCount: 3, postKey: "plain",
        avatar: "https://cdn.bsky.app/img/avatar/plain/did:plc:fixture/avatar@jpeg"),
      try FeedRowTestPosts.cachedPost(
        text: text, likeCount: 1234, facets: facets, postKey: "links", replyCount: 12, repostCount: 999_950),
      try FeedRowTestPosts.cachedPost(
        text: "Long handle", displayName: "Someone With A Name", postKey: "longhandle",
        handle: "a-very-long-handle-that-keeps-going-and-going.example.com"),
      try FeedRowTestPosts.cachedPost(text: "Blank name", displayName: "   ", postKey: "blankname"),
      try FeedRowTestPosts.cachedPost(
        text: "Verified author", displayName: "Alice Rivera", postKey: "verified",
        authorDID: VerificationBadge.selfVerifiedDID),
      try FeedRowTestPosts.cachedPost(
        text: "مرحبا بالعالم، هذا منشور مكتوب من اليمين إلى اليسار", displayName: "سارة", postKey: "rtl"),
      try FeedRowTestPosts.cachedPost(text: "Hosted, with an image", withImageEmbed: true, postKey: "hosted"),
    ]
  }

  @Test("A prepared row is the row the main actor builds")
  func preparedRowsMatchTheMainActor() async throws {
    let fixture = try await Fixture("nativerowpreparationequal")
    defer { fixture.tearDown() }
    let posts = try representativePosts()
    let width: CGFloat = 402
    fixture.show(posts)
    fixture.coordinator.prepareRows(forPostIDs: posts.map(\.id), boundsWidth: width)
    await fixture.coordinator.waitForPreparation()
    let layoutsBefore = fixture.coordinator.layoutStore.computedOnCallCount

    fixture.show(posts, in: fixture.reference)
    for post in posts {
      let prepared = try #require(fixture.coordinator.decision(forPostID: post.id))
      let built = try #require(fixture.reference.decision(forPostID: post.id))
      switch (prepared, built) {
      case (.hosted(let preparedReason), .hosted(let builtReason)):
        #expect(preparedReason == builtReason)
      case (.native(let preparedRow), .native(let builtRow)):
        try expectSameRow(preparedRow, builtRow)
        let preparedContent = try #require(fixture.coordinator.content(for: preparedRow, width: width))
        let builtContent = try #require(fixture.reference.content(for: builtRow, width: width))
        expectSameContent(preparedContent, builtContent)
        #expect(preparedContent.avatarURL == (try post.feedViewPost).post.author.finalAvatarURL())
      default:
        Issue.record("\(post.id) was decided differently: \(prepared) against \(built)")
      }
    }
    // Every decision and layout came from the preparation, none from the main actor.
    #expect(fixture.coordinator.mainActorDecisionCount == 0)
    #expect(fixture.coordinator.layoutStore.computedOnCallCount == layoutsBefore)
    #expect(fixture.reference.mainActorDecisionCount == posts.count)
  }

  private func expectSameContent(_ prepared: NativeFeedRowContent, _ built: NativeFeedRowContent) {
    #expect(prepared.layout == built.layout)
    #expect(prepared.timeText == built.timeText)
    #expect(prepared.timeAccessibilityLabel == built.timeAccessibilityLabel)
    #expect(prepared.actionBarState == built.actionBarState)
    #expect(prepared.displayName == built.displayName)
    #expect(prepared.handle == built.handle)
    #expect(prepared.verification == built.verification)
    #expect(prepared.avatarURL == built.avatarURL)
  }

  private func expectSameRow(_ prepared: NativeFeedRowCoordinator.Row, _ built: NativeFeedRowCoordinator.Row) throws {
    #expect(prepared.postID == built.postID)
    #expect(prepared.post == built.post)
    #expect(prepared.createdAt == built.createdAt)
    #expect(prepared.displayName == built.displayName)
    #expect(prepared.handle == built.handle)
    #expect(prepared.verification == built.verification)
    #expect(prepared.signature == built.signature)
    #expect(prepared.canCopyLink == built.canCopyLink)
    #expect(prepared.avatarURL == built.avatarURL)
    expectSameText(prepared.text, built.text)
    for (preparedCount, builtCount) in [
      (prepared.counts.reply, built.counts.reply), (prepared.counts.repost, built.counts.repost),
      (prepared.counts.like, built.counts.like),
    ] {
      #expect(preparedCount?.text.string == builtCount?.text.string)
      #expect(preparedCount?.measuredSize == builtCount?.measuredSize)
    }
  }

  /// The same characters with the same attributes in the same runs. Colours are compared resolved
  /// in light and dark, since each coordinator builds its own dynamic theme colours.
  private func expectSameText(_ prepared: NSAttributedString, _ built: NSAttributedString) {
    #expect(prepared.string == built.string)
    #expect(prepared.length == built.length)
    var location = 0
    while location < prepared.length {
      var preparedRun = NSRange()
      var builtRun = NSRange()
      let preparedAttributes = prepared.attributes(at: location, effectiveRange: &preparedRun)
      let builtAttributes = built.attributes(at: location, effectiveRange: &builtRun)
      #expect(preparedRun == builtRun)
      #expect(Set(preparedAttributes.keys) == Set(builtAttributes.keys))
      for (key, value) in preparedAttributes {
        let other = builtAttributes[key]
        if let color = value as? UIColor, let otherColor = other as? UIColor {
          for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            #expect(color.resolvedColor(with: traits) == otherColor.resolvedColor(with: traits))
          }
        } else {
          #expect((value as? NSObject)?.isEqual(other) == true, "\(key.rawValue) differs at \(location)")
        }
      }
      location = NSMaxRange(preparedRun)
    }
  }

  // MARK: - Stale Preparations

  private func manyPosts(_ count: Int, key: String) throws -> [CachedFeedViewPost] {
    try (0..<count).map { index in
      try FeedRowTestPosts.cachedPost(
        text: "Post \(index): " + String(repeating: "several words of text ", count: 1 + index % 5),
        postKey: "\(key)\(index)")
    }
  }

  /// Waits until the coordinator has taken a batch and is preparing it off the main actor.
  private func waitUntilPreparing(_ coordinator: NativeFeedRowCoordinator) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !coordinator.hasPreparationInFlight, ContinuousClock.now < deadline {
      await Task.yield()
    }
    try #require(coordinator.hasPreparationInFlight)
  }

  @Test("A width change cancels the preparation in flight, and only layouts for the new width are kept")
  func widthChangeDiscardsStalePreparation() async throws {
    let fixture = try await Fixture("nativerowpreparationwidth")
    defer { fixture.tearDown() }
    let posts = try manyPosts(40, key: "width")
    fixture.show(posts)
    let generation = fixture.coordinator.preparationGeneration
    fixture.coordinator.prepareRows(forPostIDs: posts.map(\.id), boundsWidth: 402)
    try await waitUntilPreparing(fixture.coordinator)

    fixture.coordinator.prepareRows(forPostIDs: posts.map(\.id), boundsWidth: 320)
    #expect(fixture.coordinator.preparationGeneration != generation)
    await fixture.coordinator.waitForPreparation()

    // Every post was prepared once, for the new width; nothing from the cancelled batch was kept.
    #expect(fixture.coordinator.layoutStore.cachedCount == posts.count)
    let computed = fixture.coordinator.layoutStore.computedOnCallCount
    for post in posts {
      let row = try #require(fixture.coordinator.nativeRow(forPostID: post.id))
      #expect(try #require(fixture.coordinator.content(for: row, width: 320)).layout.width == 320)
    }
    #expect(fixture.coordinator.layoutStore.computedOnCallCount == computed)
    #expect(fixture.coordinator.mainActorDecisionCount == 0)
  }

  @Test("A typography change cancels the preparation in flight, and none of its layouts is kept")
  func typographyChangeDiscardsStalePreparation() async throws {
    let fixture = try await Fixture("nativerowpreparationtypography")
    defer { fixture.tearDown() }
    let posts = try manyPosts(40, key: "typography")
    fixture.show(posts)
    fixture.coordinator.prepareRows(forPostIDs: posts.map(\.id), boundsWidth: 402)
    try await waitUntilPreparing(fixture.coordinator)

    // The controller does this when the font settings or the content size category change.
    fixture.coordinator.invalidateLayouts()
    await fixture.coordinator.waitForPreparation()
    #expect(fixture.coordinator.layoutStore.cachedCount == 0)

    // The rows are prepared again when asked for, for the current typography.
    fixture.coordinator.prepareRows(forPostIDs: posts.map(\.id), boundsWidth: 402)
    await fixture.coordinator.waitForPreparation()
    #expect(fixture.coordinator.layoutStore.cachedCount == posts.count)
    let typography = try #require(fixture.coordinator.typography)
    let row = try #require(fixture.coordinator.nativeRow(forPostID: posts[0].id))
    let content = try #require(fixture.coordinator.content(for: row, width: 402))
    let expected = FeedRowLayoutEngine.layout(FeedRowLayoutInput(
      postID: row.postID, width: 402, typography: typography, displayName: row.displayName, handle: row.handle,
      timeText: content.timeText, verificationSymbol: row.verification?.symbolName, text: row.text,
      contentSignature: row.signature, displayScale: 3))
    #expect(content.layout == expected)
  }

  @Test("A snapshot without a post cancels its preparation and keeps nothing for it")
  func removedPostIsNotPrepared() async throws {
    let fixture = try await Fixture("nativerowpreparationremoved")
    defer { fixture.tearDown() }
    let posts = try manyPosts(40, key: "removed")
    fixture.show(posts)
    fixture.coordinator.prepareRows(forPostIDs: posts.map(\.id), boundsWidth: 402)
    try await waitUntilPreparing(fixture.coordinator)

    // The batch in flight holds the first posts; the snapshot keeps the last of them and the rest.
    let kept = Array(posts.suffix(20))
    fixture.show(kept)
    await fixture.coordinator.waitForPreparation()
    // The kept posts the cancelled batch held are prepared once they are asked for again.
    fixture.coordinator.prepareRows(forPostIDs: kept.map(\.id), boundsWidth: 402)
    await fixture.coordinator.waitForPreparation()
    // Nothing was kept for the posts that left.
    #expect(fixture.coordinator.layoutStore.cachedCount == kept.count)
    for post in kept {
      #expect(fixture.coordinator.nativeRow(forPostID: post.id) != nil)
    }
    #expect(fixture.coordinator.mainActorDecisionCount == 0)
  }

  // MARK: - Time

  @Test("A prepared row whose time ticks over shows the new time with a layout for it")
  func tickedTimeRefreshes() async throws {
    let fixture = try await Fixture("nativerowpreparationtime")
    defer { fixture.tearDown() }
    // One minute and 58.5 seconds old: "1m" now, "2m" in a second and a half.
    let createdAt = Date().addingTimeInterval(-118.5)
    let post = try FeedRowTestPosts.cachedPost(text: "Ticking", postKey: "ticking", createdAt: createdAt)
    fixture.show([post])
    fixture.coordinator.prepareRows(forPostIDs: [post.id], boundsWidth: 402)
    await fixture.coordinator.waitForPreparation()
    let row = try #require(fixture.coordinator.nativeRow(forPostID: post.id))

    while Date() < createdAt.addingTimeInterval(120.2) {
      try await Task.sleep(for: .milliseconds(50))
    }
    let content = try #require(fixture.coordinator.content(for: row, width: 402))
    #expect(content.timeText == "2m")
    #expect(content.timeAccessibilityLabel == formatTimeAgo(from: createdAt, forAccessibility: true))
    let typography = try #require(fixture.coordinator.typography)
    #expect(content.layout == FeedRowLayoutEngine.layout(FeedRowLayoutInput(
      postID: row.postID, width: 402, typography: typography, displayName: row.displayName, handle: row.handle,
      timeText: "2m", verificationSymbol: row.verification?.symbolName, text: row.text,
      contentSignature: row.signature, displayScale: 3)))
  }

  @Test("The spoken time changes with the shown time from a minute up, so it can be prepared with it")
  func timeStringsChangeTogether() {
    let minute: TimeInterval = 60
    let hour = 60 * minute
    let day = 24 * hour
    let ages: [TimeInterval] = [
      minute, minute + 30, 2 * minute - 1, 2 * minute, hour - 1, hour, hour + 1, 2 * hour - 1, day - 1, day,
      day + 1, 2 * day - 1, 2 * day, 6 * day, 7 * day - 1, 7 * day, 8 * day, 13 * day, 14 * day, 27 * day,
      31 * day, 40 * day, 364 * day, 366 * day, 800 * day,
    ]
    let now = Date()
    for age in ages {
      for delta: TimeInterval in [0.5, 1, 20, 59] {
        let newer = now.addingTimeInterval(-age)
        let older = newer.addingTimeInterval(-delta)
        guard shortTimeAgoString(from: newer) == shortTimeAgoString(from: older) else { continue }
        #expect(
          formatTimeAgo(from: newer, forAccessibility: true) == formatTimeAgo(from: older, forAccessibility: true),
          "\(age) s and \(age + delta) s show the same time but read differently")
      }
    }
    // Below a minute the shown time stays "now" while the spoken one counts seconds; it is never reused.
    let recent = now.addingTimeInterval(-5)
    let time = NativeFeedRowPreparation.RowTime(createdAt: recent)
    #expect(time.text == "now")
    #expect(!time.isCurrent(createdAt: recent, timeText: "now"))
  }

  // MARK: - Decision Counts

  @Test("Decisions are counted per outcome for the current feed, from both paths, without content")
  func decisionsAreCountedPerReason() async throws {
    let fixture = try await Fixture("nativerowdecisioncounts")
    defer { fixture.tearDown() }
    let decidedHere = [
      try FeedRowTestPosts.cachedPost(text: "native one", postKey: "countnative1"),
      try FeedRowTestPosts.cachedPost(text: "embed", withImageEmbed: true, postKey: "countembed"),
      try FeedRowTestPosts.cachedPost(text: "reply", asReply: true, postKey: "countreply"),
    ]
    let prepared = [
      try FeedRowTestPosts.cachedPost(text: "native two", postKey: "countnative2"),
      try FeedRowTestPosts.cachedPost(text: "repost", asRepost: true, postKey: "countrepost"),
    ]
    fixture.show(decidedHere + prepared)
    for post in decidedHere { _ = fixture.coordinator.decision(forPostID: post.id) }
    fixture.coordinator.prepareRows(forPostIDs: prepared.map(\.id), boundsWidth: 402)
    await fixture.coordinator.waitForPreparation()
    for post in decidedHere + prepared { _ = fixture.coordinator.decision(forPostID: post.id) }

    let counter = fixture.coordinator.decisionCounter
    #expect(counter.total == 5)
    #expect(counter.counts == [.native: 2, .hosted(.embed): 1, .hosted(.replyContext): 1, .hosted(.reason): 1])
    #expect(counter.summary == "native=2 embed=1 replyContext=1 reason=1")

    fixture.coordinator.feedDidReset()
    #expect(counter.total == 0)
    #expect(counter.counts.isEmpty)
    #expect(counter.summary.isEmpty)
  }

  @Test("The counter keeps counting past each summary")
  func counterCountsPastSummaries() {
    let counter = NativeFeedRowDecisionCounter()
    for index in 0..<(NativeFeedRowDecisionCounter.summaryInterval * 2 + 3) {
      counter.record(index.isMultiple(of: 3) ? .hosted(.translationOffered) : .native)
    }
    #expect(counter.total == 203)
    #expect(counter.counts[.hosted(.translationOffered)] == 68)
    #expect(counter.counts[.native] == 135)
    #expect(counter.summary == "native=135 translationOffered=68")
  }

  // MARK: - Window

  @Test("The window moves ahead in the direction of travel and asks again only when it runs low")
  func windowFollowsTravel() {
    var window = NativeFeedRowPreparationWindow()
    #expect(window.reset(at: 0, count: 200) == 0..<25)
    // Plenty prepared ahead: nothing to ask for.
    for index in 0...12 { #expect(window.advance(to: index, count: 200) == nil) }
    #expect(window.advance(to: 13, count: 200) == 25..<38)
    #expect(window.advance(to: 14, count: 200) == nil)
    #expect(window.advance(to: 26, count: 200) == 38..<51)
    // The end of the feed bounds the window.
    #expect(window.reset(at: 190, count: 200) == 182..<200)
    #expect(window.advance(to: 199, count: 200) == nil)
  }

  @Test("A reversal prepares the window behind")
  func windowReversal() {
    var window = NativeFeedRowPreparationWindow()
    // A jump far down the feed, then back up.
    _ = window.reset(at: 0, count: 300)
    #expect(window.advance(to: 1, count: 300) == nil)
    #expect(window.advance(to: 150, count: 300) == 142..<175)
    #expect(window.direction == .forward)
    // The posts just above the jump were prepared with it; the reversal asks for the next ones.
    #expect(window.advance(to: 149, count: 300) == 125..<142)
    #expect(window.direction == .backward)
    for index in stride(from: 148, through: 137, by: -1) {
      #expect(window.advance(to: index, count: 300) == nil)
    }
    #expect(window.advance(to: 136, count: 300) == 112..<125)
  }

  // MARK: - Scrolling the Feed

  /// The production controller with text posts in a window, prefetching off: only the visible
  /// range moving prepares rows.
  private func scrollingHost(_ name: String, count: Int) async throws -> (NativeFeedRowControllerHost, AppState) {
    let client = await ATProtoClient(baseURL: try #require(URL(string: "https://\(name).invalid")))
    let appState = AppState(userDID: "did:plc:\(name)", client: client, regulatoryChecker: NoAgePrompt())
    let posts = try manyPosts(count, key: name)
    let host = try NativeFeedRowControllerHost(appState: appState, posts: posts)
    host.controller.enableUpdateDiagnostics()
    await host.controller.performUpdate()
    _ = try #require(try await host.waitForPostCell(NativeFeedPostCell.self))
    await settle(host)
    return (host, appState)
  }

  /// Lays the feed out and waits for the preparations that asked for.
  private func settle(_ host: NativeFeedRowControllerHost) async {
    host.window.layoutIfNeeded()
    host.controller.collectionView.layoutIfNeeded()
    await host.controller.nativeRowsForTesting.waitForPreparation()
    host.controller.collectionView.layoutIfNeeded()
  }

  private func visiblePostItems(_ host: NativeFeedRowControllerHost) -> [Int] {
    host.controller.collectionView.indexPathsForVisibleItems.map(\.item).sorted()
  }

  @Test("Scrolling prepares the rows ahead without a snapshot, so they are configured from the preparation")
  func scrollingPreparesAhead() async throws {
    let (host, appState) = try await scrollingHost("nativerowscrollahead", count: 120)
    defer {
      host.tearDown()
      appState.cleanup()
    }
    let coordinator = host.controller.nativeRowsForTesting
    let collectionView = host.controller.collectionView!
    let snapshots = host.controller.updateDiagnostics?.snapshotApplications
    let decisions = coordinator.mainActorDecisionCount
    let layouts = coordinator.layoutStore.computedOnCallCount
    let firstScreen = visiblePostItems(host)

    for _ in 0..<16 {
      collectionView.contentOffset.y += 300
      await settle(host)
    }
    let lastVisible = try #require(visiblePostItems(host).last)
    // Past the rows the first snapshot prepared.
    #expect(lastVisible > (firstScreen.last ?? 0) + NativeFeedRowPreparationWindow.ahead)
    #expect(host.controller.updateDiagnostics?.snapshotApplications == snapshots)
    #expect(coordinator.mainActorDecisionCount == decisions)
    #expect(coordinator.layoutStore.computedOnCallCount == layouts)
  }

  @Test("Scrolling back up after a jump configures the rows above from a preparation")
  func reversalPreparesBehind() async throws {
    let (host, appState) = try await scrollingHost("nativerowscrollreversal", count: 160)
    defer {
      host.tearDown()
      appState.cleanup()
    }
    let coordinator = host.controller.nativeRowsForTesting
    let collectionView = host.controller.collectionView!
    // A jump far down, past every prepared row: the rows it lands on are built on the main actor.
    collectionView.scrollToItem(at: IndexPath(item: 120, section: 0), at: .top, animated: false)
    await settle(host)
    let landing = try #require(visiblePostItems(host).first)
    #expect(landing > 100)
    let decisions = coordinator.mainActorDecisionCount
    let layouts = coordinator.layoutStore.computedOnCallCount

    for _ in 0..<14 {
      collectionView.contentOffset.y -= 250
      await settle(host)
    }
    let firstVisible = try #require(visiblePostItems(host).first)
    #expect(firstVisible < landing - NativeFeedRowPreparationWindow.behind)
    #expect(coordinator.mainActorDecisionCount == decisions)
    #expect(coordinator.layoutStore.computedOnCallCount == layouts)
  }
}

#endif
