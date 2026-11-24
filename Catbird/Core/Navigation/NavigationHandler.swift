import Petrel
import SwiftUI
import CatbirdMLSCore

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
    case .settings:
      destinationContent(destination, path: path, appState: appState, selectedTab: selectedTab)
    #if os(iOS)
    case .conversation, .chatTab:
      PlatformAgeProtectedContent(operation: .directMessaging) {
        destinationContent(destination, path: path, appState: appState, selectedTab: selectedTab)
      }
    #endif
    default:
      PlatformAgeProtectedContent(operation: .generalContent, safetyTarget: safetyTarget(for: destination)) {
        destinationContent(destination, path: path, appState: appState, selectedTab: selectedTab)
      }
    }
  }

  private static func safetyTarget(for destination: NavigationDestination) -> String? {
    switch destination {
    case .profile(let actor): return actor
    case .post(let uri): return uri.uriString()
    default: return nil
    }
  }

  @ViewBuilder
  private static func destinationContent(
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
        .navigationTitle(Text("Post", comment: "Navigation bar title when viewing a single post thread."))
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
      .navigationTitle(Text("Timeline", comment: "Navigation bar title for the Following timeline."))
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
        .navigationTitle(
          isLabeler
            ? Text("Liked By", comment: "Navigation bar title listing users who liked a moderation service.")
            : Text("Likes", comment: "Navigation bar title listing users who liked a post.")
        )
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .id(postUri)

    case .postReposts(let postUri):
      RepostsView(postUri: postUri, path: path)
        .navigationTitle(Text("Reposts", comment: "Navigation bar title listing users who reposted a post."))
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .id(postUri)

    case .postQuotes(let postUri):
      QuotesView(postUri: postUri, path: path)
        .navigationTitle(Text("Quotes", comment: "Navigation bar title listing quote posts of a post."))
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .id(postUri)

    case .bookmarks:
      BookmarksView(path: path)
        .navigationTitle(Text("Bookmarks", comment: "Navigation bar title for saved bookmarks."))
        #if os(iOS)
        .toolbarTitleDisplayMode(.large)
        #endif
        .id("bookmarks")

    case .activitySubscriptions:
      ActivitySubscriptionsView()
        .navigationTitle(Text("Activity Alerts", comment: "Navigation bar title for account activity alert subscriptions."))
        #if os(iOS)
        .toolbarTitleDisplayMode(.large)
        #endif
        .id("activitySubscriptions")
    case .circlePost(let uri, let circle):
      if appState.circlesEnabled {
        ThreadView(postURI: uri, path: path, visibilityContext: .circle(circle))
          .ignoresSafeArea()
          #if os(iOS)
          .toolbarTitleDisplayMode(.inline)
          #endif
          .navigationTitle(circle.name)
          .id(uri.uriString())
      }

    case .circlesFeed:
      if appState.circlesEnabled {
        CirclesFeedView(path: path)
          .id("circlesFeed")
      }

    case .circleDetail(let circle):
      if appState.circlesEnabled {
        CircleDetailView(circle: circle, path: path)
          .id(circle.uri.description)
      }

    case .notificationActivity(let uris):
      NotificationsActivityListView(postURIs: uris, path: path)
        .navigationTitle(Text("Activity", comment: "Navigation bar title for subscribed account activity posts."))
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
    case .videoFeedZoom(let post, let source):
      VideoFeedView(initialPost: post, path: path)
        .id("videoFeed-\(post?.uri.uriString() ?? "thevids")")
        .videoFeedZoomDestination(source)

    case .settings(let route):
      settingsView(for: route)
        .id("settings-\(route.rawValue)")

    #if os(iOS)
    case .conversation(let convoId):
      ConversationView(convoId: convoId)
        .id(convoId)

    case .mlsConversation(let convoId):
      MLSRequestConversationGate(conversationID: convoId) {
        MLSConversationDetailView(conversationId: convoId)
      }
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
        .navigationTitle(Text("Create List", comment: "Navigation bar title for creating a new user list."))
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .id("createList")

    case .editList(let listURI):
      EditListView(listURI: listURI.uriString())
        .navigationTitle(Text("Edit List", comment: "Navigation bar title for editing an existing user list."))
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .id(listURI.uriString())

    case .listManager:
      ListsManagerView()
        .navigationTitle(Text("My Lists", comment: "Navigation bar title for managing the user's lists."))
        #if os(iOS)
        .toolbarTitleDisplayMode(.large)
        #endif
        .id("listManager")

    case .listDiscovery:
      ListDiscoveryView()
        .navigationTitle(Text("Discover Lists", comment: "Navigation bar title for browsing community lists."))
        #if os(iOS)
        .toolbarTitleDisplayMode(.large)
        #endif
        .id("listDiscovery")

    case .listFeed(let listURI):
      ListDetailView(listURIString: listURI.uriString(), path: path)
        .navigationTitle(Text("List", comment: "Navigation bar title when viewing a user list feed."))
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
      return String(localized: "Profile", comment: "Navigation destination title for a user profile.")
    case .post:
      return String(localized: "Post", comment: "Navigation destination title for a single post.")
    case .hashtag(let tag):
      return "#\(tag)"
    case .topic(let topic):
      return topic
    case .timeline:
      return String(localized: "Timeline", comment: "Navigation destination title for the home timeline.")
    case .feed:
      return String(localized: "Feed", comment: "Navigation destination title for a custom feed.")
    case .list:
      return String(localized: "List", comment: "Navigation destination title for a user list.")
    case .starterPack, .starterPackShort:
      return String(localized: "Starter Pack", comment: "Navigation destination title for a starter pack.")
    case .postLikes:
      return String(localized: "Likes", comment: "Navigation destination title for post likes.")
    case .postReposts:
      return String(localized: "Reposts", comment: "Navigation destination title for post reposts.")
    case .postQuotes:
      return String(localized: "Quotes", comment: "Navigation destination title for post quotes.")
    case .bookmarks:
      return String(localized: "Bookmarks", comment: "Navigation destination title for bookmarks.")
    case .activitySubscriptions:
      return String(localized: "Activity Alerts", comment: "Navigation destination title for activity alerts.")
    case .circlePost(_, let circle):
      return circle.name
    case .circlesFeed:
      return String(localized: "Circles", comment: "Navigation destination title for Circles feed.")
    case .circleDetail(let circle):
      return circle.name
    case .notificationActivity:
      return String(localized: "Activity", comment: "Navigation destination title for notification activity.")
    case .videoFeed, .videoFeedStartingAt, .videoFeedZoom:
      return String(localized: "Videos", comment: "Navigation destination title for video feed.")
    case .settings(let route):
      return route.target.screen.title
    #if os(iOS)
    case .conversation:
      return String(localized: "Conversation", comment: "Navigation destination title for a chat conversation.")
    case .mlsConversation:
      return String(localized: "Secure Conversation", comment: "Navigation destination title for an encrypted MLS conversation.")
    case .chatTab:
      return String(localized: "Messages", comment: "Navigation destination title for Messages.")
    #endif
    case .createList:
      return String(localized: "Create List", comment: "Navigation destination title for creating a list.")
    case .editList:
      return String(localized: "Edit List", comment: "Navigation destination title for editing a list.")
    case .listManager:
      return String(localized: "My Lists", comment: "Navigation destination title for My Lists.")
    case .listDiscovery:
      return String(localized: "Discover Lists", comment: "Navigation destination title for Discover Lists.")
    case .listFeed:
      return String(localized: "List Feed", comment: "Navigation destination title for a list feed.")
    case .listMembers:
      return String(localized: "List Members", comment: "Navigation destination title for list members.")
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
    case .circlePost:
      return "person.2.circle"
    case .circlesFeed:
      return "person.2.circle.fill"
    case .circleDetail:
      return "person.2.circle"
    case .notificationActivity:
      return "bell"
    case .videoFeed, .videoFeedStartingAt, .videoFeedZoom:
      return "play.rectangle"
    case .settings:
      return "gear"
    #if os(iOS)
    case .conversation:
      return "bubble.left.and.bubble.right"
    case .mlsConversation:
      return "lock.bubble"
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
          Label {
            Text("Couldn’t Open Starter Pack", comment: "Error title when a short starter pack link cannot be resolved.")
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
        } description: {
          Text(errorMessage)
        } actions: {
          Button {
            Task { await resolveCode() }
          } label: {
            Text("Try Again", comment: "Button retrying opening a starter pack link.")
          }
        }
      } else {
        ProgressView {
          Text("Opening starter pack…", comment: "Progress message while resolving a starter pack link.")
        }
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
      errorMessage = String(localized: "This starter pack link isn’t valid.", comment: "Error message when a short starter pack URL is malformed.")
      isLoading = false
      return
    }

    let notFoundMessage = String(
      localized: "This starter pack couldn’t be found. The link may have expired.",
      comment: "Error message when a short starter pack link cannot be resolved."
    )

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard isCurrentScene(operationScene) else { return }
      guard let httpResponse = response as? HTTPURLResponse, (200...399).contains(httpResponse.statusCode) else {
        errorMessage = notFoundMessage
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
              errorMessage = notFoundMessage
            }
          }
        } else {
          errorMessage = notFoundMessage
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
            errorMessage = notFoundMessage
          }
        }
      } else {
        errorMessage = notFoundMessage
      }
    } catch {
      guard isCurrentScene(operationScene) else { return }
      errorMessage = UserFacingError.message(
        for: error,
        action: String(localized: "open this starter pack", comment: "Action phrase for opening a starter pack.")
      )
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
