import SwiftUI

/// A contextual bar with active filter pills and a filters chip, shown above post search results (Top / Latest).
public struct SearchFilterBar: View {
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme

  public let activeFilterCount: Int
  public let summaryItems: [SearchFilterSummaryItem]
  public let onFiltersTap: () -> Void
  public let onResetFilters: (() -> Void)?

  public init(
    activeFilterCount: Int,
    summaryItems: [SearchFilterSummaryItem] = [],
    onFiltersTap: @escaping () -> Void,
    onResetFilters: (() -> Void)? = nil
  ) {
    self.activeFilterCount = activeFilterCount
    self.summaryItems = summaryItems
    self.onFiltersTap = onFiltersTap
    self.onResetFilters = onResetFilters
  }

  public init(
    filterState: SearchFilterState,
    onFiltersTap: @escaping () -> Void,
    onResetFilters: (() -> Void)? = nil
  ) {
    self.activeFilterCount = filterState.activeFilterCount
    self.summaryItems = filterState.summaryItems
    self.onFiltersTap = onFiltersTap
    self.onResetFilters = onResetFilters
  }

  public var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        filtersChip

        ForEach(summaryItems) { item in
          Button(action: onFiltersTap) {
            HStack(spacing: 4) {
              Image(systemName: item.icon)
                .appFont(AppTextRole.caption)
              Text(item.text)
                .appFont(AppTextRole.caption)
                .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(Color.accentColor)
            .background(
              Capsule().fill(Color.accentColor.opacity(0.12))
            )
          }
          .buttonStyle(.plain)
        }

        if activeFilterCount > 0, let onResetFilters {
          Button(action: onResetFilters) {
            Text("Clear")
              .appFont(AppTextRole.caption.weight(.medium))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Clear filters")
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }
    .background(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.dynamicBorder(appState.themeManager, currentScheme: colorScheme))
        .frame(height: 0.5)
    }
  }

  private var filtersChip: some View {
    Button(action: onFiltersTap) {
      HStack(spacing: 5) {
        Image(systemName: activeFilterCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
          .appFont(AppTextRole.subheadline)
        Text("Filters")
          .appFont(AppTextRole.subheadline.weight(.medium))
        if activeFilterCount > 0 {
          Text("\(activeFilterCount)")
            .appFont(AppTextRole.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .frame(minWidth: 16, minHeight: 16)
            .background(Circle().fill(Color.accentColor))
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .foregroundStyle(activeFilterCount > 0 ? Color.accentColor : Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))
      .background(
        Capsule().fill(
          activeFilterCount > 0
            ? Color.accentColor.opacity(0.15)
            : Color.elevatedBackground(appState.themeManager, elevation: .low, currentScheme: colorScheme)
        )
      )
      .overlay(
        Capsule()
          .stroke(
            activeFilterCount > 0
              ? Color.accentColor.opacity(0.3)
              : Color.dynamicBorder(appState.themeManager, currentScheme: colorScheme),
            lineWidth: 0.5
          )
      )
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("searchFiltersButton")
    .accessibilityLabel(activeFilterCount > 0 ? "Filters, \(activeFilterCount) active" : "Filters")
  }
}
