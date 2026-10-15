#if os(iOS)
import Foundation
import Petrel
import Synchronization
import Testing
import UIKit
@testable import Catbird

@MainActor
@Suite("Native feed post cell")
struct NativeFeedPostCellTests {
  @Test("Preferred height is the layout height, without measuring subviews")
  func preferredHeightFromLayout() throws {
    let (cell, content) = try NativeFeedRowTestFactory.configuredCell(text: "hello world")
    let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
    attributes.frame = CGRect(x: 0, y: 0, width: content.layout.width, height: 44)
    #expect(cell.preferredLayoutAttributesFitting(attributes).size.height == content.layout.height)
  }

  @Test("Subviews sit at the layout's frames")
  func framesApplied() throws {
    let (cell, content) = try NativeFeedRowTestFactory.configuredCell(text: "hello world")
    cell.frame = CGRect(x: 0, y: 0, width: content.layout.width, height: content.layout.height)
    cell.layoutIfNeeded()
    #expect(cell.textViewForTesting.frame == content.layout.textFrame)
    #expect(cell.avatarViewForTesting.frame == content.layout.avatarFrame)
    #expect(cell.actionBarForTesting.frame == content.layout.actionBarFrame)
    #expect(cell.optionsButtonForTesting.frame == content.layout.optionsButtonFrame)
    #expect(cell.dividerForTesting.frame == content.layout.dividerFrame)
  }

  @Test("The header spans the content view, so its labels sit at the layout's own frames")
  func headerSpansContentView() throws {
    let (cell, content) = try NativeFeedRowTestFactory.configuredCell(text: "hello world")
    layOut(cell, content)
    let header = cell.headerViewForTesting
    #expect(header.frame == cell.contentView.bounds)
    #expect(header.nameLabelForTesting.frame == content.layout.nameFrame)
    #expect(header.timeLabelForTesting.frame == content.layout.timeFrame)
    #expect(header.isUserInteractionEnabled == false)
  }

  @Test("Reuse clears the previous post")
  func reuseClears() throws {
    let (cell, _) = try NativeFeedRowTestFactory.configuredCell(text: "first")
    cell.prepareForReuse()
    #expect(cell.postURI == nil)
    #expect(cell.textViewForTesting.attributedText == nil)
    #expect(cell.hasOptionsMenuForTesting == false)
  }

  @Test("Accessibility matches the hosted row")
  func accessibility() throws {
    let (cell, content) = try NativeFeedRowTestFactory.configuredCell(text: "hello")
    #expect(cell.contentView.accessibilityIdentifier == "post.\(content.post.uri.uriString())")
    #expect(cell.avatarViewForTesting.accessibilityLabel?.hasSuffix(", view profile") == true)
    #expect(cell.avatarViewForTesting.accessibilityLabel == "\(NativeFeedRowTestFactory.displayName), view profile")
  }

  @Test("Height follows the content size category", arguments: [
    UIContentSizeCategory.small, .large, .accessibilityExtraExtraExtraLarge,
  ])
  func heightTracksDynamicType(category: UIContentSizeCategory) throws {
    let (_, content) = try NativeFeedRowTestFactory.configuredCell(
      text: String(repeating: "dynamic type ", count: 20), contentSize: category)
    let label = UILabel()
    label.numberOfLines = 0
    label.attributedText = content.text
    let fitted = label.sizeThatFits(CGSize(width: content.layout.textFrame.width, height: .greatestFiniteMagnitude))
    #expect(abs(ceil(fitted.height) - content.layout.textFrame.height) <= 0.5)
  }

  // MARK: - Accessibility

  @Test("VoiceOver can open the post from the row")
  func openPostAccessibilityAction() throws {
    let recorder = ActionRecorder()
    let (cell, content) = try NativeFeedRowTestFactory.configuredCell(text: "hello", actions: recorder.actions)
    let action = try #require(cell.contentView.accessibilityCustomActions?.first { $0.name == "Open post" })
    let handler = try #require(action.actionHandler)
    #expect(handler(action))
    #expect(recorder.openedPosts == [content.post.uri.uriString()])

    cell.prepareForReuse()
    #expect(handler(action) == false)
    #expect(recorder.openedPosts.count == 1)
  }

  @Test("Action bar buttons keep the identifiers UI tests use")
  func actionBarIdentifiers() throws {
    let (cell, _) = try NativeFeedRowTestFactory.configuredCell(text: "hello")
    let identifiers = Set(cell.actionBarForTesting.subviews.compactMap(\.accessibilityIdentifier))
    #expect(identifiers.isSuperset(of: ["replyButton", "repostButton", "likeButton", "shareButton"]))
    #expect(cell.optionsButtonForTesting.accessibilityLabel == "Post Options")
  }

  // MARK: - Taps

  @Test("Taps on text and header open the post; controls, the avatar and links keep theirs")
  func tapRouting() throws {
    let (cell, content) = try NativeFeedRowTestFactory.configuredCell(text: "plain words with no links at all")
    layOut(cell, content)
    let layout = content.layout
    #expect(cell.tapOpensPost(at: center(of: layout.textFrame)))
    #expect(cell.tapOpensPost(at: center(of: layout.nameFrame)))
    #expect(cell.tapOpensPost(at: center(of: layout.timeFrame)))
    #expect(cell.tapOpensPost(at: center(of: layout.avatarFrame)) == false)
    #expect(cell.tapOpensPost(at: center(of: layout.optionsButtonFrame)) == false)
    let like = try #require(cell.actionBarForTesting.subviews.first { $0.accessibilityIdentifier == "likeButton" })
    let likeCenter = cell.contentView.convert(CGPoint(x: like.bounds.midX, y: like.bounds.midY), from: like)
    #expect(cell.tapOpensPost(at: likeCenter) == false)
  }

  @Test("A tap on a link does not open the post")
  func linkTapIsTheLinks() throws {
    let base = try NativeFeedRowTestFactory.content(text: "every word here is one link")
    let linked = NSMutableAttributedString(attributedString: base.text)
    linked.addAttribute(
      .feedLink, value: try #require(URL(string: "https://example.test")), range: NSRange(location: 0, length: linked.length))
    let content = NativeFeedRowContent(
      post: base.post, layout: base.layout, text: linked, displayName: base.displayName, handle: base.handle,
      timeText: base.timeText, timeAccessibilityLabel: base.timeAccessibilityLabel, verification: nil,
      actionBarState: base.actionBarState)
    let cell = NativeFeedPostCell(frame: .zero)
    cell.configure(
      content, typography: NativeFeedRowTestFactory.typography(contentSize: .large),
      actions: NativeFeedRowTestFactory.noOpActions, shadowUpdates: NativeFeedRowTestFactory.finishedShadowUpdates)
    layOut(cell, content)
    #expect(cell.tapOpensPost(at: center(of: content.layout.textFrame)) == false)
  }

  @Test("The avatar opens the author's profile")
  func avatarOpensProfile() throws {
    let recorder = ActionRecorder()
    let (cell, content) = try NativeFeedRowTestFactory.configuredCell(text: "hello", actions: recorder.actions)
    #expect(cell.avatarViewForTesting.accessibilityActivate())
    #expect(recorder.openedProfiles == [content.post.author.did.didString()])
  }

  // MARK: - Reuse

  @Test("A reused cell's menu and actions belong to the new post")
  func reuseRebindsActions() throws {
    let recorder = ActionRecorder()
    let (cell, _) = try NativeFeedRowTestFactory.configuredCell(text: "first", postKey: "a", actions: recorder.actions)
    cell.prepareForReuse()
    let second = try NativeFeedRowTestFactory.content(text: "second", postKey: "b")
    cell.configure(
      second, typography: NativeFeedRowTestFactory.typography(contentSize: .large), actions: recorder.actions,
      shadowUpdates: NativeFeedRowTestFactory.finishedShadowUpdates)
    _ = cell.optionsButtonForTesting.makeItems?()
    let openPost = try #require(cell.contentView.accessibilityCustomActions?.first { $0.name == "Open post" })
    _ = openPost.actionHandler?(openPost)
    #expect(recorder.menuPosts == [second.post.uri.uriString()])
    #expect(recorder.openedPosts == [second.post.uri.uriString()])
    #expect(cell.postURI == second.post.uri.uriString())
  }

  @Test("The verification badge resolved for the row is drawn")
  func verificationBadge() throws {
    let (verified, _) = try NativeFeedRowTestFactory.configuredCell(text: "hello", verification: .regular)
    #expect(verified.headerViewForTesting.badgeViewForTesting.isHidden == false)
    let (plain, _) = try NativeFeedRowTestFactory.configuredCell(text: "hello")
    #expect(plain.headerViewForTesting.badgeViewForTesting.isHidden)
  }

  // MARK: - Live Counts

  @Test("Shadow updates refresh the action bar")
  func shadowUpdatesApply() async throws {
    let (stream, continuation) = AsyncStream<AppBskyFeedDefs.PostView>.makeStream()
    let (cell, content) = try NativeFeedRowTestFactory.configuredCell(text: "hello", shadowUpdates: { _ in stream })
    let like = try #require(cell.actionBarForTesting.subviews.first { $0.accessibilityIdentifier == "likeButton" })
    #expect(like.accessibilityLabel == "Like, 0 likes")
    continuation.yield(try liked(content.post, likeCount: 5))
    try await waitUntil { like.accessibilityLabel == "Unlike, 5 likes" }
    #expect(like.accessibilityLabel == "Unlike, 5 likes")
    continuation.finish()
  }

  @Test("Reuse stops observing the previous post's shadow")
  func reuseEndsShadowObservation() async throws {
    let probe = ShadowStreamProbe()
    let (stream, continuation) = AsyncStream<AppBskyFeedDefs.PostView>.makeStream()
    continuation.onTermination = { _ in probe.markTerminated() }
    let (cell, _) = try NativeFeedRowTestFactory.configuredCell(text: "hello", shadowUpdates: { _ in
      probe.markRequested()
      return stream
    })
    try await waitUntil { probe.isRequested }
    #expect(probe.isRequested)
    #expect(probe.isTerminated == false)
    cell.prepareForReuse()
    try await waitUntil { probe.isTerminated }
    #expect(probe.isTerminated)
  }

  @Test("A deallocated cell stops observing its post's shadow")
  func deallocationEndsShadowObservation() async throws {
    let probe = ShadowStreamProbe()
    let (stream, continuation) = AsyncStream<AppBskyFeedDefs.PostView>.makeStream()
    continuation.onTermination = { _ in probe.markTerminated() }
    weak var released: NativeFeedPostCell?
    try autoreleasepool {
      let (cell, _) = try NativeFeedRowTestFactory.configuredCell(text: "hello", shadowUpdates: { _ in
        probe.markRequested()
        return stream
      })
      released = cell
    }
    try await waitUntil { released == nil && probe.isRequested && probe.isTerminated }
    #expect(released == nil)
    #expect(probe.isTerminated)
  }

  // MARK: - Helpers

  private func layOut(_ cell: NativeFeedPostCell, _ content: NativeFeedRowContent) {
    cell.frame = CGRect(x: 0, y: 0, width: content.layout.width, height: content.layout.height)
    cell.layoutIfNeeded()
  }

  private func center(of rect: CGRect) -> CGPoint {
    CGPoint(x: rect.midX, y: rect.midY)
  }

  private func liked(_ post: AppBskyFeedDefs.PostView, likeCount: Int) throws -> AppBskyFeedDefs.PostView {
    let like = try ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.feed.like/one")
    return AppBskyFeedDefs.PostView(
      uri: post.uri, cid: post.cid, author: post.author, record: post.record, embed: post.embed,
      bookmarkCount: post.bookmarkCount, replyCount: post.replyCount, repostCount: post.repostCount,
      likeCount: likeCount, quoteCount: post.quoteCount, indexedAt: post.indexedAt,
      viewer: AppBskyFeedDefs.ViewerState(like: like), labels: post.labels, threadgate: post.threadgate,
      debug: post.debug)
  }

  private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}

// MARK: - Test Doubles

/// Records what a native row asked its actions to do.
@MainActor
private final class ActionRecorder {
  var openedPosts: [String] = []
  var openedProfiles: [String] = []
  var menuPosts: [String] = []

  var actions: NativeFeedRowActions {
    NativeFeedRowActions(
      openPost: { [weak self] post in self?.openedPosts.append(post.uri.uriString()) },
      openProfile: { [weak self] did in self?.openedProfiles.append(did) },
      openLink: { _ in },
      actionBar: { _ in NativeFeedRowTestFactory.noOpActionBarActions },
      optionsMenu: { [weak self] post in
        self?.menuPosts.append(post.uri.uriString())
        return []
      })
  }
}

/// Records when a cell asks for a shadow stream and when that stream terminates. The
/// termination handler may run on any thread.
private final class ShadowStreamProbe: Sendable {
  private let requested = Mutex(false)
  private let terminated = Mutex(false)

  var isRequested: Bool { requested.withLock { $0 } }
  var isTerminated: Bool { terminated.withLock { $0 } }

  func markRequested() {
    requested.withLock { $0 = true }
  }

  func markTerminated() {
    terminated.withLock { $0 = true }
  }
}
#endif
