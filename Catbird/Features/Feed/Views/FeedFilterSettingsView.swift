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
                .appFont(AppTextRole.headline)
              Text(appState.feedFilterSettings.filters[index].description)
                .appFont(AppTextRole.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }

      Section(header: Text("About Filtering")) {
        Text("Filters are applied as posts load. Changes will affect newly loaded content.")
          .appFont(AppTextRole.caption)
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
