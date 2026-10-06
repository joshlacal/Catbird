import SwiftUI

enum TrendingTopicCategoryStyle {
  static func symbol(for category: String?) -> String {
    switch category?.lowercased() {
    case "pop-culture": return "music.note.tv"
    case "politics": return "building.columns"
    case "sports": return "figure.basketball"
    case "video-games": return "gamecontroller"
    case "tech", "technology": return "laptopcomputer"
    case "business": return "chart.bar"
    case "science": return "atom"
    case "news": return "newspaper"
    default: return "number"
    }
  }

  static func color(for category: String?) -> Color {
    switch category?.lowercased() {
    case "pop-culture": return .purple
    case "politics": return .blue
    case "sports": return .orange
    case "video-games": return .green
    case "tech", "technology": return .cyan
    case "business": return .yellow
    case "science": return .mint
    case "news": return .red
    default: return .gray
    }
  }

  static func name(for category: String) -> String {
    switch category.lowercased() {
    case "pop-culture": return "Entertainment"
    case "video-games": return "Video Games"
    default: return category.replacingOccurrences(of: "-", with: " ").capitalized
    }
  }
}

/// A decorative category mark occupies the same leading position as a post avatar.
struct TrendingTopicCategoryMark: View {
  let category: String?
  @ScaledMetric(relativeTo: .title3) private var iconSize: CGFloat = 25
  @ScaledMetric(relativeTo: .title3) private var diameter: CGFloat = 44

  var body: some View {
    Image(systemName: TrendingTopicCategoryStyle.symbol(for: category))
      .font(.system(size: min(iconSize, 36), weight: .semibold))
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
