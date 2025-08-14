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
    @State private var hideReposts: Bool = false
    @State private var hideQuotePosts: Bool = false
    
    @State private var errorMessage: String?
    
    var body: some View {
        Form {
            // Media Playback Settings
            Section("Media Playback") {
                Toggle("Autoplay Videos", isOn: Binding(
                    get: { appState.appSettings.autoplayVideos },
                    set: { appState.appSettings.autoplayVideos = $0 }
                ))
                .tint(.blue)
                
                .tint(.blue)
                
                Toggle("Open Links In-App", isOn: Binding(
                    get: { appState.appSettings.useInAppBrowser },
                    set: { appState.appSettings.useInAppBrowser = $0 }
                ))
                .tint(.blue)
            }
            
                    Toggle("Auto-start PiP when navigating away", isOn: Binding(
                        get: { appState.appSettings.autoStartPiP },
                        set: { appState.appSettings.autoStartPiP = $0 }
                    ))
                    .tint(.blue)
                    
                    Toggle("Remember PiP window position", isOn: Binding(
                        get: { appState.appSettings.rememberPiPPosition },
                        set: { appState.appSettings.rememberPiPPosition = $0 }
                    ))
                    .tint(.blue)
                } else {
                    Text("Enable Picture in Picture above to access additional settings")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
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
            }
            
            // Feed View Preferences - synced with server
            Section("Feed Filtering") {
                if isLoadingFeedPrefs {
                    ProgressView()
                } else {
                    Toggle("Hide Replies", isOn: $hideReplies)
                        .onChange(of: hideReplies) {
                            updateFeedViewPreference()
                        }
                    
                    Toggle("Hide Replies from Users I Don't Follow", isOn: $hideRepliesByUnfollowed)
                        .onChange(of: hideRepliesByUnfollowed) {
                            updateFeedViewPreference()
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
            Section("Thread Display") {
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
                }
            }
            
            // External Media Embeds
            Section {
                Toggle("Enable WebView Embeds", isOn: Binding(
                    get: { appState.appSettings.useWebViewEmbeds },
                    set: { appState.appSettings.useWebViewEmbeds = $0 }
                ))
                .tint(.blue)
                
                .tint(.blue)
                .disabled(!appState.appSettings.useWebViewEmbeds)
                
                Toggle("YouTube", isOn: Binding(
                    get: { appState.appSettings.allowYouTube },
                    set: { appState.appSettings.allowYouTube = $0 }
                ))
                .tint(.blue)
                
                Toggle("YouTube Shorts", isOn: Binding(
                    get: { appState.appSettings.allowYouTubeShorts },
                    set: { appState.appSettings.allowYouTubeShorts = $0 }
                ))
                .tint(.blue)
                
                Toggle("Vimeo", isOn: Binding(
                    get: { appState.appSettings.allowVimeo },
                    set: { appState.appSettings.allowVimeo = $0 }
                ))
                .tint(.blue)
                
                Toggle("Twitch", isOn: Binding(
                    get: { appState.appSettings.allowTwitch },
                    set: { appState.appSettings.allowTwitch = $0 }
                ))
                .tint(.blue)
                
                Toggle("GIPHY", isOn: Binding(
                    get: { appState.appSettings.allowGiphy },
                    set: { appState.appSettings.allowGiphy = $0 }
                ))
                .tint(.blue)
                
                Toggle("Tenor", isOn: Binding(
                    get: { appState.appSettings.allowTenor },
                    set: { appState.appSettings.allowTenor = $0 }
                ))
                .tint(.blue)
                
                Toggle("Spotify", isOn: Binding(
                    get: { appState.appSettings.allowSpotify },
                    set: { appState.appSettings.allowSpotify = $0 }
                ))
                .tint(.blue)
                
                Toggle("Apple Music", isOn: Binding(
                    get: { appState.appSettings.allowAppleMusic },
                    set: { appState.appSettings.allowAppleMusic = $0 }
                ))
                .tint(.blue)
                
                Toggle("SoundCloud", isOn: Binding(
                    get: { appState.appSettings.allowSoundCloud },
                    set: { appState.appSettings.allowSoundCloud = $0 }
                ))
                .tint(.blue)
                
                Toggle("Flickr", isOn: Binding(
                    get: { appState.appSettings.allowFlickr },
                    set: { appState.appSettings.allowFlickr = $0 }
                ))
                .tint(.blue)
            } header: {
                Text("External Media Embeds")
            } footer: {
                Text("WebView embeds show interactive content directly in posts. Picture in Picture allows videos to continue playing in a floating window while browsing. When WebView embeds are disabled, external media will display as link cards. Control which external media services are allowed to display embedded content in posts.")
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
        .toolbarTitleDisplayMode(.inline)
        .task {
            await loadServerPreferences()
        }
        .onAppear {
            // Initialize local state from current app settings
            threadSortOrder = appState.appSettings.threadSortOrder
            prioritizeFollowedUsers = appState.appSettings.prioritizeFollowedUsers
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
                hideReposts = feedPref.hideReposts ?? false
                hideQuotePosts = feedPref.hideQuotePosts ?? false
            }
            
            // Update app settings to ensure consistency
            appState.appSettings.threadSortOrder = threadSortOrder
            appState.appSettings.prioritizeFollowedUsers = prioritizeFollowedUsers
            
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
                    hideReposts: hideReposts,
                    hideQuotePosts: hideQuotePosts
                )
            } catch {
                errorMessage = "Failed to update feed preferences: \(error.localizedDescription)"
            }
        }
    }
    
    private func resetToDefaults() {
        // Reset media playback settings
        appState.appSettings.autoplayVideos = true
        appState.appSettings.useInAppBrowser = true
        appState.appSettings.showTrendingTopics = true
        appState.appSettings.showTrendingVideos = true
        
        // Reset external media settings
        appState.appSettings.useWebViewEmbeds = true
        appState.appSettings.enablePictureInPicture = true
        appState.appSettings.allowYouTube = true
        appState.appSettings.allowYouTubeShorts = true
        appState.appSettings.allowVimeo = true
        appState.appSettings.allowTwitch = true
        appState.appSettings.allowGiphy = true
        appState.appSettings.allowTenor = true
        appState.appSettings.allowSpotify = true
        appState.appSettings.allowAppleMusic = true
        appState.appSettings.allowSoundCloud = true
        appState.appSettings.allowFlickr = true
        
        // Reset thread preferences
        threadSortOrder = "hot"
        prioritizeFollowedUsers = true
        appState.appSettings.threadSortOrder = threadSortOrder
        appState.appSettings.prioritizeFollowedUsers = prioritizeFollowedUsers
        appState.appSettings.threadedReplies = false
        
        // Reset feed preferences
        hideReplies = false
        hideRepliesByUnfollowed = false
        hideReposts = false
        hideQuotePosts = false
        
        // Update server preferences
        updateThreadViewPreference()
        updateFeedViewPreference()
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ContentMediaSettingsView()
            .environment(AppState.shared)
    }
}
