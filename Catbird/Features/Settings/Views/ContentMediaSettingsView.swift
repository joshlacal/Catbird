import SwiftUI
import Petrel

struct ContentMediaSettingsView: View {
    @Environment(AppState.self) private var appState
    
    // Local state for thread preferences (server-synced)
    @State private var isLoadingThreadPrefs = true
    @State private var threadSortOrder: String = "hot"
    @State private var prioritizeFollowedUsers: Bool = true
    
    // Feed preferences (server-synced)
    @State private var isLoadingFeedPrefs = true
    @State private var hideReplies: Bool = false
    @State private var hideRepliesByUnfollowed: Bool = false
    @State private var hideRepliesByLikeCount: Int? = nil
    @State private var hideReposts: Bool = false
    @State private var hideQuotePosts: Bool = false
    
    @State private var errorMessage: String?
    
    // Interests (server-synced)
    @State private var userInterestsCount: Int = 0
    @State private var isLoadingInterests: Bool = true
    
    var body: some View {
        Form {
            // Media Playback Settings
            Section("Media Playback") {
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
            }

            // Sensitive Content
            Section {
                Toggle("Scan for Sensitive Content", isOn: Binding(
                    get: { appState.appSettings.sensitiveContentScanningEnabled },
                    set: { appState.appSettings.sensitiveContentScanningEnabled = $0 }
                ))
                .tint(.blue)
            } header: {
                Text("Chat Safety")
            } footer: {
                Text("Uses on-device analysis to detect nudity in chat images. Analysis is performed entirely on your device and is never sent to a server.")
            }
            
            // Feed Content Settings
            Section("Feed Content") {
                Toggle("Show Trending Topics", isOn: Binding(
                    get: { appState.appSettings.showTrendingTopics },
                    set: { appState.appSettings.showTrendingTopics = $0 }
                ))
                .tint(.blue)
                
                Toggle("Show Trending Videos", isOn: Binding(
                    get: { appState.appSettings.showTrendingVideos },
                    set: { appState.appSettings.showTrendingVideos = $0 }
                ))
                .tint(.blue)
                
                NavigationLink {
                    InterestsSettingsView()
                } label: {
                    HStack {
                        Text("Your Interests")
                        Spacer()
                        if isLoadingInterests {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(userInterestsCount > 0 ? "\(userInterestsCount) selected" : "None")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            
            // Feed View Preferences - synced with server
            Section {
                if isLoadingFeedPrefs {
                    ProgressView()
                } else {
                    Toggle("Hide All Replies", isOn: $hideReplies)
                        .onChange(of: hideReplies) {
                            updateFeedViewPreference()
                        }
                    
                    if hideReplies {
                        Text("Hides all reply posts from your feed, except your own replies")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 16)
                    }
                    
                    Toggle("Hide Replies to Users You Don't Follow", isOn: $hideRepliesByUnfollowed)
                        .onChange(of: hideRepliesByUnfollowed) {
                            updateFeedViewPreference()
                        }
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
                    
                    Toggle("Hide Reposts", isOn: $hideReposts)
                        .onChange(of: hideReposts) {
                            updateFeedViewPreference()
                        }
                    
                    Toggle("Hide Quote Posts", isOn: $hideQuotePosts)
                        .onChange(of: hideQuotePosts) {
                            updateFeedViewPreference()
                        }
                }
            } header: {
                Text("Feed Filtering")
            } footer: {
                if !isLoadingFeedPrefs {
                    Text("These settings sync with your Bluesky account and apply across all your devices")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Language Filtering
            Section("Language Filtering") {
                Toggle("Hide posts in non-preferred languages", isOn: Binding(
                    get: { appState.appSettings.hideNonPreferredLanguages },
                    set: { appState.appSettings.hideNonPreferredLanguages = $0 }
                ))
                .tint(.blue)
                
                Toggle("Show language indicators on posts", isOn: Binding(
                    get: { appState.appSettings.showLanguageIndicators },
                    set: { appState.appSettings.showLanguageIndicators = $0 }
                ))
                .tint(.blue)
                
                NavigationLink("Manage Languages") {
                    LanguageSettingsView()
                }
            }
            
            // Thread View Preferences
            Section {
                if isLoadingThreadPrefs {
                    ProgressView()
                } else {
                    Picker("Thread Sort Order", selection: $threadSortOrder) {
                        Text("Hot").tag("hot")
                        Text("Top").tag("top")
                        Text("Latest").tag("newest")
                        Text("Oldest").tag("oldest")
                    }
                    .onChange(of: threadSortOrder) {
                        updateThreadViewPreference()
                        appState.appSettings.threadSortOrder = threadSortOrder
                    }
                    
                    Toggle("Prioritize Users I Follow", isOn: $prioritizeFollowedUsers)
                        .onChange(of: prioritizeFollowedUsers) {
                            updateThreadViewPreference()
                            appState.appSettings.prioritizeFollowedUsers = prioritizeFollowedUsers
                        }
                        .tint(.blue)
                    
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
                }
            } header: {
                Text("Thread Display")
            } footer: {
                Text("When enabled, replies hidden by threadgates are loaded automatically. Otherwise, a \"Show More Replies\" button will appear when hidden replies are available.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // External Media Embeds
            Section {
                Toggle("Enable WebView Embeds", isOn: Binding(
                    get: { appState.appSettings.useWebViewEmbeds },
                    set: { appState.appSettings.useWebViewEmbeds = $0 }
                ))
                .tint(.blue)
                
                NavigationLink(destination: ExternalMediaPreferencesView()) {
                    HStack {
                        Text("External Media Preferences")
                        Spacer()
                    }
                }
                .disabled(!appState.appSettings.useWebViewEmbeds)
            } header: {
                Text("External Media Embeds")
            } footer: {
                Text("Control player permissions and consent for third-party media embeds such as YouTube, Spotify, and Bandcamp.")
                    .appFont(AppTextRole.footnote)
                    .foregroundStyle(.secondary)
            }
            
            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .appFont(AppTextRole.callout)
                }
            }
            
            // Reset Section
            Section {
                Button("Reset to Defaults") {
                    resetToDefaults()
                }
                .foregroundStyle(.red)
            }
        }
        .navigationTitle("Content & Media")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .task {
            await loadServerPreferences()
        }
        .onAppear {
            // Initialize local state from current app settings
            threadSortOrder = appState.appSettings.threadSortOrder
            prioritizeFollowedUsers = appState.appSettings.prioritizeFollowedUsers
            Task { @MainActor in
                if let prefs = try? await appState.preferencesManager.getPreferences() {
                    userInterestsCount = prefs.interests.count
                }
            }
        }
    }
    
    private func loadServerPreferences() async {
        isLoadingThreadPrefs = true
        isLoadingFeedPrefs = true
        
        do {
            let preferences = try await appState.preferencesManager.getPreferences()
            
            // Load thread view preferences
            if let threadPref = preferences.threadViewPref {
                if let sort = threadPref.sort {
                    threadSortOrder = sort
                }
                
                if let prioritize = threadPref.prioritizeFollowedUsers {
                    prioritizeFollowedUsers = prioritize
                }
            }
            
            // Load feed view preferences
            if let feedPref = preferences.feedViewPref {
                hideReplies = feedPref.hideReplies ?? false
                hideRepliesByUnfollowed = feedPref.hideRepliesByUnfollowed ?? false
                hideRepliesByLikeCount = feedPref.hideRepliesByLikeCount
                hideReposts = feedPref.hideReposts ?? false
                hideQuotePosts = feedPref.hideQuotePosts ?? false
            }
            
            // Update app settings to ensure consistency
            appState.appSettings.threadSortOrder = threadSortOrder
            appState.appSettings.prioritizeFollowedUsers = prioritizeFollowedUsers
            
            
            userInterestsCount = preferences.interests.count
            isLoadingInterests = false
        } catch {
            errorMessage = "Failed to load preferences: \(error.localizedDescription)"
        }
        
        isLoadingThreadPrefs = false
        isLoadingFeedPrefs = false
    }
    
    private func updateThreadViewPreference() {
        Task {
            do {
                try await appState.preferencesManager.setThreadViewPreferences(
                    sort: threadSortOrder,
                    prioritizeFollowedUsers: prioritizeFollowedUsers
                )
            } catch {
                errorMessage = "Failed to update thread preferences: \(error.localizedDescription)"
            }
        }
    }
    
    private func updateFeedViewPreference() {
        Task {
            do {
                try await appState.preferencesManager.setFeedViewPreferences(
                    hideReplies: hideReplies,
                    hideRepliesByUnfollowed: hideRepliesByUnfollowed,
                    hideRepliesByLikeCount: hideRepliesByLikeCount,
                    hideReposts: hideReposts,
                    hideQuotePosts: hideQuotePosts
                )
                
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
    
    private func resetToDefaults() {
        // Reset media playback settings
        appState.appSettings.sensitiveContentScanningEnabled = true
        appState.appSettings.autoplayVideos = true
        appState.appSettings.useInAppBrowser = true
        appState.appSettings.showTrendingTopics = true
        appState.appSettings.showTrendingVideos = true
        
        // Reset external media settings
        appState.appSettings.useWebViewEmbeds = true
        appState.appSettings.setExternalMediaConsentForAllProviders(.undecided)
        // Reset thread preferences
        threadSortOrder = "hot"
        prioritizeFollowedUsers = true
        appState.appSettings.threadSortOrder = threadSortOrder
        appState.appSettings.prioritizeFollowedUsers = prioritizeFollowedUsers
        appState.appSettings.threadedReplies = false
        appState.appSettings.showHiddenPosts = false
        
        // Reset feed preferences
        hideReplies = false
        hideRepliesByUnfollowed = false
        hideRepliesByLikeCount = nil
        hideReposts = false
        hideQuotePosts = false
        
        // Update server preferences
        updateThreadViewPreference()
        updateFeedViewPreference()
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

