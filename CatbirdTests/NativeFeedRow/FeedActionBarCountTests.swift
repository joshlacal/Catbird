#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import Catbird

/// The action bar sizes its count labels from counts measured ahead of display, at exactly the
/// size the labels would measure for themselves.
@MainActor
@Suite("Feed action bar counts", .serialized)
struct FeedActionBarCountTests {
  private static let counts = [1, 7, 42, 999, 1000, 1234, 99_950, 123_456, 999_950, 1_234_567]

  /// The row's count fonts for a few font settings.
  private func fontsList() -> [FeedActionBarFonts] {
    let fontManager = FontManager()
    var list = [
      FeedActionBarFonts.resolved(fontManager: fontManager, boldText: false),
      FeedActionBarFonts.resolved(fontManager: fontManager, boldText: true),
    ]
    fontManager.fontSize = "extraLarge"
    fontManager.letterSpacing = "loose"
    list.append(.resolved(fontManager: fontManager, boldText: false))
    return list
  }

  private func windowedHost(scale: CGFloat) throws -> (UIWindow, UIView) {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 402, height: 200)
    let host = UIView(frame: window.bounds)
    host.traitOverrides.displayScale = scale
    window.addSubview(host)
    window.isHidden = false
    return (window, host)
  }

  @Test("A measured count is the size its label measures for itself", arguments: [CGFloat(2), 3])
  func measuredSizeIsTheLabelsSize(scale: CGFloat) throws {
    let (window, host) = try windowedHost(scale: scale)
    defer { window.isHidden = true }
    for fonts in fontsList() {
      for count in Self.counts {
        let text = try #require(FeedActionBarCountText(count: count, fonts: fonts))
        let label = UILabel()
        label.numberOfLines = 1
        host.addSubview(label)
        label.attributedText = text.text
        #expect(text.size(scale: scale) == label.intrinsicContentSize, "\(count) at \(scale)x")
        label.removeFromSuperview()
      }
    }
    #expect(FeedActionBarCountText(count: 0, fonts: fontsList()[0]) == nil)
  }

  private func bar(in host: UIView, state: FeedActionBarState, counts: FeedActionBarCounts?) -> FeedActionBarView {
    let bar = FeedActionBarView(frame: CGRect(x: 0, y: 0, width: 390, height: FeedActionBar.height))
    host.addSubview(bar)
    bar.apply(state, counts: counts)
    bar.layoutIfNeeded()
    return bar
  }

  private func buttons(of bar: FeedActionBarView) throws -> [FeedActionBarButton] {
    try ["replyButton", "repostButton", "likeButton"].map { identifier in
      try #require(bar.subviews.first { $0.accessibilityIdentifier == identifier } as? FeedActionBarButton)
    }
  }

  private func state(reply: Int, repost: Int, like: Int, fonts: FeedActionBarFonts) -> FeedActionBarState {
    FeedActionBarState(
      postURI: "at://did:plc:counts/app.bsky.feed.post/one", replyCount: reply, isReplyDisabled: false,
      repostCount: repost, isReposted: false, isQuoteDisabled: false, likeCount: like, isLiked: false,
      isShareEnabled: true, canSendViaChat: true, canCopyLink: true, reduceMotion: true, fonts: fonts)
  }

  @Test("Count labels sit at the frames the labels' own sizes give, with or without prepared counts")
  func countFramesAreUnchanged() throws {
    let (window, host) = try windowedHost(scale: 3)
    defer { window.isHidden = true }
    for fonts in fontsList() {
      let state = state(reply: 12, repost: 999_950, like: 1234, fonts: fonts)
      let prepared = FeedActionBarCounts(replyCount: 12, repostCount: 999_950, likeCount: 1234, fonts: fonts)
      for counts in [prepared, nil] {
        let bar = bar(in: host, state: state, counts: counts)
        for button in try buttons(of: bar) {
          let label = button.countLabelForTesting
          #expect(label.frame.size == label.intrinsicContentSize)
          #expect(label.frame.midY == button.bounds.midY)
        }
        bar.removeFromSuperview()
      }
    }
  }

  @Test("Layout sizes a count from the count it was given, without measuring the label")
  func layoutDoesNotMeasureTheLabel() throws {
    let (window, host) = try windowedHost(scale: 3)
    defer { window.isHidden = true }
    let fonts = fontsList()[0]
    let bar = bar(in: host, state: state(reply: 0, repost: 0, like: 7, fonts: fonts), counts: nil)
    let like = try buttons(of: bar)[2]
    let label = like.countLabelForTesting
    let configured = label.frame.size
    // Text the label was not configured with: layout keeps the configured count's size.
    label.attributedText = NSAttributedString(string: "1,234,567,890", attributes: [.font: fonts.count])
    like.setNeedsLayout()
    like.layoutIfNeeded()
    #expect(label.frame.size == configured)
  }

  @Test("Prepared counts are used only while they are the state's counts in the state's fonts")
  func preparedCountsFollowTheState() throws {
    let (window, host) = try windowedHost(scale: 3)
    defer { window.isHidden = true }
    let fonts = fontsList()[0]
    let bold = fontsList()[1]
    let prepared = FeedActionBarCounts(replyCount: 1, repostCount: 2, likeCount: 3, fonts: fonts)
    let like = try #require(prepared.like)
    #expect(like.matches(count: 3, fonts: fonts))
    #expect(!like.matches(count: 30, fonts: fonts))
    #expect(!like.matches(count: 3, fonts: bold))

    // A live count that changed since the counts were measured is measured again.
    let bar = bar(in: host, state: state(reply: 1, repost: 2, like: 30, fonts: fonts), counts: prepared)
    let buttons = try buttons(of: bar)
    #expect(buttons.map { $0.countLabelForTesting.attributedText?.string } == ["1", "2", "30"])
    for button in buttons {
      #expect(button.countLabelForTesting.frame.size == button.countLabelForTesting.intrinsicContentSize)
    }

    // So are counts in other fonts.
    bar.apply(state(reply: 1, repost: 2, like: 30, fonts: bold), counts: prepared)
    bar.layoutIfNeeded()
    for button in buttons {
      let label = button.countLabelForTesting
      #expect(label.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont == bold.count)
      #expect(label.frame.size == label.intrinsicContentSize)
    }
  }
}
#endif
