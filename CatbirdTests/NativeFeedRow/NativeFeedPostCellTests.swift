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
    #expect(cell.dividerForTesting.frame == content.layout.dividerFrame)
  }

  @Test("The options button covers its glyph's frame and is at least a button's height, centered on it")
  func optionsButtonTouchArea() throws {
    let (cell, content) = try NativeFeedRowTestFactory.configuredCell(text: "hello world")
    cell.frame = CGRect(x: 0, y: 0, width: content.layout.width, height: content.layout.height)
    cell.layoutIfNeeded()
    let glyph = content.layout.optionsButtonFrame
    let button = cell.optionsButtonForTesting.frame
    // The hosted row's button is the size the overlay gives it: the padded glyph's width and the
    // button's own intrinsic height.
    #expect(button.width == glyph.width)
    #expect(button.height == max(glyph.height, PostOptionsMenuButtonView().intrinsicContentSize.height))
    #expect(abs(button.midY - glyph.midY) < 0.001)
    #expect(button.minX == glyph.minX)
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

  @Test("Reuse clears the previous post, and leaves the text for the next configuration to replace")
  func reuseClears() throws {
    let (cell, first) = try NativeFeedRowTestFactory.configuredCell(text: "first")
    cell.prepareForReuse()
    #expect(cell.postURI == nil)
    #expect(cell.hasOptionsMenuForTesting == false)
    // `configure` always sets the text, so reuse does not pay for clearing it.
    #expect(cell.textViewForTesting.attributedText === first.text)

    let second = try NativeFeedRowTestFactory.content(text: "second", postKey: "b")
    cell.configure(
      second, typography: NativeFeedRowTestFactory.typography(contentSize: .large),
      actions: NativeFeedRowTestFactory.noOpActions, shadowUpdates: NativeFeedRowTestFactory.finishedShadowUpdates)
    #expect(cell.textViewForTesting.attributedText === second.text)
    #expect(cell.textViewForTesting.accessibilityLabel == "second")
  }

  @Test("A reused cell that is not configured shows none of the previous post's text")
  func unconfiguredReuseShowsNoText() throws {
    let (cell, _) = try NativeFeedRowTestFactory.configuredCell(text: "first")
    cell.prepareForReuse()
    cell.clearContent()
    #expect(cell.textViewForTesting.attributedText == nil)
    #expect(cell.textViewForTesting.accessibilityLabel == nil)
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
    // Never shorter than the label needs, and less than a point taller (the text is rounded up
    // to a whole pixel of the input's display scale).
    #expect(content.layout.textFrame.height >= fitted.height - 0.001)
    #expect(content.layout.textFrame.height - fitted.height < 1)
  }

  // MARK: - Accessibility

  @Test("VoiceOver reads the row in the hosted row's order")
  func accessibilityReadingOrder() throws {
    let (cell, _) = try NativeFeedRowTestFactory.configuredCell(text: "hello", verification: .regular)
    let elements = try #require(cell.contentView.accessibilityElements as? [UIView])
    #expect(elements == [
      cell.avatarViewForTesting, cell.headerViewForTesting, cell.optionsButtonForTesting,
      cell.textViewForTesting, cell.actionBarForTesting,
    ])
    let header = cell.headerViewForTesting
    let headerElements = try #require(header.accessibilityElements as? [UIView])
    #expect(headerElements == [
      header.nameLabelForTesting, header.badgeViewForTesting, header.handleLabelForTesting,
      header.timeLabelForTesting,
    ])
  }

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

  @Test("VoiceOver offers Open post on the text and the author's name")
  func openPostOnFocusableElements() throws {
    let recorder = ActionRecorder()
    let (cell, content) = try NativeFeedRowTestFactory.configuredCell(text: "hello", actions: recorder.actions)
    let textAction = try #require(cell.textViewForTesting.accessibilityCustomActions?.first { $0.name == "Open post" })
    let nameLabel = cell.headerViewForTesting.nameLabelForTesting
    let nameAction = try #require(nameLabel.accessibilityCustomActions?.first { $0.name == "Open post" })
    #expect(textAction.actionHandler?(textAction) == true)
    #expect(nameAction.actionHandler?(nameAction) == true)
    #expect(recorder.openedPosts == [content.post.uri.uriString(), content.post.uri.uriString()])
  }

  @Test("Open post comes before the text's link actions")
  func openPostBeforeLinkActions() throws {
    let base = try NativeFeedRowTestFactory.content(text: "read this")
    let linked = NSMutableAttributedString(attributedString: base.text)
    linked.addAttribute(.feedLink, value: try #require(URL(string: "https://example.test")), range: NSRange(location: 5, length: 4))
    let content = NativeFeedRowContent(
      post: base.post, layout: base.layout, text: linked, displayName: base.displayName, handle: base.handle,
      timeText: base.timeText, timeAccessibilityLabel: base.timeAccessibilityLabel, verification: nil,
      actionBarState: base.actionBarState, metadataColor: base.metadataColor, actionBarCounts: base.actionBarCounts,
      avatarURL: base.avatarURL)
    let cell = NativeFeedPostCell(frame: .zero)
    cell.configure(
      content, typography: NativeFeedRowTestFactory.typography(contentSize: .large),
      actions: NativeFeedRowTestFactory.noOpActions, shadowUpdates: NativeFeedRowTestFactory.finishedShadowUpdates)
    #expect(cell.textViewForTesting.accessibilityCustomActions?.map(\.name) == ["Open post", "this"])
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
      actionBarState: base.actionBarState, metadataColor: base.metadataColor, actionBarCounts: base.actionBarCounts,
      avatarURL: base.avatarURL)
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

  // MARK: - Width

  @Test("Laying out at the layout's width reports nothing")
  func matchingWidthIsQuiet() throws {
    let recorder = ActionRecorder()
    let (cell, content) = try NativeFeedRowTestFactory.configuredCell(text: "hello", actions: recorder.actions)
    layOut(cell, content)
    #expect(content.layout.width == 390)
    #expect(recorder.widthChanges.isEmpty)
  }

  @Test("Laying out at another width reports it once, and again after reconfiguration")
  func widthMismatchIsReported() throws {
    let recorder = ActionRecorder()
    let (cell, content) = try NativeFeedRowTestFactory.configuredCell(text: "hello", actions: recorder.actions)
    let uri = content.post.uri.uriString()
    cell.frame = CGRect(x: 0, y: 0, width: 320, height: content.layout.height)
    cell.layoutIfNeeded()
    #expect(recorder.widthChanges == [ActionRecorder.WidthChange(postURI: uri, width: 320)])
    cell.setNeedsLayout()
    cell.layoutIfNeeded()
    #expect(recorder.widthChanges.count == 1)

    cell.configure(
      content, typography: NativeFeedRowTestFactory.typography(contentSize: .large), actions: recorder.actions,
      shadowUpdates: NativeFeedRowTestFactory.finishedShadowUpdates)
    cell.layoutIfNeeded()
    #expect(recorder.widthChanges.count == 2)
  }

  @Test("Self-sizing at another width reports it")
  func selfSizingWidthMismatchIsReported() throws {
    let recorder = ActionRecorder()
    let (cell, content) = try NativeFeedRowTestFactory.configuredCell(text: "hello", actions: recorder.actions)
    let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
    attributes.frame = CGRect(x: 0, y: 0, width: 600, height: 44)
    _ = cell.preferredLayoutAttributesFitting(attributes)
    #expect(recorder.widthChanges == [ActionRecorder.WidthChange(postURI: content.post.uri.uriString(), width: 600)])
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
  var widthChanges: [WidthChange] = []

  struct WidthChange: Equatable {
    let postURI: String
    let width: CGFloat
  }

  var actions: NativeFeedRowActions {
    NativeFeedRowActions(
      openPost: { [weak self] post in self?.openedPosts.append(post.uri.uriString()) },
      openProfile: { [weak self] did in self?.openedProfiles.append(did) },
      openLink: { _ in },
      actionBar: { _ in NativeFeedRowTestFactory.noOpActionBarActions },
      optionsMenu: { [weak self] post in
        self?.menuPosts.append(post.uri.uriString())
        return []
      },
      layoutWidthChanged: { [weak self] post, width in
        self?.widthChanges.append(WidthChange(postURI: post.uri.uriString(), width: width))
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
