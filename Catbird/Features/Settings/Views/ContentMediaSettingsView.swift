import SwiftUI
import Petrel

struct ContentMediaSettingsView: View {
  @Environment(AppState.self) private var appState

  // Local state for thread preferences (server-synced)
  @State private var isLoadingAccountPreferences = true
  @State private var hasLoadedAccountPreferences = false
  @State private var isSavingServerPreferences = false
  @State private var threadSortOrder: String = "hot"

  // Feed preferences (server-synced)
  @State private var hideReplies: Bool = false
  @State private var hideRepliesByUnfollowed: Bool = false
  @State private var hideRepliesByLikeCount: Int?
  @State private var hideReposts: Bool = false
  @State private var hideQuotePosts: Bool = false

  private enum PendingPreferenceSave { case feed, thread }
  @State private var pendingPreferenceSave: PendingPreferenceSave?
  @State private var errorMessage: String?

  // Interests (server-synced)
  @State private var userInterestsCount: Int = 0

  var body: some View {
    Form {
      SettingsPersistenceStatusSection(settings: appState.appSettings)

      // Media Playback Settings
      Section {
        Toggle("Autoplay Videos", isOn: Binding(
          get: { appState.appSettings.autoplayVideos },
          set: { appState.appSettings.autoplayVideos = $0 }
        ))
        .tint(.blue)

        Toggle("Open Links In-App", isOn: Binding(
          get: { appState.appSettings.useInAppBrowser },
          set: { appState.appSettings.useInAppBrowser = $0 }
        ))
        .tint(.blue)
      } header: {
        Text("Playback & Links")
      } footer: {
        Text("Videos can play automatically in feeds. Animated GIFs always play automatically.")
      }
      .disabled(!appState.appSettings.canEditPersistedSettings)

      // Feed Content Settings
      Section {
        Toggle("Show Trending Topics", isOn: Binding(
          get: { appState.appSettings.showTrendingTopics },
          set: { appState.appSettings.showTrendingTopics = $0 }
        ))
        .tint(.blue)
        .disabled(!appState.appSettings.canEditPersistedSettings)

        Toggle("Show Trending Videos", isOn: Binding(
          get: { appState.appSettings.showTrendingVideos },
          set: { appState.appSettings.showTrendingVideos = $0 }
        ))
        .tint(.blue)
        .disabled(!appState.appSettings.canEditPersistedSettings)

        NavigationLink {
          InterestsSettingsView()
        } label: {
          HStack {
            Text("Your Interests")
            Spacer()
            if isLoadingAccountPreferences {
              ProgressView()
                .controlSize(.small)
            } else if hasLoadedAccountPreferences {
              Text(userInterestsCount > 0 ? "\(userInterestsCount) selected" : "None")
                .foregroundStyle(.secondary)
            }
          }
        }
      } header: {
        Text("Discovery")
      } footer: {
        Text("Trending topics and videos are shown in feeds and Search for this account. Your interests sync with Bluesky.")
      }

      if !hasLoadedAccountPreferences {
        Section("Bluesky Preferences") {
          if isLoadingAccountPreferences {
            ProgressView("Loading account preferences…")
          } else {
            Text("Account preferences are unavailable. Reload them before making another change.")
              .foregroundStyle(.secondary)
            Button("Retry Loading Preferences") {
              Task { await loadAccountPreferences() }
            }
          }
        }
      }

      // Account preferences are editable only after a successful load.
      if hasLoadedAccountPreferences {
        Section {
          Toggle("Hide All Replies", isOn: feedBinding($hideReplies))

          if hideReplies {
            Text("Hides all reply posts from your feed, except your own replies")
              .font(.caption)
              .foregroundColor(.secondary)
              .padding(.leading, 16)
          }

          Toggle("Hide Replies to Users You Don't Follow", isOn: feedBinding($hideRepliesByUnfollowed))
            .disabled(hideReplies) // Disabled if hideReplies is on

          if !hideReplies && hideRepliesByUnfollowed {
            Text("Hides replies to posts from people you don't follow")
              .font(.caption)
              .foregroundColor(.secondary)
              .padding(.leading, 16)
          }

          // Hide replies by like count
          VStack(alignment: .leading, spacing: 8) {
            Toggle("Hide Replies Below Minimum Likes", isOn: Binding(
              get: { hideRepliesByLikeCount != nil },
              set: { enabled in
                guard !isSavingServerPreferences, pendingPreferenceSave == nil else { return }
                hideRepliesByLikeCount = enabled ? 2 : nil
                updateFeedViewPreference()
              }
            ))
            .disabled(hideReplies)

            if !hideReplies && hideRepliesByLikeCount != nil {
              HStack {
                Text("Minimum likes:")
                  .font(.caption)
                  .foregroundColor(.secondary)

                Spacer()

                Stepper(value: Binding(
                  get: { hideRepliesByLikeCount ?? 2 },
                  set: { newValue in
                    guard !isSavingServerPreferences, pendingPreferenceSave == nil else { return }
                    hideRepliesByLikeCount = max(0, newValue)
                    updateFeedViewPreference()
                  }
                ), in: 0...100) {
                  Text("\(hideRepliesByLikeCount ?? 2)")
                    .font(.caption)
                    .monospacedDigit()
                }
              }
              .padding(.leading, 16)
            }
          }

          Toggle("Hide Reposts", isOn: feedBinding($hideReposts))

          Toggle("Hide Quote Posts", isOn: feedBinding($hideQuotePosts))
        } header: {
          Text("Feed Filtering · Syncs with Bluesky")
        } footer: {
          if hasLoadedAccountPreferences {
            Text("These choices apply to Catbird feeds and sync with your Bluesky account’s Following feed preferences.")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
        .disabled(isSavingServerPreferences || pendingPreferenceSave != nil)
      }

      // Language Filtering
      Section("Language Filtering") {
        Toggle("Hide posts in non-preferred languages", isOn: Binding(
          get: { appState.appSettings.hideNonPreferredLanguages },
          set: { appState.appSettings.hideNonPreferredLanguages = $0 }
        ))
        .tint(.blue)
        .disabled(!appState.appSettings.canEditPersistedSettings)

        Toggle("Show language indicators on posts", isOn: Binding(
          get: { appState.appSettings.showLanguageIndicators },
          set: { appState.appSettings.showLanguageIndicators = $0 }
        ))
        .tint(.blue)
        .disabled(!appState.appSettings.canEditPersistedSettings)

        NavigationLink("Manage Languages") {
          LanguageSettingsView()
        }
      }

      // Thread sort is server-synced; layout choices remain local.
      if hasLoadedAccountPreferences {
        Section {
          Picker("Thread Sort Order", selection: threadBinding(Binding(
            get: { threadSortOrder == "hot" ? "top" : threadSortOrder },
            set: { threadSortOrder = $0 }
          ))) {
            Text("Top").tag("top")
            Text("Latest").tag("newest")
            Text("Oldest").tag("oldest")
          }

        } header: {
          Text("Thread Order · Syncs with Bluesky")
        }
        .disabled(isSavingServerPreferences || pendingPreferenceSave != nil)
      }

      Section {
        Toggle("Threaded Replies View", isOn: Binding(
          get: { appState.appSettings.threadedReplies },
          set: { appState.appSettings.threadedReplies = $0 }
        ))
        .tint(.blue)

        Toggle("Auto-Load Hidden Replies", isOn: Binding(
          get: { appState.appSettings.showHiddenPosts },
          set: { appState.appSettings.showHiddenPosts = $0 }
        ))
        .tint(.blue)
      } header: {
        Text("Thread Display · On This Device")
      } footer: {
        Text("When enabled, replies hidden by threadgates are loaded automatically. Otherwise, a \"Show More Replies\" button will appear when hidden replies are available.")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      .disabled(!appState.appSettings.canEditPersistedSettings)

      // External Media Embeds
      Section {
        Toggle("Enable Embedded Players", isOn: Binding(
          get: { appState.appSettings.useWebViewEmbeds },
          set: { appState.appSettings.useWebViewEmbeds = $0 }
        ))
        .tint(.blue)
        .disabled(!appState.appSettings.canEditPersistedSettings)

        NavigationLink(destination: ExternalMediaPreferencesView()) {
          HStack {
            Text("External Media Preferences")
            Spacer()
          }
        }
      } header: {
        Text("External Media Embeds")
      } footer: {
        Text("Control player permissions and consent for third-party media embeds such as YouTube, Spotify, and Bandcamp.")
          .appFont(AppTextRole.footnote)
          .foregroundStyle(.secondary)
      }

      if isSavingServerPreferences {
        Section { ProgressView("Saving account preferences…") }
      }

      if let error = errorMessage {
        Section {
          Text(error)
            .foregroundStyle(.red)
            .appFont(AppTextRole.callout)
          if let pendingPreferenceSave {
            Text("This change hasn’t been confirmed by Bluesky. Retry to sync your selected preference.")
              .foregroundStyle(.secondary)
            Button("Retry Saving Preferences") {
              switch pendingPreferenceSave {
              case .feed: updateFeedViewPreference()
              case .thread: updateThreadViewPreference()
              }
            }
            .disabled(isSavingServerPreferences)
          }
        }
      }

    }
    .navigationTitle("Content & Media")
    #if os(iOS)
      .toolbarTitleDisplayMode(.inline)
    #endif
      .task {
        await loadAccountPreferences()
      }
  }

  private func feedBinding<Value>(_ binding: Binding<Value>) -> Binding<Value> {
    Binding(get: { binding.wrappedValue }, set: { newValue in
      guard hasLoadedAccountPreferences, !isSavingServerPreferences, pendingPreferenceSave == nil else { return }
      binding.wrappedValue = newValue
      updateFeedViewPreference()
    })
  }

  private func threadBinding<Value>(_ binding: Binding<Value>) -> Binding<Value> {
    Binding(get: { binding.wrappedValue }, set: { newValue in
      guard hasLoadedAccountPreferences, !isSavingServerPreferences, pendingPreferenceSave == nil else { return }
      binding.wrappedValue = newValue
      updateThreadViewPreference()
    })
  }

  private func loadAccountPreferences() async {
    // A return from a child page must not replace an unacknowledged edit with fetched state.
    guard pendingPreferenceSave == nil, !isSavingServerPreferences else { return }
    isLoadingAccountPreferences = true
    errorMessage = nil
    defer { isLoadingAccountPreferences = false }

    do {
      guard appState.isAuthenticated, appState.atProtoClient != nil else {
        throw PreferencesManagerError.clientNotInitialized
      }
      let preferences = try await appState.preferencesManager.refreshSettingsPreferences()

      threadSortOrder = preferences.threadViewPref?.sort ?? "hot"
      hideReplies = preferences.feedViewPref?.hideReplies ?? false
      hideRepliesByUnfollowed = preferences.feedViewPref?.hideRepliesByUnfollowed ?? false
      hideRepliesByLikeCount = preferences.feedViewPref?.hideRepliesByLikeCount
      hideReposts = preferences.feedViewPref?.hideReposts ?? false
      hideQuotePosts = preferences.feedViewPref?.hideQuotePosts ?? false

      // Update app settings to ensure consistency
      appState.appSettings.threadSortOrder = threadSortOrder

      userInterestsCount = preferences.interests.count
      hasLoadedAccountPreferences = true
    } catch {
      errorMessage = "Failed to load preferences: \(error.localizedDescription)"
    }

  }

  private func updateThreadViewPreference() {
    guard hasLoadedAccountPreferences, !isSavingServerPreferences else { return }
    let sort = threadSortOrder
    isSavingServerPreferences = true
    pendingPreferenceSave = .thread
    Task {
      defer { isSavingServerPreferences = false }
      do {
        try await appState.preferencesManager.setThreadViewPreferences(
          sort: sort
        )
        appState.appSettings.threadSortOrder = sort
        pendingPreferenceSave = nil
        errorMessage = nil
      } catch {
        errorMessage = "Failed to update thread preferences: \(error.localizedDescription)"
      }
    }
  }

  private func updateFeedViewPreference() {
    guard hasLoadedAccountPreferences, !isSavingServerPreferences else { return }
    let replies = hideReplies
    let unfollowed = hideRepliesByUnfollowed
    let minimumLikes = hideRepliesByLikeCount
    let reposts = hideReposts
    let quotes = hideQuotePosts
    isSavingServerPreferences = true
    pendingPreferenceSave = .feed
    Task {
      defer { isSavingServerPreferences = false }
      do {
        try await appState.preferencesManager.setFeedViewPreferences(
          hideReplies: replies,
          hideRepliesByUnfollowed: unfollowed,
          hideRepliesByLikeCount: minimumLikes,
          hideReposts: reposts,
          hideQuotePosts: quotes,
          clearReplyLikeThreshold: minimumLikes == nil
        )

        pendingPreferenceSave = nil
        errorMessage = nil
        // Notify that preferences have changed to trigger feed refresh
        NotificationCenter.default.post(
          name: NSNotification.Name("FeedPreferencesChanged"),
          object: nil
        )
      } catch {
        errorMessage = "Failed to update feed preferences: \(error.localizedDescription)"
      }
    }
  }

}

// MARK: - Preview

#Preview {
  AsyncPreviewContent { appState in
    NavigationStack {
      ContentMediaSettingsView()
    }
  }
}
