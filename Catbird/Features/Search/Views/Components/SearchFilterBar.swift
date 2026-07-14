import SwiftUI

/// A contextual bar with sort pills and a filters chip, shown above search results.
struct SearchFilterBar: View {
  let sort: SearchSort
  let activeFilterCount: Int
  let onSortChange: (SearchSort) -> Void
  let onFiltersTap: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      ForEach(SearchSort.allCases, id: \.self) { option in
        sortPill(option)
      }

      Spacer(minLength: 8)
      filtersChip
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
  }

  private func sortPill(_ option: SearchSort) -> some View {
    let isSelected = option == sort
    return Button { onSortChange(option) } label: {
      HStack(spacing: 4) {
        Image(systemName: option.icon)
          .appFont(AppTextRole.caption)
        Text(option.displayName)
          .appFont(AppTextRole.subheadline)
          .fontWeight(isSelected ? .semibold : .regular)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
      .background(
        Capsule().fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
      )
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
