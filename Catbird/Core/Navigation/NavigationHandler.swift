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
            .id(did)
            
        case .post(let uri):
            ThreadView(postURI: uri, path: path)
                .toolbarVisibility(.visible, for: .automatic)
                .toolbarBackgroundVisibility(.visible, for: .automatic)
                .navigationBarTitleDisplayMode(.inline)
                .navigationTitle("Post")
                .id(uri.uriString())
            
        case .hashtag(let tag):
            HashtagView(tag: tag, path: path)
                .id(tag)
            
        case .timeline:
            FeedView(appState: appState, fetch: .timeline, path: path, selectedTab: selectedTab)
                .id("timeline")
            
        case .feed(let uri):
            FeedView(appState: appState, fetch: .feed(uri), path: path, selectedTab: selectedTab)
                .id(uri.uriString())
            
        case .list(let uri):
            ListView(listURI: uri, path: path)
                .id(uri.uriString())
            
        case .starterPack(let uri):
            StarterPackView(uri: uri, path: path)
                .id(uri.uriString())
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
        }
    }
}
