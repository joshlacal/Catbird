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
    locale: Locale = .current,
    onFiltersTap: @escaping () -> Void,
    onResetFilters: (() -> Void)? = nil
  ) {
    self.activeFilterCount = filterState.activeFilterCount
    self.summaryItems = filterState.summaryItems(locale: locale)
    self.onFiltersTap = onFiltersTap
    self.onResetFilters = onResetFilters
  }

  public var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        filtersChip

        ForEach(summaryItems) { item in
          CatbirdChip(
            title: Text(item.text), systemImage: item.icon, size: .md, action: onFiltersTap)
        }

        if activeFilterCount > 0, let onResetFilters {
          Button(action: onResetFilters) {
            Text("Clear", comment: "Button to clear all active search filters")
              .appFont(AppTextRole.caption.weight(.medium))
          }
          .buttonStyle(.catbird(.quiet, size: .sm))
          .accessibilityLabel(Text("Clear filters", comment: "Accessibility label for button to reset search filters"))
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
        Text("Filters", comment: "Button chip to open post search filters")
          .appFont(AppTextRole.subheadline.weight(.medium))
        if activeFilterCount > 0 {
          Text(activeFilterCount, format: .number)
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
        Capsule(style: .continuous).fill(
          activeFilterCount > 0
            ? Color.accentColor.opacity(0.15)
            : Color.elevatedBackground(appState.themeManager, elevation: .low, currentScheme: colorScheme)
        )
      )
      .overlay(
        Capsule(style: .continuous)
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
    .accessibilityLabel(
      activeFilterCount > 0
        ? Text("Filters, \(activeFilterCount) active", comment: "Accessibility label for search filters button showing number of active filters")
        : Text("Filters", comment: "Accessibility label for search filters button")
    )
  }
}
