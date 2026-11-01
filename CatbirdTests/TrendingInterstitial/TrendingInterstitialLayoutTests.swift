#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import Catbird

@MainActor
@Suite("Trending interstitial layout")
struct TrendingInterstitialLayoutTests {
  private func typography(_ category: UIContentSizeCategory = .large) -> TrendingInterstitialTypography {
    TrendingInterstitialTypography.resolved(
      fontManager: FontManager(), traits: UITraitCollection(preferredContentSizeCategory: category))
  }

  private func topic(
    title: String = "Aurora Watch", category: String? = "Science",
    description: String? = "Northern lights are visible much farther south than usual tonight.",
    postCount: String? = "48K posts", participants: Int = 3
  ) -> TrendingInterstitialLayoutInput.Topic {
    .init(categoryName: category, title: title, description: description, postCountText: postCount,
      participantCount: participants)
  }

  private func layout(
    width: CGFloat = 390, topics: [TrendingInterstitialLayoutInput.Topic],
    videos: TrendingInterstitialLayoutInput.Videos = .hidden,
    typography: TrendingInterstitialTypography? = nil
  ) -> TrendingInterstitialLayout {
    TrendingInterstitialLayoutEngine.layout(.init(
      width: width, typography: typography ?? self.typography(), topics: topics, videos: videos))
  }

  @Test("No topics and hidden videos produce no row")
  func emptyHasNoHeight() {
    #expect(layout(topics: []).height == 0)
    #expect(layout(width: 0, topics: [topic()]).height == 0)
  }

  @Test("Sections stack with the presentation's padding and spacing")
  func sectionsStack() throws {
    let m = TrendingInterstitialMetrics.self
    let result = layout(topics: [topic()], videos: .cards(count: 4))
    let topics = try #require(result.topicsFrame)
    let videosHeader = try #require(result.videosHeader)
    let videos = try #require(result.videosFrame)
    #expect(result.header.titleFrame.minY >= m.verticalPadding)
    #expect(topics.minY == m.verticalPadding + result.header.height + m.sectionSpacing)
    #expect(videosHeader.titleFrame.minY >= topics.maxY + m.sectionSpacing)
    #expect(videos.minY == topics.maxY + m.sectionSpacing + videosHeader.height + m.videosStackSpacing)
    #expect(result.height == ceil(videos.maxY + m.verticalPadding))
    #expect(result.videoCardX.count == 4)
    #expect(result.videosContentWidth == 2 * m.horizontalInset + 4 * m.videoCardWidth + 3 * m.videoCardSpacing)
  }

  @Test("Cards keep both carousel insets and their own padding inside narrow widths",
    arguments: [CGFloat(320), 390, 680])
  func cardWidth(width: CGFloat) {
    let m = TrendingInterstitialMetrics.self
    let result = layout(width: width, topics: [topic(), topic(title: "Cup Final", category: "Sports")])
    let content = min(m.topicCardPreferredWidth, width - 2 * m.horizontalInset - 2 * m.topicCardHorizontalPadding)
    #expect(result.topicCardSize.width == content + 2 * m.topicCardHorizontalPadding)
    #expect(result.topicCardSize.width + 2 * m.horizontalInset <= width)
    #expect(result.topicCardX == [m.horizontalInset, m.horizontalInset + result.topicCardSize.width + m.topicCardSpacing])
  }

  @Test("Every card takes the tallest card's height")
  func sharedHeight() {
    let short = topic(description: nil, participants: 0)
    let tall = topic(description: String(repeating: "A long description that wraps. ", count: 8))
    let result = layout(topics: [short, tall])
    let tallOnly = layout(topics: [tall])
    #expect(result.topicCardSize.height == tallOnly.topicCardSize.height)
  }

  @Test("The description sits beside the media fan, and below it at accessibility sizes")
  func descriptionPlacement() throws {
    let regular = try #require(layout(topics: [topic()]).topicCards.first)
    let regularDescription = try #require(regular.descriptionFrame)
    #expect(regularDescription.minX == regular.mediaFanFrame.maxX + TrendingInterstitialMetrics.topicStackSpacing)
    #expect(regularDescription.minY == regular.mediaFanFrame.minY)

    let large = try #require(layout(topics: [topic()], typography: typography(.accessibilityLarge)).topicCards.first)
    let largeDescription = try #require(large.descriptionFrame)
    #expect(largeDescription.minY == large.mediaFanFrame.maxY + TrendingInterstitialMetrics.topicStackSpacing)
    #expect(largeDescription.minX == large.mediaFanFrame.minX)
  }

  @Test("A missing description reserves only the media fan")
  func missingDescription() throws {
    let card = try #require(layout(topics: [topic(description: nil)]).topicCards.first)
    #expect(card.descriptionFrame == nil)
    let footer = try #require(card.postCountFrame)
    #expect(footer.minY >= card.mediaFanFrame.maxY + TrendingInterstitialMetrics.topicStackSpacing)
    #expect(footer.minY < card.mediaFanFrame.maxY + TrendingInterstitialMetrics.topicStackSpacing
      + TrendingInterstitialMetrics.participantSide)
  }

  @Test("Participants and the post count share a centered footer row")
  func footer() throws {
    let card = try #require(layout(topics: [topic()]).topicCards.first)
    let participants = try #require(card.participantsFrame)
    let count = try #require(card.postCountFrame)
    #expect(abs(participants.width - (26 + 2 * 20)) < 0.001)
    #expect(abs(participants.midY - count.midY) <= 0.5)
    #expect(count.maxX == TrendingInterstitialMetrics.topicCardHorizontalPadding
      + layout(topics: [topic()]).topicCardSize.width - 2 * TrendingInterstitialMetrics.topicCardHorizontalPadding)

    let none = try #require(layout(topics: [topic(postCount: nil, participants: 0)]).topicCards.first)
    #expect(none.participantsFrame == nil)
    #expect(none.postCountFrame == nil)
  }

  @Test("Section headers move the action below a title that cannot share its row")
  func headerFallback() {
    let wide = layout(width: 390, topics: [topic()])
    #expect(abs(wide.header.titleFrame.midY - wide.header.actionFrame.midY) <= 0.5)
    #expect(wide.header.actionFrame.maxX == 390 - TrendingInterstitialMetrics.horizontalInset)

    let narrow = layout(width: 200, topics: [topic()])
    #expect(narrow.header.actionFrame.minY >= narrow.header.titleFrame.maxY)
    #expect(narrow.header.actionFrame.minX == TrendingInterstitialMetrics.horizontalInset)
  }

  @Test("The empty videos message keeps the minimum row height")
  func emptyVideos() throws {
    let m = TrendingInterstitialMetrics.self
    let result = layout(topics: [], videos: .empty(message: TrendingInterstitialModel.emptyVideosMessage))
    let message = try #require(result.emptyVideosFrame)
    let header = try #require(result.videosHeader)
    #expect(result.videosFrame == nil)
    #expect(message.height > 0 && message.height < m.emptyVideosMinimumHeight)
    let rowTop = m.verticalPadding + result.header.height + m.sectionSpacing + header.height + m.videosStackSpacing
    #expect(abs(message.midY - (rowTop + m.emptyVideosMinimumHeight / 2)) <= 0.5)
    #expect(result.height == rowTop + m.emptyVideosMinimumHeight + m.verticalPadding)
  }

  @Test("Measured topic text is what a UILabel needs to draw it", arguments: [
    "Aurora Watch", "A Much Longer Trending Topic Title That Wraps Onto More Lines", "Ünïcödé 🦋 Topic",
  ], ["normal", "tight"])
  func measureMatchesLabel(title: String, lineSpacing: String) throws {
    let t = typography(lineSpacing: lineSpacing)
    let input = topic(title: title, description: title + " " + String(repeating: "described ", count: 10))
    let card = try #require(layout(topics: [input], typography: t).topicCards.first)
    let texts = TrendingInterstitialLayoutEngine.topicTexts(input, typography: t)
    let label = UILabel()
    label.numberOfLines = 0
    for (text, frame) in [(texts.title, card.titleFrame), (try #require(texts.description), try #require(card.descriptionFrame))] {
      label.attributedText = text
      let fitted = label.sizeThatFits(CGSize(width: frame.width, height: .greatestFiniteMagnitude))
      #expect(abs(ceil(fitted.height) - frame.height) <= 0.5)
    }
  }

  // MARK: - Line spacing

  /// Every manager the line-spacing tests create, kept for the test process: the typography cache
  /// keys on a manager's identity and generation, which a new manager at a released one's address
  /// would share.
  private static var fontManagers: [FontManager] = []

  private static func fontManager(lineSpacing: String) -> FontManager {
    let fontManager = FontManager()
    fontManager.lineSpacing = lineSpacing
    fontManagers.append(fontManager)
    return fontManager
  }

  private func typography(lineSpacing: String) -> TrendingInterstitialTypography {
    TrendingInterstitialTypography.resolved(
      fontManager: Self.fontManager(lineSpacing: lineSpacing),
      traits: UITraitCollection(preferredContentSizeCategory: UIApplication.shared.preferredContentSizeCategory))
  }

  private static var screenScale: CGFloat {
    UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.scale }.first ?? 3
  }

  private static func hostedHeight<V: View>(_ view: V, fontManager: FontManager, width: CGFloat) -> CGFloat {
    let host = UIHostingController(rootView:
      view.environment(\.fontManager, fontManager).fixedSize(horizontal: false, vertical: true))
    return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
  }

  /// The native labels against the hosted views they mirror, at every line spacing: the section
  /// heading against `DiscoverySectionHeader`, the category and title against `TrendingTopicHeading`
  /// (both pass a `Font` to `appFont`, spaced by the body size's spacing with no tracking), and the
  /// description, post count and video author against `Text` under the `appFont` the Search
  /// sections give them.
  @Test("Every label is as tall natively as the hosted view draws it", arguments: ["tight", "normal", "relaxed"])
  func labelsMatchHostedViews(setting: String) throws {
    let fontManager = Self.fontManager(lineSpacing: setting)
    let t = TrendingInterstitialTypography.resolved(
      fontManager: fontManager,
      traits: UITraitCollection(preferredContentSizeCategory: UIApplication.shared.preferredContentSizeCategory))
    let width: CGFloat = 260
    let scale = Self.screenScale
    func expectMatch(_ label: String, native: CGFloat, hosted: CGFloat) {
      #expect(abs(hosted - native) < 0.001, "\(setting) \(label): native \(native) hosted \(hosted)")
    }

    let heading = "Trending on\nBluesky\nToday"
    expectMatch("heading",
      native: TrendingInterstitialText.height(
        TrendingInterstitialLayoutEngine.headingText(heading, typography: t), width: width, scale: scale),
      hosted: Self.hostedHeight(
        DiscoverySectionHeader(heading) { EmptyView() }, fontManager: fontManager,
        width: width + 2 * TrendingInterstitialMetrics.horizontalInset))

    let input = topic(
      title: "Aurora Watch\nNorthern Lights\nTonight", category: "science",
      description: "Northern lights are visible much farther south than usual tonight, across three states.",
      postCount: "48.2K posts")
    let texts = TrendingInterstitialLayoutEngine.topicTexts(input, typography: t)
    let category = try #require(texts.category)
    expectMatch("category and title",
      native: TrendingInterstitialText.height(category, width: width, scale: scale)
        + TrendingInterstitialMetrics.topicTitleSpacing
        + TrendingInterstitialText.height(texts.title, width: width, scale: scale),
      hosted: Self.hostedHeight(
        TrendingTopicHeading(title: input.title, category: input.categoryName, size: 18, showsMark: false),
        fontManager: fontManager, width: width))

    let description = try #require(input.description)
    expectMatch("description",
      native: TrendingInterstitialText.height(try #require(texts.description), width: width, scale: scale),
      hosted: Self.hostedHeight(
        Text(description).appFont(AppTextRole.subheadline).lineLimit(nil), fontManager: fontManager, width: width))

    let postCount = try #require(input.postCountText)
    expectMatch("post count",
      native: TrendingInterstitialText.singleLineSize(try #require(texts.postCount), scale: scale).height,
      hosted: Self.hostedHeight(Text(postCount).fixedSize().appFont(AppTextRole.caption), fontManager: fontManager,
        width: width))

    let author = "Alexandra Konstantinopoulou-Vanderbilt of the Northern Lights Society"
    let authorWidth: CGFloat = 106
    let nativeAuthor = TrendingInterstitialText.attributed(
      author, font: t.videoAuthor, lineSpacing: t.videoAuthorLineSpacing, lineHeightFactor: t.lineHeightFactor,
      kerning: t.kerning)
    expectMatch("video author",
      native: TrendingInterstitialText.height(nativeAuthor, width: authorWidth, maximumLines: 2, scale: scale),
      hosted: Self.hostedHeight(
        Text(author).appFont(size: Typography.Size.caption, weight: .medium, relativeTo: .caption).lineLimit(2),
        fontManager: fontManager, width: authorWidth))
  }

  @Test("At Tight every label's lines take the constant line height", .enabled(if: FontManager.supportsLineHeight))
  func tightLineSpacingTightensEveryLabel() throws {
    let t = typography(lineSpacing: "tight")
    let factor = try #require(t.lineHeightFactor)
    #expect(factor == FontManager.tightLineHeightFactor)
    let input = topic(description: String(repeating: "A long description that wraps. ", count: 6))
    let texts = TrendingInterstitialLayoutEngine.topicTexts(input, typography: t)
    let labels: [(NSAttributedString, UIFont)] = [
      (try #require(texts.category), t.categoryName), (texts.title, t.topicTitle),
      (try #require(texts.description), t.subheadline), (try #require(texts.postCount), t.caption),
      (TrendingInterstitialLayoutEngine.headingText(TrendingInterstitialLayoutEngine.topicsHeading, typography: t), t.sectionHeading),
      (TrendingInterstitialLayoutEngine.openVideosText(typography: t), t.videosButton),
    ]
    for (text, font) in labels {
      let paragraph = try #require(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
      let line = AppLineHeightPlacement.resolve(font: font, factor: factor)
      #expect(paragraph.minimumLineHeight == line.lineHeight && paragraph.maximumLineHeight == line.lineHeight,
        "\(text.string)")
      #expect(AppLineHeightPlacement(of: text) == line)
    }
    let description = try #require(texts.description)
    let line = AppLineHeightPlacement.resolve(font: t.subheadline, factor: factor)
    let twoLines = TrendingInterstitialText.height(description, width: 200, maximumLines: 2, scale: 3)
    #expect(abs(twoLines - ceil(line.height(lines: 2) * 3 - 0.001) / 3) < 0.001)
    let single = TrendingInterstitialText.singleLineSize(try #require(texts.postCount), scale: 3)
    let countLine = AppLineHeightPlacement.resolve(font: t.caption, factor: factor)
    #expect(abs(single.height - ceil(countLine.lineHeight * 3 - 0.001) / 3) < 0.001)
    let frame = CGRect(x: 0, y: 10, width: 100, height: 20)
    #expect(TrendingInterstitialText.labelFrame(frame, for: description) == line.labelFrame(textFrame: frame))
    #expect(TrendingInterstitialText.labelFrame(
      frame, for: TrendingInterstitialLayoutEngine.topicTexts(input, typography: typography(lineSpacing: "normal")).title)
      == frame)
  }

  @Test("Tight line spacing shortens topic cards", .enabled(if: FontManager.supportsLineHeight))
  func tightShortensTopicCards() {
    let description = String(repeating: "A long description that wraps. ", count: 6)
    let tight = layout(topics: [topic(description: description)], typography: typography(lineSpacing: "tight"))
    let normal = layout(topics: [topic(description: description)], typography: typography(lineSpacing: "normal"))
    #expect(tight.topicCardSize.height < normal.topicCardSize.height,
      "tight \(tight.topicCardSize.height) normal \(normal.topicCardSize.height)")
  }

  @Test("Layouts are cached by input")
  func cache() {
    let input = TrendingInterstitialLayoutInput(width: 375, typography: typography(), topics: [topic()], videos: .hidden)
    #expect(TrendingInterstitialLayoutCache.layout(for: input) == TrendingInterstitialLayoutEngine.layout(input))
    #expect(TrendingInterstitialLayoutCache.layout(for: input) == TrendingInterstitialLayoutCache.layout(for: input))
  }
}
#endif
