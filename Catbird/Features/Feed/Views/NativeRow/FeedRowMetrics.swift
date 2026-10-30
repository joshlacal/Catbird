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
  /// The avatar column's frame; the avatar is centered in it (`AuthorAvatarColumn` `.frame(width:)`).
  static let avatarColumnWidth: CGFloat = avatarSize + 6
  static let avatarColumnInset: CGFloat = 3 // AuthorAvatarColumn horizontal and top padding
  static let columnSpacing: CGFloat = 3     // DesignTokens.Spacing.xs
  static let contentTop: CGFloat = 3        // postContentColumn .padding(.top, baseUnit)
  static let headerHorizontal: CGFloat = 3  // postHeader .padding(.horizontal, baseUnit)
  static let headerSpacing: CGFloat = 8     // PostHeaderView.spacing
  static let minimumTruncatedHandleWidth: CGFloat = 56
  /// Padding around the options ellipsis glyph (`postOptionsGlyph` `.padding(baseUnit * 3)`). The
  /// padded glyph is the options button, so the header is at least the glyph plus twice this.
  static let optionsGlyphPadding: CGFloat = 9
  /// Header to text: postContentColumn VStack spacing (3) + PostRecordText top padding (3) +
  /// TappableTextView padding (3).
  static let textTop: CGFloat = 3 + 3 + 3
  /// Text to action bar: TappableTextView padding (3) + PostRecordText bottom padding (3) +
  /// postContentColumn VStack spacing (3).
  static let textBottom: CGFloat = 3 + 3 + 3
  /// TappableTextView padding(3) on every side. A post without text has no text view, so this
  /// inset is absent above and below its (empty) text frame.
  static let textHorizontal: CGFloat = 3
  static let actionBarHeight: CGFloat = 45   // FeedActionBar.height
  static let actionBarBottom: CGFloat = 3
  static let dividerHeight: CGFloat = 0.5
  /// EnhancedFeedPost's content width in a regular horizontal size class; the row is centered.
  static let maxRegularWidthContent: CGFloat = 600
}
#endif
