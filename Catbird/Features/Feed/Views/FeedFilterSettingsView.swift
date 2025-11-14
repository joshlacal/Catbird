import SwiftUI

struct FeedFilterSettingsView: View {
  @Environment(AppState.self) private var appState
  @State private var feedViewPref: FeedViewPreference?
  @State private var isLoading = true
  @State private var isSaving = false
  
  var body: some View {
    List {
      
      // Sort section removed - only "Latest" is supported, no need to show picker
      // Section(header: Text("Sort")) {
      //   Picker("Feed Order", selection: Binding(
      //     get: { appState.feedFilterSettings.sortMode },
      //     set: { newValue in
      //       appState.feedFilterSettings.sortMode = newValue
      //     }
      //   )) {
      //     ForEach(FeedFilterSettings.FeedSortMode.allCases) { mode in
      //       Text(mode == .latest ? "Latest" : "Relevant")
      //         .tag(mode)
      //     }
      //   }
      //   .pickerStyle(.segmented)
      // }
      
      // Server-synced feed preferences
      Section(header: Text("Feed Preferences"), footer: Text("This setting syncs across your devices.")) {
        if isLoading {
          HStack {
            Spacer()
            ProgressView()
            Spacer()
          }
        } else {
          Toggle(
            isOn: Binding(
              get: { feedViewPref?.hideRepliesByUnfollowed ?? false },
              set: { newValue in
                Task {
                  await updateHideRepliesByUnfollowed(newValue)
                }
              }
            )
          ) {
            VStack(alignment: .leading, spacing: 4) {
              Text("Hide Replies from Not Followed")
                .appFont(AppTextRole.headline)
              Text("Hide replies where you don't follow the original poster")
                .appFont(AppTextRole.caption)
                .foregroundStyle(.secondary)
            }
          }
          .disabled(isSaving)
        }
      }
      
      Section(header: Text("Quick Filters"), footer: Text("These filters apply locally and do not sync.")) {
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
    .task {
      await loadPreferences()
    }
  }
  
  // MARK: - Helper Methods
  
  @MainActor
  private func loadPreferences() async {
    isLoading = true
    defer { isLoading = false }
    
    do {
      let preferences = try await appState.preferencesManager.getPreferences()
      feedViewPref = preferences.feedViewPref ?? FeedViewPreference(
        hideReplies: nil,
        hideRepliesByUnfollowed: nil,
        hideRepliesByLikeCount: nil,
        hideReposts: nil,
        hideQuotePosts: nil
      )
    } catch {
      // If we can't load preferences, use default
      feedViewPref = FeedViewPreference(
        hideReplies: nil,
        hideRepliesByUnfollowed: nil,
        hideRepliesByLikeCount: nil,
        hideReposts: nil,
        hideQuotePosts: nil
      )
    }
  }
  
  @MainActor
  private func updateHideRepliesByUnfollowed(_ newValue: Bool) async {
    isSaving = true
    defer { isSaving = false }
    
    do {
      // Update the preference on the server
      try await appState.preferencesManager.setFeedViewPreferences(
        hideRepliesByUnfollowed: newValue
      )
      
      // Update local state
      feedViewPref = FeedViewPreference(
        hideReplies: feedViewPref?.hideReplies,
        hideRepliesByUnfollowed: newValue,
        hideRepliesByLikeCount: feedViewPref?.hideRepliesByLikeCount,
        hideReposts: feedViewPref?.hideReposts,
        hideQuotePosts: feedViewPref?.hideQuotePosts
      )
      
      // Notify that preferences have changed to trigger feed refresh
      NotificationCenter.default.post(
        name: NSNotification.Name("FeedPreferencesChanged"),
        object: nil
      )
    } catch {
      // If save fails, revert the toggle
      // The binding will update automatically when feedViewPref is set back
      print("Failed to update feed preference: \(error)")
    }
  }
}

#Preview {
    @Previewable @Environment(AppState.self) var appState
    FeedFilterSettingsView()
      .environment(AppStateManager.shared)
}
