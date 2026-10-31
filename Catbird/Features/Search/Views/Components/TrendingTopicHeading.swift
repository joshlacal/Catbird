import SwiftUI
#if os(iOS)
import UIKit
#endif

enum TrendingTopicCategoryStyle {
  /// System tints shared by the SwiftUI and UIKit renderings of a category.
  enum Tint {
    case pink, purple, blue, red, orange, green, teal, mint, cyan, yellow, indigo, brown, gray

    var color: Color {
      switch self {
      case .pink: .pink
      case .purple: .purple
      case .blue: .blue
      case .red: .red
      case .orange: .orange
      case .green: .green
      case .teal: .teal
      case .mint: .mint
      case .cyan: .cyan
      case .yellow: .yellow
      case .indigo: .indigo
      case .brown: .brown
      case .gray: .gray
      }
    }

    #if os(iOS)
    var uiColor: UIColor {
      switch self {
      case .pink: .systemPink
      case .purple: .systemPurple
      case .blue: .systemBlue
      case .red: .systemRed
      case .orange: .systemOrange
      case .green: .systemGreen
      case .teal: .systemTeal
      case .mint: .systemMint
      case .cyan: .systemCyan
      case .yellow: .systemYellow
      case .indigo: .systemIndigo
      case .brown: .systemBrown
      case .gray: .systemGray
      }
    }
    #endif
  }

  private struct Style {
    let symbol: String
    let tint: Tint
    let name: String?
  }

  /// One distinct symbol and color per getTrends category, including legacy and alias values.
  private static func style(for category: String?) -> Style {
    switch category?.lowercased() {
    case "culture": return Style(symbol: "theatermasks", tint: .pink, name: nil)
    case "entertainment", "pop-culture": return Style(symbol: "popcorn", tint: .purple, name: "Entertainment")
    case "politics": return Style(symbol: "building.columns", tint: .blue, name: nil)
    case "news", "world": return Style(symbol: "newspaper", tint: .red, name: nil)
    case "sports": return Style(symbol: "figure.basketball", tint: .orange, name: nil)
    case "video-games", "gaming": return Style(symbol: "gamecontroller", tint: .green, name: "Video Games")
    case "science-tech": return Style(symbol: "atom", tint: .teal, name: "Science & Tech")
    case "science": return Style(symbol: "atom", tint: .mint, name: nil)
    case "tech", "technology": return Style(symbol: "cpu", tint: .cyan, name: "Tech")
    case "business", "economy", "finance": return Style(symbol: "chart.line.uptrend.xyaxis", tint: .yellow, name: nil)
    case "health": return Style(symbol: "cross.case", tint: .red, name: nil)
    case "music": return Style(symbol: "music.note", tint: .indigo, name: nil)
    case "weather": return Style(symbol: "cloud.sun", tint: .cyan, name: nil)
    case "other": return Style(symbol: "sparkles", tint: .brown, name: "Trending")
    default: return Style(symbol: "number", tint: .gray, name: nil)
    }
  }

  static func symbol(for category: String?) -> String { style(for: category).symbol }

  static func tint(for category: String?) -> Tint { style(for: category).tint }

  static func color(for category: String?) -> Color { style(for: category).tint.color }

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
