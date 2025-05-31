import SwiftUI
import Petrel
import UIKit

/// Utility for handling navigation destination resolution throughout the app
struct NavigationHandler {
    
    /// Returns a view for the specified navigation destination
    /// - Parameters:
    ///   - destination: The navigation destination enum value
    ///   - path: Binding to the navigation path for further navigation
    ///   - appState: The app state environment
    /// - Returns: The appropriate view for the destination
    @ViewBuilder
    static func viewForDestination(_ destination: NavigationDestination, path: Binding<NavigationPath>, appState: AppState, selectedTab: Binding<Int>) -> some View {
        switch destination {
        case .profile(let did):
            UnifiedProfileView(
                did: did, 
                selectedTab: selectedTab, 
                appState: appState, 
                path: path
            )
            .themedNavigationBar(appState.themeManager)
            .ensureDeepNavigationFonts() // Use deep navigation fonts for profile views
            .id(did)
            
        case .post(let uri):
            ThreadView(postURI: uri, path: path)
                .toolbarVisibility(.visible, for: .automatic)
                .toolbarBackgroundVisibility(.visible, for: .automatic)
                .navigationBarTitleDisplayMode(.inline)
                .themedNavigationBar(appState.themeManager)
                .navigationTitle("Post")
                .ensureDeepNavigationFonts() // Use deep navigation fonts for thread views
                .onAppear {
                    // Configure specific appearances for post view navigation
                    let standardAppearance = UINavigationBarAppearance()
                    let scrollEdgeAppearance = UINavigationBarAppearance()
                    let compactAppearance = UINavigationBarAppearance()
                    
                    let backgroundColor = UIColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0)
                    
                    // Apply specific configuration: standard=default, scrollEdge=transparent, compact=opaque
                    standardAppearance.configureWithDefaultBackground()
                    standardAppearance.backgroundColor = backgroundColor
                    
                    scrollEdgeAppearance.configureWithTransparentBackground()
                    scrollEdgeAppearance.backgroundColor = backgroundColor
                    
                    compactAppearance.configureWithOpaqueBackground()
                    compactAppearance.backgroundColor = backgroundColor
                    
                    // Apply fonts to all appearances
                    NavigationFontConfig.applyFonts(to: standardAppearance)
                    NavigationFontConfig.applyFonts(to: scrollEdgeAppearance)
                    NavigationFontConfig.applyFonts(to: compactAppearance)
                    
                    // Set appearances to prevent black flash before theme is applied
                    UINavigationBar.appearance().standardAppearance = standardAppearance
                    UINavigationBar.appearance().scrollEdgeAppearance = scrollEdgeAppearance
                    UINavigationBar.appearance().compactAppearance = compactAppearance
                }
                .id(uri.uriString())
            
        case .hashtag(let tag):
            HashtagView(tag: tag, path: path)
                .themedNavigationBar(appState.themeManager)
                .id(tag)
            
        case .timeline:
            FeedView(appState: appState, fetch: .timeline, path: path, selectedTab: selectedTab)
                .themedNavigationBar(appState.themeManager)
                .id("timeline")
            
        case .feed(let uri):
            FeedView(appState: appState, fetch: .feed(uri), path: path, selectedTab: selectedTab)
                .themedNavigationBar(appState.themeManager)
                .id(uri.uriString())
            
        case .list(let uri):
            ListView(listURI: uri, path: path)
                .themedNavigationBar(appState.themeManager)
                .id(uri.uriString())
            
        case .starterPack(let uri):
            StarterPackView(uri: uri, path: path)
                .themedNavigationBar(appState.themeManager)
                .id(uri.uriString())
            
        case .conversation(let convoId):
            ConversationView(convoId: convoId)
//                .themedNavigationBar(appState.themeManager)
                .id(convoId) // Use convoId for view identity
                // Add necessary environment objects or parameters if needed
                // .environment(appState) // Already available via @Environment

        case .chatTab:
             ChatTabView(
                 selectedTab: selectedTab,
                 lastTappedTab: .constant(nil) // Pass constant nil as lastTappedTab isn't available here
             )
//             .themedNavigationBar(appState.themeManager)
             .id("chatTab") // Static ID for the tab view itself
        }
    }
    
    /// Returns the title string for a navigation destination
    /// - Parameter destination: The navigation destination
    /// - Returns: A title string appropriate for the destination
    static func titleForDestination(_ destination: NavigationDestination) -> String {
        switch destination {
        case .profile:
            return "Profile"
        case .post:
            return "Post"
        case .hashtag(let tag):
            return "#\(tag)"
        case .timeline:
            return "Timeline"
        case .feed:
            return "Feed"
        case .list:
            return "List"
        case .starterPack:
            return "Starter Pack"
        case .conversation:
            // Title might be dynamic based on convo, but NavigationHandler provides a static one
            return "Conversation"
        case .chatTab:
            return "Messages"
        }
    }
    
    /// Returns the icon name for a navigation destination
    /// - Parameter destination: The navigation destination
    /// - Returns: An SF Symbol name appropriate for the destination
    static func iconForDestination(_ destination: NavigationDestination) -> String {
        switch destination {
        case .profile:
            return "person"
        case .post:
            return "bubble.left"
        case .hashtag:
            return "number"
        case .timeline:
            return "list.bullet"
        case .feed:
            return "newspaper"
        case .list:
            return "list.bullet.rectangle"
        case .starterPack:
            return "person.3"
        case .conversation:
            return "bubble.left.and.bubble.right.fill" // Or just "bubble.left.fill"
        case .chatTab:
            return "bubble.left.and.bubble.right"
        }
    }
}
