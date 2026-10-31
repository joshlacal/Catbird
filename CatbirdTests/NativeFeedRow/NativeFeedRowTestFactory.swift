#if os(iOS)
import Foundation
import Petrel
import Testing
import UIKit
@testable import Catbird

// MARK: - Native Feed Row Test Factory

/// Builds native feed row layout inputs, row content and configured cells from
/// `FeedRowTestPosts` fixtures.
///
/// Fonts are scaled for an explicit content size category with
/// `UIFontMetrics.scaledFont(for:compatibleWith:)`, so results do not depend on the
/// simulator's text size setting.
@MainActor
enum NativeFeedRowTestFactory {
  static let width: CGFloat = 390
  static let displayName = "Alice Rivera"
  static let handle = "@author.test"
  static let timeText = "3m"
  static let timeAccessibilityLabel = "3 minutes ago"

  // MARK: - Typography

  static func typography(contentSize: UIContentSizeCategory) -> FeedRowTypography {
    let traits = UITraitCollection(preferredContentSizeCategory: contentSize)
    func scaled(_ size: CGFloat, weight: UIFont.Weight, style: UIFont.TextStyle) -> UIFont {
      UIFontMetrics(forTextStyle: style).scaledFont(
        for: .systemFont(ofSize: size, weight: weight), compatibleWith: traits)
    }
    let fontManager = FontManager()
    let body = scaled(Typography.Size.body, weight: .regular, style: .body)
    var hasher = Hasher()
    hasher.combine(contentSize.rawValue)
    return FeedRowTypography(
      body: body,
      name: scaled(Typography.Size.headline, weight: .semibold, style: .headline),
      metadata: scaled(Typography.Size.body, weight: .regular, style: .body),
      bodyLineSpacing: FeedRowTypography.bodyLineSpacing(fontManager: fontManager),
      kerning: fontManager.letterSpacingValue,
      optionsGlyphSize: FeedRowTypography.optionsGlyphSize(contentSize: contentSize),
      separatorLineHeight: FeedRowTypography.separatorLineHeight(contentSize: contentSize),
      generationKey: hasher.finalize())
  }

  // MARK: - Inputs and Content

  static func layoutInput(text: String, contentSize: UIContentSizeCategory = .large) throws -> FeedRowLayoutInput {
    try parts(text: text, contentSize: contentSize, postKey: "one", verification: nil).input
  }

  static func content(
    text: String, contentSize: UIContentSizeCategory = .large, postKey: String = "one",
    verification: VerificationBadgeKind? = nil
  ) throws -> NativeFeedRowContent {
    let parts = try parts(text: text, contentSize: contentSize, postKey: postKey, verification: verification)
    let barState = actionBarState(for: parts.post)
    return NativeFeedRowContent(
      post: parts.post, layout: FeedRowLayoutEngine.layout(parts.input), text: parts.input.text,
      displayName: displayName, handle: handle, timeText: timeText,
      timeAccessibilityLabel: timeAccessibilityLabel, verification: verification,
      actionBarState: barState, metadataColor: .secondaryLabel,
      actionBarCounts: FeedActionBarCounts(
        replyCount: barState.replyCount, repostCount: barState.repostCount, likeCount: barState.likeCount,
        fonts: barState.fonts),
      avatarURL: parts.post.author.finalAvatarURL())
  }

  static func actionBarState(for post: AppBskyFeedDefs.PostView) -> FeedActionBarState {
    FeedActionBarState(
      postURI: post.uri.uriString(), replyCount: post.replyCount ?? 0, isReplyDisabled: false,
      repostCount: post.repostCount ?? 0, isReposted: post.viewer?.repost != nil, isQuoteDisabled: false,
      likeCount: post.likeCount ?? 0, isLiked: post.viewer?.like != nil, isShareEnabled: true,
      canSendViaChat: true, canCopyLink: true, reduceMotion: true,
      fonts: .resolved(fontManager: FontManager(), boldText: false))
  }

  // MARK: - Cells

  static func configuredCell(
    text: String, contentSize: UIContentSizeCategory = .large, postKey: String = "one",
    verification: VerificationBadgeKind? = nil, actions: NativeFeedRowActions? = nil,
    shadowUpdates: @escaping @Sendable (String) async -> AsyncStream<AppBskyFeedDefs.PostView> = finishedShadowUpdates
  ) throws -> (NativeFeedPostCell, NativeFeedRowContent) {
    let content = try content(text: text, contentSize: contentSize, postKey: postKey, verification: verification)
    let cell = NativeFeedPostCell(frame: CGRect(x: 0, y: 0, width: content.layout.width, height: content.layout.height))
    cell.configure(
      content, typography: typography(contentSize: contentSize), actions: actions ?? noOpActions,
      shadowUpdates: shadowUpdates)
    return (cell, content)
  }

  static var noOpActions: NativeFeedRowActions {
    NativeFeedRowActions(
      openPost: { _ in }, openProfile: { _ in }, openLink: { _ in },
      actionBar: { _ in noOpActionBarActions }, optionsMenu: { _ in [] }, layoutWidthChanged: { _, _ in })
  }

  static var noOpActionBarActions: FeedActionBarActions {
    FeedActionBarActions(
      reply: {}, toggleRepost: {}, quote: {}, toggleLike: {}, sendViaChat: {}, copyLink: {}, moreSharing: {})
  }

  /// A shadow stream with no updates.
  nonisolated static let finishedShadowUpdates: @Sendable (String) async -> AsyncStream<AppBskyFeedDefs.PostView> = { _ in
    AsyncStream { $0.finish() }
  }

  // MARK: - Building

  private struct Parts {
    let post: AppBskyFeedDefs.PostView
    let input: FeedRowLayoutInput
  }

  private static func parts(
    text: String, contentSize: UIContentSizeCategory, postKey: String, verification: VerificationBadgeKind?
  ) throws -> Parts {
    let cached = try FeedRowTestPosts.cachedPost(text: text, displayName: displayName, postKey: postKey)
    let post = try cached.feedViewPost.post
    guard case .knownType(let record) = post.record, let feedPost = record as? AppBskyFeedPost else {
      throw FactoryError.notAPost
    }
    let typography = typography(contentSize: contentSize)
    let attributed = FeedPostTextBuilder.build(
      post: feedPost, typography: typography, linkStyle: .color, textColor: .label, linkColor: .systemBlue)
    let input = FeedRowLayoutInput(
      postID: cached.id, width: width, typography: typography, displayName: displayName, handle: handle,
      timeText: timeText, verificationSymbol: verification?.symbolName, text: attributed,
      contentSignature: FeedPostContentSignature(cached))
    return Parts(post: post, input: input)
  }

  private enum FactoryError: Error {
    case notAPost
  }
}
#endif
