import SwiftUI

struct FeedFilterSettingsView: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    List {
      Section(header: Text("Filter Settings")) {
        ForEach(appState.feedFilterSettings.filters) { filter in
          Toggle(
            isOn: Binding(
              get: { filter.isEnabled },
              set: { _ in appState.feedFilterSettings.toggleFilter(id: filter.id) }
            )
          ) {
            VStack(alignment: .leading, spacing: 4) {
              Text(filter.name)
                .font(.headline)
              Text(filter.description)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }

      Section(header: Text("About Filtering")) {
        Text("Filters are applied as posts load. Changes will affect newly loaded content.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Feed Filters")
  }
}

#Preview {
  NavigationStack {
    FeedFilterSettingsView()
      .environment(AppState())
  }
}
