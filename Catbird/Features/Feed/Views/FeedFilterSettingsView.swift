import SwiftUI

import SwiftUI

struct FeedFilterSettingsView: View {
  @Environment(AppState.self) private var appState
  
  var body: some View {
    List {
      Section(header: Text("Filter Settings")) {
        ForEach(appState.feedFilterSettings.filters.indices, id: \.self) { index in
          Toggle(
            isOn: Binding(
              get: { appState.feedFilterSettings.filters[index].isEnabled },
              set: { _ in appState.feedFilterSettings.toggleFilter(id: appState.feedFilterSettings.filters[index].id) }
            )
          ) {
            VStack(alignment: .leading, spacing: 4) {
              Text(appState.feedFilterSettings.filters[index].name)
                .font(.headline)
              Text(appState.feedFilterSettings.filters[index].description)
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
    FeedFilterSettingsView()
      .environment(AppState())
}
