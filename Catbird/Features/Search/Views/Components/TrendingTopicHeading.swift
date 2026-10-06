import SwiftUI

enum TrendingTopicCategoryStyle {
  private struct Style {
    let symbol: String
    let color: Color
    let name: String?
  }

  /// One distinct symbol and color per getTrends category, including legacy and alias values.
  private static func style(for category: String?) -> Style {
    switch category?.lowercased() {
    case "culture": return Style(symbol: "theatermasks", color: .pink, name: nil)
    case "entertainment", "pop-culture": return Style(symbol: "popcorn", color: .purple, name: "Entertainment")
    case "politics": return Style(symbol: "building.columns", color: .blue, name: nil)
    case "news", "world": return Style(symbol: "newspaper", color: .red, name: nil)
    case "sports": return Style(symbol: "figure.basketball", color: .orange, name: nil)
    case "video-games", "gaming": return Style(symbol: "gamecontroller", color: .green, name: "Video Games")
    case "science-tech": return Style(symbol: "atom", color: .teal, name: "Science & Tech")
    case "science": return Style(symbol: "atom", color: .mint, name: nil)
    case "tech", "technology": return Style(symbol: "cpu", color: .cyan, name: "Tech")
    case "business", "economy", "finance": return Style(symbol: "chart.line.uptrend.xyaxis", color: .yellow, name: nil)
    case "health": return Style(symbol: "cross.case", color: .red, name: nil)
    case "music": return Style(symbol: "music.note", color: .indigo, name: nil)
    case "weather": return Style(symbol: "cloud.sun", color: .cyan, name: nil)
    case "other": return Style(symbol: "sparkles", color: .brown, name: "Trending")
    default: return Style(symbol: "number", color: .gray, name: nil)
    }
  }

  static func symbol(for category: String?) -> String { style(for: category).symbol }

  static func color(for category: String?) -> Color { style(for: category).color }

  static func name(for category: String) -> String {
    style(for: category).name ?? category.replacingOccurrences(of: "-", with: " ").capitalized
  }
}

/// A decorative category mark occupies the same leading position as a post avatar.
struct TrendingTopicCategoryMark: View {
  let category: String?
  private let scaledIconSize: ScaledMetric<CGFloat>
  private let scaledDiameter: ScaledMetric<CGFloat>
  private var iconSize: CGFloat { scaledIconSize.wrappedValue }
  private var diameter: CGFloat { scaledDiameter.wrappedValue }

  /// `diameter` is the default-text-size width; the symbol fills half of it, leaving a generous ring.
  init(category: String?, diameter: CGFloat = 44) {
    self.category = category
    scaledDiameter = ScaledMetric(wrappedValue: diameter, relativeTo: .title3)
    scaledIconSize = ScaledMetric(wrappedValue: diameter * 0.5, relativeTo: .title3)
  }

  var body: some View {
    Image(systemName: TrendingTopicCategoryStyle.symbol(for: category))
      .font(.system(size: min(iconSize, min(diameter, 60) * 0.5), weight: .semibold))
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(TrendingTopicCategoryStyle.color(for: category))
      .frame(width: min(diameter, 60), height: min(diameter, 60))
      .background(TrendingTopicCategoryStyle.color(for: category).opacity(0.12), in: Circle())
      .accessibilityHidden(true)
  }
}

struct TrendingTopicHeading: View {
  let title: String
  let category: String?
  var size: CGFloat = 22
  var titleLineLimit: Int?
  /// Search rows put media in the leading slot, so their heading omits the category mark.
  var showsMark = true

  var body: some View {
    HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
      if showsMark {
        TrendingTopicCategoryMark(category: category)
      }
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        if let category {
          Text(TrendingTopicCategoryStyle.name(for: category))
            .appFont(AppTextRole.caption.weight(.medium))
            .foregroundStyle(TrendingTopicCategoryStyle.color(for: category))
            .lineLimit(1)
        }
        TrendingTopicTitle(title: title, size: size, lineLimit: titleLineLimit)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
