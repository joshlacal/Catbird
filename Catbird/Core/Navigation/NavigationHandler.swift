import Petrel
import SwiftUI

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
      .ignoresSafeArea()
      #if os(iOS)
      .toolbarTitleDisplayMode(.inline)
      #endif
      .id(did)

    case .post(let uri):
      ThreadView(postURI: uri, path: path)
            .ignoresSafeArea()

        //                .toolbarVisibility(.visible, for: .automatic)
        //                .toolbarBackgroundVisibility(.visible, for: .automatic)
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        //                .themedNavigationBar(appState.themeManager)
        .navigationTitle("Post")
        //                .ensureDeepNavigationFonts() // Use deep navigation fonts for thread views
        .id(uri.uriString())

    case .hashtag(let tag):
      HashtagView(tag: tag, path: path)
            .ignoresSafeArea()

        //                .themedNavigationBar(appState.themeManager)
        .id(tag)

    case .timeline:
      FeedCollectionView.create(
        for: .timeline,
        appState: appState,
        navigationPath: path
      )
      .ignoresSafeArea()

      .id("timeline")  // Add stable identity
      .navigationTitle("Timeline")
      #if os(iOS)
      .toolbarTitleDisplayMode(.large)
      #endif

    case .feed(let uri):
        FeedScreen(path: path, uri: uri)
        .ignoresSafeArea()
        .id(uri.uriString())

    case .list(let uri):
      ListView(listURI: uri, path: path)
        //                .themedNavigationBar(appState.themeManager)
        .id(uri.uriString())

    case .starterPack(let uri):
      StarterPackView(uri: uri, path: path)
        //                .themedNavigationBar(appState.themeManager)
        .id(uri.uriString())

    case .postLikes(let postUri):
      LikesView(postUri: postUri, path: path)
        .navigationTitle("Likes")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .id(postUri)

    case .postReposts(let postUri):
      RepostsView(postUri: postUri, path: path)
        .navigationTitle("Reposts")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .id(postUri)

    case .postQuotes(let postUri):
      QuotesView(postUri: postUri, path: path)
        .navigationTitle("Quotes")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .id(postUri)

    case .bookmarks:
      if #available(iOS 26.0, macOS 26.0, *) {
        BookmarksView(path: path)
          .navigationTitle("Bookmarks")
          #if os(iOS)
          .toolbarTitleDisplayMode(.large)
          #endif
          .id("bookmarks")
      } else {
        Text("Bookmarks require iOS 26.0 or macOS 26.0")
          .navigationTitle("Bookmarks")
      }

    #if os(iOS)
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
    #endif


    
    case .createList:
      CreateListView()
        .navigationTitle("Create List")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .id("createList")
    
    case .editList(let listURI):
      EditListView(listURI: listURI.uriString())
        .navigationTitle("Edit List")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .id(listURI.uriString())
    
    case .listManager:
      ListsManagerView()
        .navigationTitle("My Lists")
        #if os(iOS)
        .toolbarTitleDisplayMode(.large)
        #endif
        .id("listManager")
    
    case .listDiscovery:
      ListDiscoveryView()
        .navigationTitle("Discover Lists")
        #if os(iOS)
        .toolbarTitleDisplayMode(.large)
        #endif
        .id("listDiscovery")
    
    case .listFeed(let listURI):
      ListFeedView(listURI: listURI.uriString())
        .navigationTitle("List Feed")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
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
    case .postLikes:
      return "Likes"
    case .postReposts:
      return "Reposts"
    case .postQuotes:
      return "Quotes"
    case .bookmarks:
      return "Bookmarks"
    #if os(iOS)
    case .conversation:
      // Title might be dynamic based on convo, but NavigationHandler provides a static one
      return "Conversation"
    case .chatTab:
      return "Messages"
    #endif
    
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
    case .postLikes:
      return "heart"
    case .postReposts:
      return "arrow.2.squarepath"
    case .postQuotes:
      return "quote.bubble"
    case .bookmarks:
      return "bookmark"
    #if os(iOS)
    case .conversation:
      return "bubble.left.and.bubble.right.fill"  // Or just "bubble.left.fill"
    case .chatTab:
      return "bubble.left.and.bubble.right"
    #endif
    
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
