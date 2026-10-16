#if os(iOS)
import UIKit

// MARK: - Metrics

/// Geometry of the trending interstitial. Section headers match `DiscoverySectionHeader` and the
/// video carousel matches `TrendingVideosSection(presentation: .timeline)`, so the row lines up with
/// the same sections in Search.
enum TrendingInterstitialMetrics {
  static let verticalPadding: CGFloat = 12        // Spacing.base
  static let sectionSpacing: CGFloat = 12         // Spacing.base
  static let horizontalInset: CGFloat = 16        // DiscoverySectionHeader / carousels .padding(.horizontal, 16)
  static let headerActionSpacing: CGFloat = 12    // DiscoverySectionHeader HStack spacing Spacing.base
  static let headerStackSpacing: CGFloat = 3      // DiscoverySectionHeader VStack spacing Spacing.xs
  static let optionsButtonSide: CGFloat = 44      // "Trending options" label frame
  static let disclosureSpacing: CGFloat = 4       // DisclosureLinkLabelStyle HStack spacing
  static let minimumActionHeight: CGFloat = 44    // "Open The Vids" .frame(minHeight: 44)

  static let topicCardSpacing: CGFloat = 6        // carousel HStack spacing Spacing.sm
  static let topicCardPreferredWidth: CGFloat = 300
  static let topicCardHorizontalPadding: CGFloat = 12  // Spacing.base
  static let topicCardVerticalPadding: CGFloat = 9     // Spacing.md
  static let topicCardCornerRadius: CGFloat = 9        // Size.radiusMD
  static let topicStackSpacing: CGFloat = 6       // card VStack and row HStack spacing Spacing.sm
  static let topicTitleSpacing: CGFloat = 3       // category/title VStack spacing Spacing.xs
  static let mediaFanSize = CGSize(width: 108, height: 86)
  static let mediaCardSize = CGSize(width: 62, height: 72)
  static let mediaCardCornerRadius: CGFloat = 7
  static let participantSide: CGFloat = 26
  static let participantOverlap: CGFloat = 6      // HStack(spacing: -6)

  static let videosStackSpacing: CGFloat = 6      // TrendingVideosSection VStack spacing Spacing.sm
  static let videoCardSpacing: CGFloat = 12       // LazyHStack spacing Spacing.base
  static let videoCardWidth: CGFloat = 136        // Presentation.timeline.width
  static let videoCardAccessibilityWidth: CGFloat = 208
  static let videoThumbnailHeight: CGFloat = 144  // Presentation.timeline.thumbnailHeight
  static let videoAuthorSpacing: CGFloat = 6      // card VStack and author HStack spacing Spacing.sm
  static let videoCornerRadius: CGFloat = 9       // Size.radiusMD
  static let playBadgeSide: CGFloat = 28
  static let playBadgeInset: CGFloat = 8
  static let emptyVideosMinimumHeight: CGFloat = 64
}

// MARK: - Layout Input

/// Everything the layout depends on. `@unchecked Sendable`: typography holds immutable `UIFont`s.
struct TrendingInterstitialLayoutInput: Hashable, @unchecked Sendable {
  struct Topic: Hashable {
    let categoryName: String?
    let title: String
    let description: String?
    let postCountText: String?
    let participantCount: Int
  }

  enum Videos: Hashable {
    case hidden
    case cards(count: Int)
    case empty(message: String)
  }

  let width: CGFloat
  let typography: TrendingInterstitialTypography
  /// Shown topic cards; empty when the topics section is hidden.
  let topics: [Topic]
  let videos: Videos

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.width == rhs.width && lhs.typography.generationKey == rhs.typography.generationKey
      && lhs.topics == rhs.topics && lhs.videos == rhs.videos
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(width)
    hasher.combine(typography.generationKey)
    hasher.combine(topics)
    hasher.combine(videos)
  }

  var hasContent: Bool {
    if !topics.isEmpty { return true }
    if case .hidden = videos { return false }
    return true
  }
}

// MARK: - Layout Output

struct TrendingSectionHeaderLayout: Equatable {
  let titleFrame: CGRect
  let actionFrame: CGRect
  let height: CGFloat
}

struct TrendingTopicCardLayout: Equatable {
  /// Frames are relative to the card.
  let markFrame: CGRect
  let categoryFrame: CGRect?
  let titleFrame: CGRect
  let mediaFanFrame: CGRect
  let descriptionFrame: CGRect?
  let participantsFrame: CGRect?
  let postCountFrame: CGRect?
}

struct TrendingVideoCardLayout: Equatable {
  /// Frames are relative to the card.
  let thumbnailFrame: CGRect
  let avatarFrame: CGRect
  let authorFrame: CGRect
}

struct TrendingInterstitialLayout: Equatable {
  let width: CGFloat
  let height: CGFloat
  let header: TrendingSectionHeaderLayout
  /// Carousel frame in the cell; cards are placed in its content at `topicCardX`.
  let topicsFrame: CGRect?
  let topicCardSize: CGSize
  let topicCardX: [CGFloat]
  let topicsContentWidth: CGFloat
  let topicCards: [TrendingTopicCardLayout]
  let videosHeader: TrendingSectionHeaderLayout?
  let videosFrame: CGRect?
  let videoCardSize: CGSize
  let videoCardX: [CGFloat]
  let videosContentWidth: CGFloat
  let videoCard: TrendingVideoCardLayout
  let emptyVideosFrame: CGRect?

  static let empty = TrendingInterstitialLayout(
    width: 0, height: 0,
    header: TrendingSectionHeaderLayout(titleFrame: .zero, actionFrame: .zero, height: 0),
    topicsFrame: nil, topicCardSize: .zero, topicCardX: [], topicsContentWidth: 0, topicCards: [],
    videosHeader: nil, videosFrame: nil, videoCardSize: .zero, videoCardX: [],
    videosContentWidth: 0,
    videoCard: TrendingVideoCardLayout(thumbnailFrame: .zero, avatarFrame: .zero, authorFrame: .zero),
    emptyVideosFrame: nil)
}

// MARK: - Text

/// Attributed strings for every label in the cell. Labels and measurement use the same strings,
/// so measured heights match what `UILabel` draws.
enum TrendingInterstitialText {
  /// `lineHeightFactor` gives every line a constant line height ("Tight"), as SwiftUI's `appFont`
  /// draws it; labels showing the text take their frames from `labelFrame(_:for:)`.
  static func attributed(
    _ string: String, font: UIFont, color: UIColor = .label, lineSpacing: CGFloat, lineHeightFactor: CGFloat?,
    kerning: CGFloat, alignment: NSTextAlignment = .natural
  ) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = max(0, lineSpacing)
    if let lineHeightFactor {
      AppLineHeightPlacement.resolve(font: font, factor: lineHeightFactor).apply(to: paragraph)
    }
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byWordWrapping
    var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    // SwiftUI `.tracking(0)` keeps the font's kerning pairs; a `.kern` of 0 would disable them.
    if kerning != 0 { attributes[.tracking] = kerning }
    return NSAttributedString(string: string, attributes: attributes)
  }

  /// The frame of a label drawing `text` where SwiftUI draws it in `frame`: when the text has a
  /// constant line height, `AppLineHeightPlacement.labelFrame(textFrame:)`.
  static func labelFrame(_ frame: CGRect, for text: NSAttributedString?) -> CGRect {
    AppLineHeightPlacement(of: text)?.labelFrame(textFrame: frame) ?? frame
  }

  /// The height of one of `text`'s lines: its constant line height, or its font's own.
  private static func oneLineHeight(of text: NSAttributedString) -> CGFloat? {
    let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    if let style, style.maximumLineHeight > 0 { return style.maximumLineHeight }
    return (text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.lineHeight
  }

  /// Rounds up to the next device pixel, as SwiftUI aligns text frames; whole points would add
  /// up to a point per label and drift every following frame.
  static func pixelCeil(_ value: CGFloat, scale: CGFloat) -> CGFloat {
    let scale = max(1, scale)
    return ceil(value * scale - 0.001) / scale
  }

  /// Centered origins snap to the nearest device pixel, as SwiftUI places them.
  static func pixelRound(_ value: CGFloat, scale: CGFloat) -> CGFloat {
    let scale = max(1, scale)
    return (value * scale).rounded() / scale
  }

  static func height(_ text: NSAttributedString, width: CGFloat, maximumLines: Int = 0, scale: CGFloat) -> CGFloat {
    guard text.length > 0, width > 0 else { return 0 }
    let rect = text.boundingRect(
      with: CGSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    var height = rect.height
    if maximumLines > 0, let lineHeight = oneLineHeight(of: text) {
      let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
      let limit = lineHeight * CGFloat(maximumLines) + (style?.lineSpacing ?? 0) * CGFloat(maximumLines - 1)
      height = min(height, limit)
    }
    return pixelCeil(height, scale: scale)
  }

  static func singleLineSize(_ text: NSAttributedString, scale: CGFloat) -> CGSize {
    guard text.length > 0 else { return .zero }
    let rect = text.boundingRect(
      with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
      options: [.usesFontLeading], context: nil)
    // Measured as one line from its baseline, the text takes its font's height; a constant line
    // height replaces it.
    let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    let height = style.flatMap { $0.maximumLineHeight > 0 ? $0.maximumLineHeight : nil } ?? rect.height
    return CGSize(width: pixelCeil(rect.width, scale: scale), height: pixelCeil(height, scale: scale))
  }
}

// MARK: - Layout Engine

enum TrendingInterstitialLayoutEngine {
  static let topicsHeading = "Trending on Bluesky"
  static let videosHeading = "Trending Videos"
  static let openVideosTitle = "Open The Vids"

  static func layout(_ input: TrendingInterstitialLayoutInput) -> TrendingInterstitialLayout {
    guard input.hasContent, input.width > 0 else { return .empty }
    let m = TrendingInterstitialMetrics.self
    let t = input.typography
    var y = m.verticalPadding

    let header = sectionHeader(
      title: topicsHeading, actionSize: CGSize(width: m.optionsButtonSide, height: m.optionsButtonSide),
      width: input.width, typography: t)
    let headerLayout = header.offset(by: y)
    y += header.height

    // Topics carousel
    var topicsFrame: CGRect?
    var topicCards: [TrendingTopicCardLayout] = []
    var topicCardSize = CGSize.zero
    var topicCardX: [CGFloat] = []
    var topicsContentWidth: CGFloat = 0
    if !input.topics.isEmpty {
      let contentWidth = min(m.topicCardPreferredWidth,
        max(0, input.width - 2 * m.horizontalInset - 2 * m.topicCardHorizontalPadding))
      let measured = input.topics.map { topicCard($0, contentWidth: contentWidth, typography: t) }
      let cardHeight = measured.map(\.height).max() ?? 0
      topicCardSize = CGSize(width: contentWidth + 2 * m.topicCardHorizontalPadding, height: cardHeight)
      topicCards = measured.map(\.layout)
      topicCardX = input.topics.indices.map { m.horizontalInset + CGFloat($0) * (topicCardSize.width + m.topicCardSpacing) }
      topicsContentWidth = 2 * m.horizontalInset + CGFloat(input.topics.count) * topicCardSize.width
        + CGFloat(input.topics.count - 1) * m.topicCardSpacing
      y += m.sectionSpacing
      topicsFrame = CGRect(x: 0, y: y, width: input.width, height: cardHeight)
      y += cardHeight
    }

    // Videos section
    var videosHeader: TrendingSectionHeaderLayout?
    var videosFrame: CGRect?
    var videoCardSize = CGSize.zero
    var videoCardX: [CGFloat] = []
    var videosContentWidth: CGFloat = 0
    var emptyVideosFrame: CGRect?
    let cardWidth = t.isAccessibilitySize ? m.videoCardAccessibilityWidth : m.videoCardWidth
    let avatarSide = t.videoAuthorAvatarSize
    let videoCard = TrendingVideoCardLayout(
      thumbnailFrame: CGRect(x: 0, y: 0, width: cardWidth, height: m.videoThumbnailHeight),
      avatarFrame: CGRect(x: 0, y: m.videoThumbnailHeight + m.videoAuthorSpacing, width: avatarSide, height: avatarSide),
      authorFrame: CGRect(
        x: avatarSide + m.videoAuthorSpacing, y: m.videoThumbnailHeight + m.videoAuthorSpacing,
        width: max(0, cardWidth - avatarSide - m.videoAuthorSpacing),
        height: min(t.videoAuthorHeight, authorTextHeight(typography: t))))
    switch input.videos {
    case .hidden:
      break
    case .cards(let count):
      y += m.sectionSpacing
      let action = openVideosActionSize(width: input.width, typography: t)
      let videos = sectionHeader(title: videosHeading, actionSize: action, width: input.width, typography: t)
      videosHeader = videos.offset(by: y)
      y += videos.height + m.videosStackSpacing
      videoCardSize = CGSize(width: cardWidth, height: m.videoThumbnailHeight + m.videoAuthorSpacing + t.videoAuthorHeight)
      videoCardX = (0..<count).map { m.horizontalInset + CGFloat($0) * (cardWidth + m.videoCardSpacing) }
      videosContentWidth = 2 * m.horizontalInset + CGFloat(count) * cardWidth + CGFloat(max(0, count - 1)) * m.videoCardSpacing
      videosFrame = CGRect(x: 0, y: y, width: input.width, height: videoCardSize.height)
      y += videoCardSize.height
    case .empty(let message):
      y += m.sectionSpacing
      let action = openVideosActionSize(width: input.width, typography: t)
      let videos = sectionHeader(title: videosHeading, actionSize: action, width: input.width, typography: t)
      videosHeader = videos.offset(by: y)
      y += videos.height + m.videosStackSpacing
      let textWidth = max(0, input.width - 2 * m.horizontalInset)
      let text = TrendingInterstitialText.attributed(
        message, font: t.subheadline, lineSpacing: t.roleLineSpacing, lineHeightFactor: t.lineHeightFactor,
        kerning: t.kerning)
      let textHeight = TrendingInterstitialText.height(text, width: textWidth, scale: t.displayScale)
      let rowHeight = max(m.emptyVideosMinimumHeight, textHeight)
      emptyVideosFrame = CGRect(x: m.horizontalInset, y: y + (rowHeight - textHeight) / 2, width: textWidth, height: textHeight)
      y += rowHeight
    }
    y += m.verticalPadding

    return TrendingInterstitialLayout(
      width: input.width, height: TrendingInterstitialText.pixelCeil(y, scale: t.displayScale), header: headerLayout,
      topicsFrame: topicsFrame, topicCardSize: topicCardSize, topicCardX: topicCardX,
      topicsContentWidth: topicsContentWidth, topicCards: topicCards,
      videosHeader: videosHeader,
      videosFrame: videosFrame, videoCardSize: videoCardSize, videoCardX: videoCardX,
      videosContentWidth: videosContentWidth, videoCard: videoCard, emptyVideosFrame: emptyVideosFrame)
  }

  // MARK: Section header

  /// `DiscoverySectionHeader`: title and action on one row when both fit at their ideal widths
  /// (`ViewThatFits`), otherwise the wrapped title above the leading-aligned action.
  static func sectionHeader(
    title: String, actionSize: CGSize, width: CGFloat, typography t: TrendingInterstitialTypography
  ) -> TrendingSectionHeaderLayout {
    let m = TrendingInterstitialMetrics.self
    let available = max(0, width - 2 * m.horizontalInset)
    let text = headingText(title, typography: t)
    let single = TrendingInterstitialText.singleLineSize(text, scale: t.displayScale)
    if single.width + m.headerActionSpacing + actionSize.width <= available {
      let rowHeight = max(single.height, actionSize.height)
      return TrendingSectionHeaderLayout(
        titleFrame: CGRect(
          x: m.horizontalInset, y: TrendingInterstitialText.pixelRound((rowHeight - single.height) / 2, scale: t.displayScale),
          width: single.width, height: single.height),
        actionFrame: CGRect(
          x: m.horizontalInset + available - actionSize.width,
          y: TrendingInterstitialText.pixelRound((rowHeight - actionSize.height) / 2, scale: t.displayScale),
          width: actionSize.width, height: actionSize.height),
        height: rowHeight)
    }
    let titleHeight = TrendingInterstitialText.height(text, width: available, scale: t.displayScale)
    let actionWidth = min(actionSize.width, available)
    return TrendingSectionHeaderLayout(
      titleFrame: CGRect(x: m.horizontalInset, y: 0, width: available, height: titleHeight),
      actionFrame: CGRect(x: m.horizontalInset, y: titleHeight + m.headerStackSpacing, width: actionWidth, height: actionSize.height),
      height: titleHeight + m.headerStackSpacing + actionSize.height)
  }

  static func headingText(_ title: String, typography t: TrendingInterstitialTypography) -> NSAttributedString {
    TrendingInterstitialText.attributed(
      title, font: t.sectionHeading, lineSpacing: t.headingLineSpacing, lineHeightFactor: t.lineHeightFactor, kerning: 0)
  }

  static func openVideosText(typography t: TrendingInterstitialTypography) -> NSAttributedString {
    TrendingInterstitialText.attributed(
      openVideosTitle, font: t.videosButton, color: .tintColor, lineSpacing: t.videosButtonLineSpacing,
      lineHeightFactor: t.lineHeightFactor, kerning: t.kerning)
  }

  /// "Open The Vids" label plus the small disclosure chevron, at least 44pt tall.
  static func openVideosActionSize(width: CGFloat, typography t: TrendingInterstitialTypography) -> CGSize {
    let m = TrendingInterstitialMetrics.self
    let text = TrendingInterstitialText.singleLineSize(openVideosText(typography: t), scale: t.displayScale)
    let glyph = t.disclosureGlyphSize
    return CGSize(
      width: text.width + m.disclosureSpacing + glyph.width,
      height: max(m.minimumActionHeight, text.height, glyph.height))
  }

  // MARK: Topic card

  static func topicTexts(_ topic: TrendingInterstitialLayoutInput.Topic, typography t: TrendingInterstitialTypography)
    -> (category: NSAttributedString?, title: NSAttributedString, description: NSAttributedString?, postCount: NSAttributedString?) {
    (
      topic.categoryName.map {
        TrendingInterstitialText.attributed(
          $0, font: t.categoryName, lineSpacing: t.roleLineSpacing, lineHeightFactor: t.lineHeightFactor,
          kerning: t.kerning)
      },
      TrendingInterstitialText.attributed(
        topic.title, font: t.topicTitle, lineSpacing: t.headingLineSpacing, lineHeightFactor: t.lineHeightFactor,
        kerning: 0),
      topic.description.map {
        TrendingInterstitialText.attributed(
          $0, font: t.subheadline, color: .secondaryLabel, lineSpacing: t.roleLineSpacing,
          lineHeightFactor: t.lineHeightFactor, kerning: t.kerning)
      },
      topic.postCountText.map {
        TrendingInterstitialText.attributed(
          $0, font: t.caption, color: .secondaryLabel, lineSpacing: t.roleLineSpacing,
          lineHeightFactor: t.lineHeightFactor, kerning: t.kerning)
      }
    )
  }

  static func topicCard(
    _ topic: TrendingInterstitialLayoutInput.Topic, contentWidth: CGFloat, typography t: TrendingInterstitialTypography
  ) -> (layout: TrendingTopicCardLayout, height: CGFloat) {
    let m = TrendingInterstitialMetrics.self
    let texts = topicTexts(topic, typography: t)
    let x0 = m.topicCardHorizontalPadding
    let y0 = m.topicCardVerticalPadding
    let diameter = t.markDiameter

    // Category mark beside the category name and the freely wrapping title.
    let columnX = x0 + diameter + m.topicStackSpacing
    let columnWidth = max(0, contentWidth - diameter - m.topicStackSpacing)
    var categoryFrame: CGRect?
    var columnHeight: CGFloat = 0
    if let category = texts.category {
      let height = TrendingInterstitialText.height(category, width: columnWidth, scale: t.displayScale)
      categoryFrame = CGRect(x: columnX, y: y0, width: columnWidth, height: height)
      columnHeight = height + m.topicTitleSpacing
    }
    let titleHeight = TrendingInterstitialText.height(texts.title, width: columnWidth, scale: t.displayScale)
    let titleFrame = CGRect(x: columnX, y: y0 + columnHeight, width: columnWidth, height: titleHeight)
    columnHeight += titleHeight
    let headingHeight = max(diameter, columnHeight)
    let markFrame = CGRect(x: x0, y: y0, width: diameter, height: diameter)

    // Media fan beside the description, or above it at accessibility sizes.
    let previewY = y0 + headingHeight + m.topicStackSpacing
    let fanFrame = CGRect(origin: CGPoint(x: x0, y: previewY), size: m.mediaFanSize)
    var descriptionFrame: CGRect?
    var previewHeight = m.mediaFanSize.height
    if let description = texts.description {
      if t.isAccessibilitySize {
        let height = TrendingInterstitialText.height(description, width: contentWidth, scale: t.displayScale)
        descriptionFrame = CGRect(x: x0, y: fanFrame.maxY + m.topicStackSpacing, width: contentWidth, height: height)
        previewHeight += m.topicStackSpacing + height
      } else {
        let width = max(0, contentWidth - m.mediaFanSize.width - m.topicStackSpacing)
        let height = TrendingInterstitialText.height(description, width: width, scale: t.displayScale)
        descriptionFrame = CGRect(x: fanFrame.maxX + m.topicStackSpacing, y: previewY, width: width, height: height)
        previewHeight = max(previewHeight, height)
      }
    }

    // Footer: participants leading, post count trailing, both centered on the row.
    let footerY = previewY + previewHeight + m.topicStackSpacing
    let countSize = texts.postCount.map { TrendingInterstitialText.singleLineSize($0, scale: t.displayScale) } ?? .zero
    let participantCount = topic.participantCount
    let footerHeight = max(participantCount > 0 ? m.participantSide : 0, countSize.height)
    let participantsFrame: CGRect? = participantCount > 0
      ? CGRect(
        x: x0, y: footerY + (footerHeight - m.participantSide) / 2,
        width: m.participantSide + CGFloat(participantCount - 1) * (m.participantSide - m.participantOverlap),
        height: m.participantSide)
      : nil
    let countWidth = min(countSize.width, contentWidth)
    let postCountFrame: CGRect? = texts.postCount == nil ? nil
      : CGRect(x: x0 + contentWidth - countWidth, y: footerY + (footerHeight - countSize.height) / 2,
        width: countWidth, height: countSize.height)

    let height = footerY + footerHeight + m.topicCardVerticalPadding
    return (
      TrendingTopicCardLayout(
        markFrame: markFrame, categoryFrame: categoryFrame, titleFrame: titleFrame, mediaFanFrame: fanFrame,
        descriptionFrame: descriptionFrame, participantsFrame: participantsFrame, postCountFrame: postCountFrame),
      TrendingInterstitialText.pixelCeil(height, scale: t.displayScale)
    )
  }

  // MARK: Video card

  /// Two author lines; `TrendingVideosSection` reserves `videoAuthorHeight` for them.
  static func authorTextHeight(typography t: TrendingInterstitialTypography) -> CGFloat {
    let lineHeight = t.lineHeightFactor.map { AppLineHeightPlacement.resolve(font: t.videoAuthor, factor: $0).lineHeight }
      ?? t.videoAuthor.lineHeight
    return TrendingInterstitialText.pixelCeil(lineHeight * 2 + max(0, t.videoAuthorLineSpacing), scale: t.displayScale)
  }
}

// MARK: - Helpers

extension TrendingSectionHeaderLayout {
  func offset(by y: CGFloat) -> TrendingSectionHeaderLayout {
    TrendingSectionHeaderLayout(
      titleFrame: titleFrame.offsetBy(dx: 0, dy: y), actionFrame: actionFrame.offsetBy(dx: 0, dy: y), height: height)
  }
}

// MARK: - Layout Cache

/// Layouts by input. The interstitial is one row per feed, so a handful of entries covers
/// both orientations and a settings change.
@MainActor
enum TrendingInterstitialLayoutCache {
  private static var entries: [(input: TrendingInterstitialLayoutInput, layout: TrendingInterstitialLayout)] = []
  private static let capacity = 4

  static func layout(for input: TrendingInterstitialLayoutInput) -> TrendingInterstitialLayout {
    if let index = entries.firstIndex(where: { $0.input == input }) {
      return entries[index].layout
    }
    let layout = TrendingInterstitialLayoutEngine.layout(input)
    entries.append((input, layout))
    if entries.count > capacity { entries.removeFirst() }
    return layout
  }
}
#endif
