#if os(iOS)
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
  ])
  func measureMatchesLabel(title: String) throws {
    let t = typography()
    let input = topic(title: title, description: title + " " + String(repeating: "described ", count: 10))
    let card = try #require(layout(topics: [input]).topicCards.first)
    let texts = TrendingInterstitialLayoutEngine.topicTexts(input, typography: t)
    let label = UILabel()
    label.numberOfLines = 0
    for (text, frame) in [(texts.title, card.titleFrame), (try #require(texts.description), try #require(card.descriptionFrame))] {
      label.attributedText = text
      let fitted = label.sizeThatFits(CGSize(width: frame.width, height: .greatestFiniteMagnitude))
      #expect(abs(ceil(fitted.height) - frame.height) <= 0.5)
    }
  }

  @Test("Layouts are cached by input")
  func cache() {
    let input = TrendingInterstitialLayoutInput(width: 375, typography: typography(), topics: [topic()], videos: .hidden)
    #expect(TrendingInterstitialLayoutCache.layout(for: input) == TrendingInterstitialLayoutEngine.layout(input))
    #expect(TrendingInterstitialLayoutCache.layout(for: input) == TrendingInterstitialLayoutCache.layout(for: input))
  }
}
#endif
