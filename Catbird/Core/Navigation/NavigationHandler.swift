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
      .ignoresSafeArea(edges: .vertical)
      #if os(iOS)
      .toolbarTitleDisplayMode(.inline)
      #endif
      .id(did)

    case .post(let uri):
      ThreadView(postURI: uri, path: path)
        .ignoresSafeArea()
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .navigationTitle("Post")
        .id(uri.uriString())

    case .hashtag(let tag):
      HashtagView(tag: tag, path: path)
        .id(tag)

    case .topic(let topic):
      TopicFeedView(topic: topic, path: path)
        .navigationTitle(topic)
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .id(topic)

    case .timeline:
      FeedCollectionView.create(
        for: .timeline,
        appState: appState,
        navigationPath: path
      )
      .ignoresSafeArea()
      .id("timeline")
      .navigationTitle("Timeline")
      #if os(iOS)
      .toolbarTitleDisplayMode(.large)
      #endif

    case .feed(let uri):
      FeedScreen(path: path, uri: uri)
        .ignoresSafeArea()
        .id(uri.uriString())

    case .list(let uri):
      // The full list screen, with Report, Block/Unblock and Share, for every list link.
      ListDetailView(listURIString: uri.uriString(), path: path)
        .id(uri.uriString())

    case .starterPack(let uri):
      StarterPackView(uri: uri, path: path)
        .id(uri.uriString())

    case .starterPackShort(let code):
      StarterPackShortResolverView(code: code, path: path)
        .id(code)

    case .postLikes(let postUri):
      let isLabeler = postUri.contains("app.bsky.labeler.service")
      LikesView(postUri: postUri, path: path)
        .navigationTitle(isLabeler ? "Liked By" : "Likes")
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
      BookmarksView(path: path)
        .navigationTitle("Bookmarks")
        #if os(iOS)
        .toolbarTitleDisplayMode(.large)
        #endif
        .id("bookmarks")

    case .activitySubscriptions:
      ActivitySubscriptionsView()
        .navigationTitle("Activity Alerts")
        #if os(iOS)
        .toolbarTitleDisplayMode(.large)
        #endif
        .id("activitySubscriptions")
    case .notificationActivity(let uris):
      NotificationsActivityListView(postURIs: uris, path: path)
        .navigationTitle("Activity")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .id(uris.map { $0.uriString() }.joined(separator: ","))

    case .videoFeed:
      VideoFeedView(path: path)
        .id("videoFeed")
    case .videoFeedStartingAt(let post):
      VideoFeedView(initialPost: post, path: path)
        .id("videoFeed-\(post.uri.uriString())")

    case .settings(let route):
      settingsView(for: route)
        .id("settings-\(route.rawValue)")

    #if os(iOS)
    case .conversation(let convoId):
      ConversationView(convoId: convoId)
        .id(convoId)

    case .chatTab:
      ChatTabView(
        selectedTab: selectedTab,
        lastTappedTab: .constant(nil)
      )
      .id("chatTab")
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
      ListDetailView(listURIString: listURI.uriString(), path: path)
        .navigationTitle("List")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .id(listURI.uriString())

    case .listMembers(let listURI):
      ListMemberManagementView(listURI: listURI.uriString())
        .id(listURI.uriString())
    }
  }

  @ViewBuilder
  private static func settingsView(for route: SettingsRoute) -> some View {
    SettingsDestinationView(target: route.target)
      .navigationDestination(for: SettingsTarget.self) { target in SettingsDestinationView(target: target) }
  }

  /// Returns the title string for a navigation destination
  static func titleForDestination(_ destination: NavigationDestination) -> String {
    switch destination {
    case .profile:
      return "Profile"
    case .post:
      return "Post"
    case .hashtag(let tag):
      return "#\(tag)"
    case .topic(let topic):
      return topic
    case .timeline:
      return "Timeline"
    case .feed:
      return "Feed"
    case .list:
      return "List"
    case .starterPack, .starterPackShort:
      return "Starter Pack"
    case .postLikes:
      return "Likes"
    case .postReposts:
      return "Reposts"
    case .postQuotes:
      return "Quotes"
    case .bookmarks:
      return "Bookmarks"
    case .activitySubscriptions:
      return "Activity Alerts"
    case .notificationActivity:
      return "Activity"
    case .videoFeed, .videoFeedStartingAt:
      return "Videos"
    case .settings(let route):
      return route.target.screen.title
    #if os(iOS)
    case .conversation:
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
  public static func iconForDestination(_ destination: NavigationDestination) -> String {
    switch destination {
    case .profile:
      return "person.circle"
    case .post:
      return "doc.text"
    case .hashtag, .topic:
      return "number"
    case .timeline:
      return "clock"
    case .feed:
      return "newspaper"
    case .list:
      return "list.bullet"
    case .starterPack, .starterPackShort:
      return "person.3.sequence"
    case .postLikes:
      return "heart"
    case .postReposts:
      return "arrow.2.squarepath"
    case .postQuotes:
      return "quote.bubble"
    case .bookmarks:
      return "bookmark"
    case .activitySubscriptions:
      return "bell.badge"
    case .notificationActivity:
      return "bell"
    case .videoFeed, .videoFeedStartingAt:
      return "play.rectangle"
    case .settings:
      return "gear"
    #if os(iOS)
    case .conversation:
      return "bubble.left.and.bubble.right"
    case .chatTab:
      return "message"
    #endif
    case .createList:
      return "plus.circle"
    case .editList:
      return "pencil.circle"
    case .listManager:
      return "list.bullet.rectangle"
    case .listDiscovery:
      return "magnifyingglass.circle"
    case .listFeed:
      return "text.badge.plus"
    case .listMembers:
      return "person.2.circle"
    }
  }

  /// Returns the associated NuxID for a navigation destination, if one exists
  public static func nuxIDForDestination(_ destination: NavigationDestination) -> NuxID? {
    switch destination {
    case .bookmarks:
      return .bookmarksAnnouncement
    case .activitySubscriptions:
      return .activitySubscriptions
    default:
      return nil
    }
  }
}

// MARK: - Helper Views

public struct StarterPackShortResolverView: View {
  let code: String
  @Binding var path: NavigationPath
  @Environment(AppState.self) private var appState
  @Environment(SceneNavigationContext.self) private var sceneNavigation
  @State private var resolvedURI: ATProtocolURI?
  @State private var errorMessage: String?
  @State private var isLoading = true

  public init(code: String, path: Binding<NavigationPath>) {
    self.code = code
    self._path = path
  }

  public var body: some View {
    Group {
      if let resolvedURI {
        StarterPackView(uri: resolvedURI, path: $path)
      } else if let errorMessage {
        ContentUnavailableView {
          Label("Couldn’t Open Starter Pack", systemImage: "exclamationmark.triangle")
        } description: {
          Text(errorMessage)
        } actions: {
          Button("Try Again") {
            Task { await resolveCode() }
          }
        }
      } else {
        ProgressView("Opening starter pack…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task {
      await resolveCode()
    }
  }

  private func resolveCode() async {
    weak var operationScene = sceneNavigation
    guard isCurrentScene(operationScene) else { return }
    isLoading = true
    errorMessage = nil
    
    guard let url = URL(string: "https://go.bsky.app/\(code)") else {
      errorMessage = "This starter pack link isn’t valid."
      isLoading = false
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard isCurrentScene(operationScene) else { return }
      guard let httpResponse = response as? HTTPURLResponse, (200...399).contains(httpResponse.statusCode) else {
        errorMessage = "This starter pack couldn’t be found. The link may have expired."
        isLoading = false
        return
      }

      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        let candidateString = json["url"] as? String ?? json["uri"] as? String ?? json["redirect"] as? String
        if let candidateString {
          if candidateString.starts(with: "at://"), let uri = try? ATProtocolURI(uriString: candidateString) {
            self.resolvedURI = uri
          } else {
            let destination = await operationScene?.urlHandler.parseDestination(from: candidateString)
            guard isCurrentScene(operationScene) else { return }
            if case .starterPack(let uri)? = destination {
              self.resolvedURI = uri
            } else {
              errorMessage = "This starter pack couldn’t be found. The link may have expired."
            }
          }
        } else {
          errorMessage = "This starter pack couldn’t be found. The link may have expired."
        }
      } else if let location = httpResponse.value(forHTTPHeaderField: "Location") {
        if location.starts(with: "at://"), let uri = try? ATProtocolURI(uriString: location) {
          self.resolvedURI = uri
        } else {
          let destination = await operationScene?.urlHandler.parseDestination(from: location)
          guard isCurrentScene(operationScene) else { return }
          if case .starterPack(let uri)? = destination {
            self.resolvedURI = uri
          } else {
            errorMessage = "This starter pack couldn’t be found. The link may have expired."
          }
        }
      } else {
        errorMessage = "This starter pack couldn’t be found. The link may have expired."
      }
    } catch {
      guard isCurrentScene(operationScene) else { return }
      errorMessage = UserFacingError.message(for: error, action: "open this starter pack")
    }
    isLoading = false
  }

  private func isCurrentScene(_ context: SceneNavigationContext?) -> Bool {
    guard let context else { return false }
    return context === sceneNavigation
      && !context.isInvalidated
      && context.accountDID == appState.userDID
      && appState.isAuthenticated
      && !Task.isCancelled
  }
}
