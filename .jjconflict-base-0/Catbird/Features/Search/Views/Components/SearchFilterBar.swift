import SwiftUI

/// A contextual bar with a filters chip, shown above post search results (Top / Latest).
public struct SearchFilterBar: View {
  public let activeFilterCount: Int
  public let onFiltersTap: () -> Void

  public init(
    activeFilterCount: Int,
    onFiltersTap: @escaping () -> Void
  ) {
    self.activeFilterCount = activeFilterCount
    self.onFiltersTap = onFiltersTap
  }

  public var body: some View {
    HStack(spacing: 8) {
      Spacer()
      filtersChip
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
  }

  private var filtersChip: some View {
    Button(action: onFiltersTap) {
      HStack(spacing: 4) {
        Image(systemName: "line.3.horizontal.decrease.circle")
          .appFont(AppTextRole.subheadline)
        Text("Filters")
          .appFont(AppTextRole.subheadline)
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
      .foregroundStyle(activeFilterCount > 0 ? Color.accentColor : Color.secondary)
      .background(
        Capsule().fill(activeFilterCount > 0 ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(activeFilterCount > 0 ? "Filters, \(activeFilterCount) active" : "Filters")
  }
}
