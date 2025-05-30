import SwiftUI
import Petrel

struct ContentMediaSettingsView: View {
    @Environment(AppState.self) private var appState
    
    // Local state for AppSettings
    @State private var autoplayVideos: Bool
    @State private var useInAppBrowser: Bool
    @State private var showTrendingTopics: Bool
    @State private var showTrendingVideos: Bool
    
    // External media preferences
    @State private var allowYouTube: Bool
    @State private var allowYouTubeShorts: Bool
    @State private var allowVimeo: Bool
    @State private var allowTwitch: Bool
    @State private var allowGiphy: Bool
    @State private var allowSpotify: Bool
    @State private var allowAppleMusic: Bool
    @State private var allowSoundCloud: Bool
    @State private var allowFlickr: Bool
    
    // Local state for thread preferences
    @State private var isLoadingThreadPrefs = true
    @State private var threadSortOrder: String
    @State private var prioritizeFollowedUsers: Bool
    @State private var threadedReplies: Bool
    
    // Feed preferences
    @State private var isLoadingFeedPrefs = true
    @State private var hideReplies: Bool = false
    @State private var hideRepliesByUnfollowed: Bool = false
    @State private var hideReposts: Bool = false
    @State private var hideQuotePosts: Bool = false
    
    @State private var errorMessage: String?
    
    // Initialize with current settings
    init() {
        let appSettings = AppSettings()
        
        // Media playback
        _autoplayVideos = State(initialValue: appSettings.autoplayVideos)
        _useInAppBrowser = State(initialValue: appSettings.useInAppBrowser)
        _showTrendingTopics = State(initialValue: appSettings.showTrendingTopics)
        _showTrendingVideos = State(initialValue: appSettings.showTrendingVideos)
        
        // External media
        _allowYouTube = State(initialValue: appSettings.allowYouTube)
        _allowYouTubeShorts = State(initialValue: appSettings.allowYouTubeShorts)
        _allowVimeo = State(initialValue: appSettings.allowVimeo)
        _allowTwitch = State(initialValue: appSettings.allowTwitch)
        _allowGiphy = State(initialValue: appSettings.allowGiphy)
        _allowSpotify = State(initialValue: appSettings.allowSpotify)
        _allowAppleMusic = State(initialValue: appSettings.allowAppleMusic)
        _allowSoundCloud = State(initialValue: appSettings.allowSoundCloud)
        _allowFlickr = State(initialValue: appSettings.allowFlickr)
        
        // Thread prefs
        _threadSortOrder = State(initialValue: appSettings.threadSortOrder)
        _prioritizeFollowedUsers = State(initialValue: appSettings.prioritizeFollowedUsers)
        _threadedReplies = State(initialValue: appSettings.threadedReplies)
    }
    
    var body: some View {
        Form {
            // Media Playback Settings
            Section("Media Playback") {
                Toggle("Autoplay Videos", isOn: $autoplayVideos)
                    .onChange(of: autoplayVideos) {
                        appState.appSettings.autoplayVideos = autoplayVideos
                    }
                
                Toggle("Open Links In-App", isOn: $useInAppBrowser)
                    .onChange(of: useInAppBrowser) {
                        appState.appSettings.useInAppBrowser = useInAppBrowser
                    }
            }
            
            // Feed Content Settings
            Section("Feed Content") {
                Toggle("Show Trending Topics", isOn: $showTrendingTopics)
                    .onChange(of: showTrendingTopics) {
                        appState.appSettings.showTrendingTopics = showTrendingTopics
                    }
                
                Toggle("Show Trending Videos", isOn: $showTrendingVideos)
                    .onChange(of: showTrendingVideos) {
                        appState.appSettings.showTrendingVideos = showTrendingVideos
                    }
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
            
            // Thread View Preferences
            Section("Thread Display") {
                if isLoadingThreadPrefs {
                    ProgressView()
                } else {
                    Picker("Thread Sort Order", selection: $threadSortOrder) {
                        Text("Algorithmic").tag("ranked")
                        Text("Latest First").tag("newest")
                        Text("Oldest First").tag("oldest")
                        Text("Most Likes").tag("most-likes")
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
                    
                    Toggle("Threaded Replies View", isOn: $threadedReplies)
                        .onChange(of: threadedReplies) {
                            appState.appSettings.threadedReplies = threadedReplies
                        }
                }
            }
            
            // External Media Embeds
            Section("External Media Embeds") {
                ExternalMediaToggle(service: "YouTube", icon: "video.fill", isOn: $allowYouTube) {
                    appState.appSettings.allowYouTube = allowYouTube
                }
                
                ExternalMediaToggle(service: "YouTube Shorts", icon: "video.fill", isOn: $allowYouTubeShorts) {
                    appState.appSettings.allowYouTubeShorts = allowYouTubeShorts
                }
                
                ExternalMediaToggle(service: "Vimeo", icon: "video.fill", isOn: $allowVimeo) {
                    appState.appSettings.allowVimeo = allowVimeo
                }
                
                ExternalMediaToggle(service: "Twitch", icon: "gamecontroller.fill", isOn: $allowTwitch) {
                    appState.appSettings.allowTwitch = allowTwitch
                }
                
                ExternalMediaToggle(service: "GIPHY", icon: "photo.on.rectangle.angled", isOn: $allowGiphy) {
                    appState.appSettings.allowGiphy = allowGiphy
                }
                
                ExternalMediaToggle(service: "Spotify", icon: "music.note", isOn: $allowSpotify) {
                    appState.appSettings.allowSpotify = allowSpotify
                }
                
                ExternalMediaToggle(service: "Apple Music", icon: "music.note", isOn: $allowAppleMusic) {
                    appState.appSettings.allowAppleMusic = allowAppleMusic
                }
                
                ExternalMediaToggle(service: "SoundCloud", icon: "music.note", isOn: $allowSoundCloud) {
                    appState.appSettings.allowSoundCloud = allowSoundCloud
                }
                
                ExternalMediaToggle(service: "Flickr", icon: "photo.fill", isOn: $allowFlickr) {
                    appState.appSettings.allowFlickr = allowFlickr
                }
            }
            
            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
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
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadServerPreferences()
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
        // Reset media playback
        autoplayVideos = true
        useInAppBrowser = true
        showTrendingTopics = true
        showTrendingVideos = true
        
        // Reset external media
        allowYouTube = true
        allowYouTubeShorts = true
        allowVimeo = true
        allowTwitch = true
        allowGiphy = true
        allowSpotify = true
        allowAppleMusic = true
        allowSoundCloud = true
        allowFlickr = true
        
        // Reset thread prefs - sync with server first, then with AppSettings
        threadSortOrder = "ranked"
        prioritizeFollowedUsers = true
        threadedReplies = false
        
        // Reset feed prefs
        hideReplies = false
        hideRepliesByUnfollowed = false
        hideReposts = false
        hideQuotePosts = false
        
        // Update app settings
        appState.appSettings.autoplayVideos = autoplayVideos
        appState.appSettings.useInAppBrowser = useInAppBrowser
        appState.appSettings.showTrendingTopics = showTrendingTopics
        appState.appSettings.showTrendingVideos = showTrendingVideos
        
        appState.appSettings.allowYouTube = allowYouTube
        appState.appSettings.allowYouTubeShorts = allowYouTubeShorts
        appState.appSettings.allowVimeo = allowVimeo
        appState.appSettings.allowTwitch = allowTwitch
        appState.appSettings.allowGiphy = allowGiphy
        appState.appSettings.allowSpotify = allowSpotify
        appState.appSettings.allowAppleMusic = allowAppleMusic
        appState.appSettings.allowSoundCloud = allowSoundCloud
        appState.appSettings.allowFlickr = allowFlickr
        
        appState.appSettings.threadSortOrder = threadSortOrder
        appState.appSettings.prioritizeFollowedUsers = prioritizeFollowedUsers
        appState.appSettings.threadedReplies = threadedReplies
        
        // Update server preferences
        updateThreadViewPreference()
        updateFeedViewPreference()
    }
}

struct ExternalMediaToggle: View {
    let service: String
    let icon: String
    @Binding var isOn: Bool
    let onToggle: () -> Void
    
    var body: some View {
        Toggle(isOn: $isOn) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.blue)
                    .frame(width: 24)
                Text(service)
            }
        }
        .onChange(of: isOn) { _ in
            onToggle()
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ContentMediaSettingsView()
            .environment(AppState())
    }
}
