import SwiftUI

struct FeedHeaderView: View {
  @Environment(AppState.self) private var appState
  let title: String

  init(title: String) {
    self.title = title
  }

  var body: some View {
    HStack {
      Text(title)
        .font(.headline)
        .lineLimit(1)

      Spacer()

      NavigationLink {
        FeedFilterSettingsView()
      } label: {
        FilterButton(activeFilterCount: appState.feedFilterSettings.activeFilterIds.count)
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
  }
}

// Extract filter button to a separate view for better organization
private struct FilterButton: View {
  let activeFilterCount: Int

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "line.3.horizontal.decrease.circle")
        .symbolEffect(.bounce, value: activeFilterCount)

      if activeFilterCount > 0 {
        Text("\(activeFilterCount)")
          .font(.caption)
          .padding(4)
          .background(Circle().fill(Color.accentColor))
          .foregroundColor(.white)
      }
    }
    .foregroundColor(activeFilterCount > 0 ? .accentColor : .secondary)
  }
}
