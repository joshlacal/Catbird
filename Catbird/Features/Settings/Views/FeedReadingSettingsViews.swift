import SwiftUI

struct FeedsDiscoverySettingsView: View {
  var initialFocus: SettingsControlID? = nil
  var body: some View {
    SettingsFocusedForm(initialFocus: initialFocus) {
      SettingsScopeSection()
      Section {
        NavigationLink { FeedFilterSettingsView() } label: {
          SettingsNavigationRow(title: "Feed Filtering", summary: "Replies, reposts, quotes, post types and links", systemImage: "line.3.horizontal.decrease", family: .feeds)
        }
        NavigationLink { ThreadSettingsView() } label: {
          SettingsNavigationRow(title: "Threads", summary: "Reply order, layout and author-hidden replies", systemImage: "text.bubble", family: .feeds)
        }
        NavigationLink { DiscoverySettingsView() } label: {
          SettingsNavigationRow(title: "Discovery", summary: "Trending topics, videos and interests", systemImage: "sparkle.magnifyingglass", family: .feeds)
        }
        NavigationLink { FeedLibrarySettingsView() } label: {
          SettingsNavigationRow(title: "Feed Library", summary: "Saved and pinned feeds, order and default feed", systemImage: "rectangle.stack", family: .feeds)
        }.settingsControl(.init(rawValue: "feed.feedLibrary"))
        NavigationLink { VerificationSettingsView() } label: {
          SettingsNavigationRow(title: "Verification Badges", summary: "Badge visibility across the app", systemImage: "checkmark.seal", family: .feeds)
        }.settingsControl(.init(rawValue: "feed.verification"))
      }
    }
    .navigationTitle("Feeds & Discovery")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
  }
}

struct MediaLinksSettingsView: View {
  @Environment(AppState.self) private var appState
  var initialFocus: SettingsControlID? = nil
  var body: some View {
    SettingsFocusedForm(initialFocus: initialFocus) {
      SettingsScopeSection(scope: "Current account on this device")
      SettingsPersistenceStatusSection(settings: appState.appSettings)
      Section {
        Toggle("Autoplay Videos", isOn: Binding(
          get: { appState.appSettings.autoplayVideos }, set: { appState.appSettings.autoplayVideos = $0 }
        )).settingsControl(.init(rawValue: "media.autoplayVideos"))
      } header: { Text("Playback") } footer: {
        Text("Videos can play automatically in feeds.")
      }.disabled(!appState.appSettings.canEditPersistedSettings)
      Section {
        Toggle("Open Links In-App", isOn: Binding(
          get: { appState.appSettings.useInAppBrowser }, set: { appState.appSettings.useInAppBrowser = $0 }
        )).settingsControl(.init(rawValue: "media.openLinks"))
      } header: { Text("Links") } footer: {
        Text("Turn this off to open links with your system browser.")
      }.disabled(!appState.appSettings.canEditPersistedSettings)
      Section {
        Toggle("Enable Embedded Players", isOn: Binding(
          get: { appState.appSettings.useWebViewEmbeds }, set: { appState.appSettings.useWebViewEmbeds = $0 }
        )).settingsControl(.init(rawValue: "media.embeddedPlayers"))
          .disabled(!appState.appSettings.canEditPersistedSettings)
        NavigationLink { ExternalMediaPreferencesView() } label: {
          SettingsNavigationRow(title: "External Media Permissions", summary: "Ask, allow or block each provider", systemImage: "hand.raised", family: .media)
        }.settingsControl(.init(rawValue: "media.providerPermissions"))
      } header: { Text("External Media") } footer: {
        Text("Embedded players connect to third-party providers. Provider permissions are separate from video autoplay.")
      }
    }
    .navigationTitle("Media & Links")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
  }
}

struct DiscoverySettingsView: View {
  @Environment(AppState.self) private var appState
  var initialFocus: SettingsControlID? = nil
  var body: some View {
    SettingsFocusedForm(initialFocus: initialFocus) {
      SettingsScopeSection()
      SettingsPersistenceStatusSection(settings: appState.appSettings)
      Section {
        Toggle("Show Trending Topics", isOn: Binding(
          get: { appState.appSettings.showTrendingTopics }, set: { appState.appSettings.showTrendingTopics = $0 }
        )).settingsControl(.init(rawValue: "feed.trendingTopics"))
        Toggle("Show Trending Videos", isOn: Binding(
          get: { appState.appSettings.showTrendingVideos }, set: { appState.appSettings.showTrendingVideos = $0 }
        )).settingsControl(.init(rawValue: "feed.trendingVideos"))
      } header: { Text("Discovery Surfaces") } footer: {
        Text("These choices control trending topics and videos for this account in feeds and Search.")
      }.disabled(!appState.appSettings.canEditPersistedSettings)
      Section {
        NavigationLink { InterestsSettingsView() } label: {
          SettingsNavigationRow(title: "Your Interests", summary: "Topics that help personalize discovery", systemImage: "heart.text.square", family: .feeds)
        }.settingsControl(.init(rawValue: "feed.interests"))
      } footer: { Text("Interests sync with Bluesky. Opening this page doesn’t change them.") }
    }
    .navigationTitle("Discovery")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
  }
}

struct ThreadSettingsView: View {
  @Environment(AppState.self) private var appState
  var initialFocus: SettingsControlID? = nil
  @State private var sort = "top"
  @State private var pendingSort: String?
  @State private var isLoading = true
  @State private var hasLoaded = false
  @State private var isSaving = false
  @State private var error: String?
  @State private var editorContext: SettingsFeedRefreshContext?

  var body: some View {
    SettingsFocusedForm(initialFocus: initialFocus, isReady: !isLoading) {
      SettingsScopeSection()
      SettingsPersistenceStatusSection(settings: appState.appSettings)
      Section {
        if hasLoaded {
          Picker("Reply Order", selection: Binding(
            get: { sort },
            set: { value in pendingSort = value; saveSort() }
          )) {
            Text("Top").tag("top")
            Text("Latest").tag("newest")
            Text("Oldest").tag("oldest")
          }.disabled(isSaving || pendingSort != nil)
            .settingsControl(.init(rawValue: "feed.threadSort"))
        } else if isLoading { ProgressView("Loading Bluesky preferences…") }
        else { Button("Retry Loading") { Task { await loadSort() } } }
      } header: { Text("Reply Order · Syncs with Bluesky") }
      Section {
        Toggle("Threaded Reply Layout", isOn: Binding(
          get: { appState.appSettings.threadedReplies }, set: { appState.appSettings.threadedReplies = $0 }
        )).settingsControl(.init(rawValue: "feed.threadLayout"))
        Toggle("Load Author-Hidden Replies Automatically", isOn: Binding(
          get: { appState.appSettings.showHiddenPosts }, set: { appState.appSettings.showHiddenPosts = $0 }
        )).settingsControl(.init(rawValue: "feed.hiddenReplies"))
      } header: { Text("Display · On This Device") } footer: {
        Text("Author-hidden replies are replies the thread’s author chose to hide. When automatic loading is off, Show More Replies remains available. This doesn’t change muted words or moderation rules.")
      }.disabled(!appState.appSettings.canEditPersistedSettings)
      if isSaving { Section { ProgressView("Saving reply order…") } }
      if let error {
        Section {
          Text(error).foregroundStyle(.red)
          if let pendingSort {
            Text("Selected order: \(sortLabel(pendingSort)). It hasn’t been confirmed by Bluesky.").foregroundStyle(.secondary)
            Button("Retry Saving") { saveSort() }.disabled(isSaving)
            Button("Discard Attempt", role: .cancel) { self.pendingSort = nil; self.error = nil }.disabled(isSaving)
          }
        }
      }
    }
    .navigationTitle("Threads")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .task(id: appState.userDID) { await loadSort() }
  }

  private func loadSort() async {
    guard !isSaving, pendingSort == nil else { return }
    let context = SettingsFeedRefreshContext(accountDID: appState.userDID,
      accountRevision: AppStateManager.shared.settingsAccountContextRevision,
      clientIdentity: appState.atProtoClient.map(ObjectIdentifier.init))
    guard isCurrent(context) else { return }
    editorContext = context
    isLoading = true
    hasLoaded = false
    defer { isLoading = false }
    do {
      let preferences = try await appState.preferencesManager.refreshSettingsPreferences()
      guard !Task.isCancelled, isCurrent(context) else { return }
      // Match the official app: anything other than oldest or newest (hotness, most-likes, random) reads as Top.
      let raw = preferences.threadViewPref?.sort ?? "top"
      sort = (raw == "oldest" || raw == "newest") ? raw : "top"
      hasLoaded = true
      error = nil
    } catch {
      guard !Task.isCancelled, isCurrent(context) else { return }
      self.error = UserFacingError.message(for: error, action: "load reply order") ?? "Couldn’t load reply order. Try again."
    }
  }

  private func saveSort() {
    guard hasLoaded, !isSaving, let pendingSort, let context = editorContext, isCurrent(context) else { return }
    isSaving = true
    Task { @MainActor in
      defer { isSaving = false }
      do {
        try await appState.preferencesManager.setThreadViewPreferences(sort: pendingSort, expectedAccountDID: context.accountDID)
        guard !Task.isCancelled, isCurrent(context) else { return }
        sort = pendingSort
        appState.appSettings.threadSortOrder = pendingSort
        self.pendingSort = nil
        error = nil
      } catch {
        guard !Task.isCancelled, isCurrent(context) else { return }
        self.error = UserFacingError.message(for: error, action: "save reply order") ?? "Couldn’t save reply order. Try again."
      }
    }
  }

  private func sortLabel(_ value: String) -> String {
    switch value {
    case "newest": "Latest"
    case "oldest": "Oldest"
    default: "Top"
    }
  }

  private func isCurrent(_ context: SettingsFeedRefreshContext) -> Bool {
    let manager = AppStateManager.shared
    return manager.lifecycle.isAuthenticated && manager.lifecycle.appState === appState
      && manager.lifecycle.userDID == context.accountDID
      && manager.settingsAccountContextRevision == context.accountRevision
      && appState.atProtoClient.map(ObjectIdentifier.init) == context.clientIdentity
  }
}
