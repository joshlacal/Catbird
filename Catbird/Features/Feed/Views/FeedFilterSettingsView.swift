import SwiftUI

struct FeedFilterSettingsView: View {
  @Environment(AppState.self) private var appState
  
  var body: some View {
    List {
      
      Section {
        NavigationLink("Account Feed Filters") {
          ContentMediaSettingsView()
        }
      } footer: {
        Text("Manage filters that sync with Bluesky in Content & Media.")
      }

      Section(header: Text("Quick Filters"), footer: Text("These filters apply locally and do not sync.")) {
        ForEach(appState.feedFilterSettings.filters, id: \.id) { filter in
          Toggle(
            isOn: Binding(
              get: {
                appState.feedFilterSettings.filters.first(where: { $0.id == filter.id })?.isEnabled ?? false
              },
              set: { _ in appState.feedFilterSettings.toggleFilter(id: filter.id) }
            )
          ) {
            VStack(alignment: .leading, spacing: 4) {
              Text(filter.name)
                .appFont(AppTextRole.headline)
              Text(filter.description)
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
  AsyncPreviewContent { appState in
    FeedFilterSettingsView()
      .environment(AppStateManager.shared)
  }
}
