import Petrel
import SwiftUI
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
  static func viewForDestination(
    _ destination: NavigationDestination, path: Binding<NavigationPath>, appState: AppState,
    selectedTab: Binding<Int>
  ) -> some View {
    switch destination {
    case .profile(let did):
      UnifiedProfileView(
        did: did,
        selectedTab: selectedTab,
        appState: appState,
        path: path
      )
      .navigationBarTitleDisplayMode(.inline)
      .id(did)

    case .post(let uri):
      ThreadView(postURI: uri, path: path)
        //                .toolbarVisibility(.visible, for: .automatic)
        //                .toolbarBackgroundVisibility(.visible, for: .automatic)
        .navigationBarTitleDisplayMode(.inline)
        //                .themedNavigationBar(appState.themeManager)
        .navigationTitle("Post")
        //                .ensureDeepNavigationFonts() // Use deep navigation fonts for thread views
        .id(uri.uriString())

    case .hashtag(let tag):
      HashtagView(tag: tag, path: path)
        //                .themedNavigationBar(appState.themeManager)
        .id(tag)

    case .timeline:
      FeedCollectionView.create(
        for: .timeline,
        appState: appState,
        navigationPath: path
      )
      .id("timeline")  // Add stable identity
      .navigationTitle("Timeline")
      .navigationBarTitleDisplayMode(.large)

    case .feed(let uri):
      FeedCollectionView.create(
        for: .feed(uri),
        appState: appState,
        navigationPath: path
      )
      .id(uri.uriString())

    case .list(let uri):
      ListView(listURI: uri, path: path)
        //                .themedNavigationBar(appState.themeManager)
        .id(uri.uriString())

    case .starterPack(let uri):
      StarterPackView(uri: uri, path: path)
        //                .themedNavigationBar(appState.themeManager)
        .id(uri.uriString())

    case .conversation(let convoId):
      ConversationView(convoId: convoId)
        //                .themedNavigationBar(appState.themeManager)
        .id(convoId)  // Use convoId for view identity
    // Add necessary environment objects or parameters if needed
    // .environment(appState) // Already available via @Environment

    case .chatTab:
      ChatTabView(
        selectedTab: selectedTab,
        lastTappedTab: .constant(nil)  // Pass constant nil as lastTappedTab isn't available here
      )
      //             .themedNavigationBar(appState.themeManager)
      .id("chatTab")  // Static ID for the tab view itself

    case .repositoryBrowser:
      RepositoryBrowserView()
        //                .themedNavigationBar(appState.themeManager)
        .id("repositoryBrowser")

    case .repositoryDetail(let repositoryID):
      // This would show a detailed view of a specific repository
      RepositoryDetailView(repositoryID: repositoryID)
        //                .themedNavigationBar(appState.themeManager)
        .id(repositoryID)

    case .migrationWizard:
      MigrationWizardView()
        //                .themedNavigationBar(appState.themeManager)
        .id("migrationWizard")

    case .migrationProgress(let migrationID):
      MigrationProgressView(
        migration: appState.migrationService.currentMigration,
        migrationService: appState.migrationService
      )
      //            .themedNavigationBar(appState.themeManager)
      .id(migrationID)
    
    case .createList:
      CreateListView()
        .navigationTitle("Create List")
        .navigationBarTitleDisplayMode(.inline)
        .id("createList")
    
    case .editList(let listURI):
      EditListView(listURI: listURI.uriString())
        .navigationTitle("Edit List")
        .navigationBarTitleDisplayMode(.inline)
        .id(listURI.uriString())
    
    case .listManager:
      ListsManagerView()
        .navigationTitle("My Lists")
        .navigationBarTitleDisplayMode(.large)
        .id("listManager")
    
    case .listDiscovery:
      ListDiscoveryView()
        .navigationTitle("Discover Lists")
        .navigationBarTitleDisplayMode(.large)
        .id("listDiscovery")
    
    case .listFeed(let listURI):
      ListFeedView(listURI: listURI.uriString())
        .navigationTitle("List Feed")
        .navigationBarTitleDisplayMode(.inline)
        .id(listURI.uriString())
    
    case .listMembers(let listURI):
      ListMemberManagementView(listURI: listURI.uriString())
        .id(listURI.uriString())
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
    case .repositoryBrowser:
      return "🧪 Repository Browser"
    case .repositoryDetail:
      return "Repository Detail"
    case .migrationWizard:
      return "🚨 Account Migration"
    case .migrationProgress:
      return "Migration Progress"
    
    case .createList:
      return "Create List"
    
    case .editList:
      return "Edit List"
    
    case .listManager:
      return "My Lists"
    
    case .listDiscovery:
      return "Discover Lists"
    
    case .listFeed:
      return "List Feed"
    
    case .listMembers:
      return "List Members"
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
      return "bubble.left.and.bubble.right.fill"  // Or just "bubble.left.fill"
    case .chatTab:
      return "bubble.left.and.bubble.right"
    case .repositoryBrowser:
      return "archivebox.fill"
    case .repositoryDetail:
      return "doc.text.magnifyingglass"
    case .migrationWizard:
      return "arrow.triangle.2.circlepath"
    case .migrationProgress:
      return "arrow.up.arrow.down.circle"
    
    case .createList:
      return "plus.rectangle.on.rectangle"
    
    case .editList:
      return "pencil.and.list.clipboard"
    
    case .listManager:
      return "list.bullet.rectangle.portrait"
    
    case .listDiscovery:
      return "magnifyingglass"
    
    case .listFeed:
      return "list.bullet.rectangle"
    
    case .listMembers:
      return "person.2.badge.gearshape"
    }
  }
}
