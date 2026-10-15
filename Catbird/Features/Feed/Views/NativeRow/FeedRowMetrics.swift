#if os(iOS)
import CoreGraphics

// MARK: - Feed Row Metrics

/// Geometry of the SwiftUI feed row, mirrored for native rows. Sources:
/// EnhancedFeedPost.swift:181-182, PostView.swift AuthorAvatarColumn / PostContentLayout,
/// PostHeaderView.swift:39-41, FeedActionBar.height, FeedPostRow divider.
enum FeedRowMetrics {
  static let rowTop: CGFloat = 9            // EnhancedFeedPost .padding(.top, baseUnit * 3)
  static let rowHorizontal: CGFloat = 4.5   // EnhancedFeedPost .padding(.horizontal, baseUnit * 1.5)
  static let avatarSize: CGFloat = 48       // ThreadReplyGeometry.linearAvatarSize
  static let avatarColumnWidth: CGFloat = avatarSize + 6
  static let avatarColumnInset: CGFloat = 3 // AuthorAvatarColumn horizontal and top padding
  static let columnSpacing: CGFloat = 3     // DesignTokens.Spacing.xs
  static let contentTop: CGFloat = 3        // postContentColumn .padding(.top, baseUnit)
  static let headerHorizontal: CGFloat = 3
  static let headerSpacing: CGFloat = 8     // PostHeaderView.spacing
  static let minimumTruncatedHandleWidth: CGFloat = 56
  static let optionsButtonSide: CGFloat = 38 // ellipsis glyph + padding(baseUnit * 3)
  static let textTop: CGFloat = 3 + 3        // PostRecordText top padding + TappableTextView padding(3)
  static let textBottom: CGFloat = 3 + 3
  static let textHorizontal: CGFloat = 3     // TappableTextView padding(3)
  static let actionBarHeight: CGFloat = 45   // FeedActionBar.height
  static let actionBarBottom: CGFloat = 3
  static let dividerHeight: CGFloat = 0.5
  static let maxRegularWidthContent: CGFloat = 600
}
#endif
