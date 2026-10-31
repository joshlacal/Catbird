import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("Notification list visibility policy")
@MainActor
struct NotificationListVisibilityPolicyTests {
  private var filterableCategories: [
    (reason: String, keyPath: WritableKeyPath<NotificationPreferences, AppBskyNotificationDefs.FilterablePreference>)
  ] {
    [
      ("follow", \.follow),
      ("like", \.like),
      ("like-via-repost", \.likeViaRepost),
      ("mention", \.mention),
      ("quote", \.quote),
      ("reply", \.reply),
      ("repost", \.repost),
      ("repost-via-repost", \.repostViaRepost)
    ]
  }

  private var simpleCategories: [
    (reason: String, keyPath: WritableKeyPath<NotificationPreferences, AppBskyNotificationDefs.Preference>)
  ] {
    [
      ("starterpack-joined", \.starterpackJoined),
      ("subscribed-post", \.subscribedPost),
      ("unverified", \.unverified),
      ("verified", \.verified)
    ]
  }

  private var allConfiguredReasons: [String] {
    filterableCategories.map { $0.reason } + simpleCategories.map { $0.reason }
  }

  @Test("Each filterable category controls only its matching raw reason")
  func filterableReasonMapping() throws {
    for category in filterableCategories {
      var preferences = NotificationPreferences()
      preferences[keyPath: category.keyPath] = .init(include: "all", list: false, push: true)

      for reason in allConfiguredReasons {
        let notification = try makeNotification(reason: reason)
        #expect(
          NotificationListVisibilityPolicy.allows(notification, preferences: preferences) == (reason != category.reason),
          "Changing \(category.reason) must only hide \(category.reason), checked \(reason)"
        )
      }
    }
  }

  @Test("Each list-only category controls only its matching raw reason")
  func simpleReasonMapping() throws {
    for category in simpleCategories {
      var preferences = NotificationPreferences()
      preferences[keyPath: category.keyPath] = .init(list: false, push: true)

      for reason in allConfiguredReasons {
        let notification = try makeNotification(reason: reason)
        #expect(
          NotificationListVisibilityPolicy.allows(notification, preferences: preferences) == (reason != category.reason),
          "Changing \(category.reason) must only hide \(category.reason), checked \(reason)"
        )
      }
    }
  }

  @Test("Filterable in-app channels are independent of category and chat push settings")
  func filterableListIsIndependentOfPush() throws {
    for category in filterableCategories {
      for list in [false, true] {
        for push in [false, true] {
          var preferences = NotificationPreferences()
          preferences.chat = .init(include: "all", push: push)
          preferences[keyPath: category.keyPath] = .init(include: "all", list: list, push: push)
          let notification = try makeNotification(reason: category.reason)

          #expect(NotificationListVisibilityPolicy.allows(notification, preferences: preferences) == list)
        }
      }
    }
  }

  @Test("List-only categories are independent of push settings")
  func simpleListIsIndependentOfPush() throws {
    for category in simpleCategories {
      for list in [false, true] {
        for push in [false, true] {
          var preferences = NotificationPreferences()
          preferences[keyPath: category.keyPath] = .init(list: list, push: push)
          let notification = try makeNotification(reason: category.reason)

          #expect(NotificationListVisibilityPolicy.allows(notification, preferences: preferences) == list)
        }
      }
    }
  }

  @Test("People I follow requires following evidence, never followedBy or missing viewer data")
  func followsRequiresOutgoingFollowEvidence() throws {
    let following = try ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.graph.follow/author1")
    let followedBy = try ATProtocolURI(uriString: "at://did:plc:author1/app.bsky.graph.follow/viewer")
    let cases: [(viewer: AppBskyActorDefs.ViewerState?, visible: Bool)] = [
      (nil, false),
      (.init(), false),
      (.init(followedBy: followedBy), false),
      (.init(following: following), true),
      (.init(following: following, followedBy: followedBy), true)
    ]

    for category in filterableCategories {
      var preferences = NotificationPreferences()
      preferences[keyPath: category.keyPath] = .init(include: "follows", list: true, push: false)

      for fixture in cases {
        let notification = try makeNotification(reason: category.reason, viewer: fixture.viewer)
        #expect(NotificationListVisibilityPolicy.allows(notification, preferences: preferences) == fixture.visible)
      }

      preferences[keyPath: category.keyPath] = .init(include: "follows", list: false, push: true)
      let followedAuthor = try makeNotification(reason: category.reason, viewer: .init(following: following))
      #expect(!NotificationListVisibilityPolicy.allows(followedAuthor, preferences: preferences))
    }
  }

  @Test("Unknown audience values use all without changing the preference value")
  func unknownIncludeUsesAll() throws {
    for category in filterableCategories {
      var preferences = NotificationPreferences()
      preferences[keyPath: category.keyPath] = .init(include: "future-audience", list: true, push: false)
      let original = preferences
      let notification = try makeNotification(reason: category.reason)

      #expect(NotificationListVisibilityPolicy.allows(notification, preferences: preferences))
      #expect(preferences == original)

      preferences[keyPath: category.keyPath] = .init(include: "future-audience", list: false, push: true)
      #expect(!NotificationListVisibilityPolicy.allows(notification, preferences: preferences))
    }
  }

  @Test("Contact matches and unknown reasons have no category preference")
  func unconfiguredReasonsPassThrough() throws {
    var preferences = NotificationPreferences()
    preferences.chat = .init(include: "all", push: false)
    for category in filterableCategories {
      preferences[keyPath: category.keyPath] = .init(include: "follows", list: false, push: false)
    }
    for category in simpleCategories {
      preferences[keyPath: category.keyPath] = .init(list: false, push: false)
    }

    for reason in ["contact-match", "future-notification-reason"] {
      let notification = try makeNotification(reason: reason)
      #expect(NotificationListVisibilityPolicy.allows(notification, preferences: preferences))
    }
  }

  @Test("Feed-generator likes and follow-back presentation keep their raw reason preference")
  func derivedPresentationTypesUseRawReason() throws {
    let following = try ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.graph.follow/author1")
    let feedLike = try makeNotification(
      reason: "like",
      token: "feed-like",
      reasonSubject: "at://did:plc:feedauthor/app.bsky.feed.generator/test"
    )
    let followBack = try makeNotification(reason: "follow", token: "follow-back", viewer: .init(following: following))
    let groups = [
      makeGroup(id: "feed-like", type: .feedgenLike, notifications: [feedLike]),
      makeGroup(id: "follow-back", type: .followBack, notifications: [followBack])
    ]
    var preferences = NotificationPreferences()
    preferences.like = .init(include: "all", list: false, push: true)
    preferences.follow = .init(include: "follows", list: true, push: false)

    let visible = NotificationListVisibilityPolicy.visibleGroups(groups, preferences: preferences)
    #expect(visible.map { $0.id } == ["follow-back"])
    #expect(visible.first?.type == .followBack)

    preferences.follow = .init(include: "all", list: false, push: true)
    #expect(NotificationListVisibilityPolicy.visibleGroups(groups, preferences: preferences).isEmpty)
  }

  @Test("Mixed groups retain only eligible members, metadata, and visible unread state")
  func mixedGroupProjectionPreservesMetadata() throws {
    let following = try ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.graph.follow/author1")
    let hidden = try makeNotification(reason: "like", token: "hidden", timestamp: 300, isRead: false)
    let visible = try makeNotification(
      reason: "like", token: "visible", viewer: .init(following: following), timestamp: 100, isRead: true
    )
    let subject = try makePost(token: "subject")
    let parent = try makePost(token: "parent")
    let source = GroupedNotification(
      id: "stable-group-id", type: .like, notifications: [hidden, visible],
      subjectPost: subject, parentPost: parent, pageNumber: 2
    )
    var preferences = NotificationPreferences()
    preferences.like = .init(include: "follows", list: true, push: false)

    let result = NotificationListVisibilityPolicy.visibleGroups([source], preferences: preferences)
    let projected = try #require(result.first)
    #expect(result.count == 1)
    #expect(projected.id == source.id)
    #expect(projected.type == source.type)
    #expect(projected.pageNumber == source.pageNumber)
    #expect(projected.subjectPost?.uri == subject.uri)
    #expect(projected.parentPost?.uri == parent.uri)
    #expect(projected.notifications.map { $0.uri } == [visible.uri])
    #expect(projected.latestNotification.uri == visible.uri)
    #expect(!projected.hasUnreadNotifications)
    #expect(projected.notifications.first?.isRead == true)
    #expect(source.notifications.map { $0.uri } == [hidden.uri, visible.uri])
    #expect(source.notifications.map { $0.isRead } == [false, true])
    #expect(source.hasUnreadNotifications)
  }

  @Test("Projection orders by raw page then surviving timestamp with stable input ties")
  func projectionSortUsesSurvivingMembers() throws {
    let following = try ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.graph.follow/author1")
    let follower = AppBskyActorDefs.ViewerState(following: following)
    let hiddenNewest = try makeNotification(reason: "like", token: "hidden-newest", timestamp: 500)
    let survivingOlder = try makeNotification(reason: "like", token: "surviving-older", viewer: follower, timestamp: 100)
    let middle = try makeNotification(reason: "like", token: "middle", viewer: follower, timestamp: 200)
    let tied = try makeNotification(reason: "like", token: "tied", viewer: follower, timestamp: 200)
    let nextPage = try makeNotification(reason: "like", token: "next-page", viewer: follower, timestamp: 900)
    let groups = [
      makeGroup(id: "next-page", notifications: [nextPage], pageNumber: 1),
      makeGroup(id: "mixed", notifications: [hiddenNewest, survivingOlder]),
      makeGroup(id: "z-middle", notifications: [middle]),
      makeGroup(id: "a-tied", notifications: [tied]),
      makeGroup(id: "all-hidden", notifications: [hiddenNewest])
    ]
    var preferences = NotificationPreferences()
    preferences.like = .init(include: "follows", list: true, push: true)

    let result = NotificationListVisibilityPolicy.visibleGroups(groups, preferences: preferences)
    #expect(result.map { $0.id } == ["z-middle", "a-tied", "mixed", "next-page"])
    #expect(result.map { $0.pageNumber } == [0, 0, 0, 1])
    #expect(groups.map { $0.id } == ["next-page", "mixed", "z-middle", "a-tied", "all-hidden"])
    #expect(groups[1].notifications.map { $0.uri } == [hiddenNewest.uri, survivingOlder.uri])
  }

  @Test("Re-enabling a category restores the untouched cached members and read flags")
  func reenableRestoresSourceGroups() throws {
    let first = try makeNotification(reason: "like", token: "first", timestamp: 200, isRead: true)
    let second = try makeNotification(reason: "like", token: "second", timestamp: 100, isRead: false)
    let source = [makeGroup(id: "likes", notifications: [first, second])]
    var preferences = NotificationPreferences()
    preferences.like = .init(include: "all", list: false, push: true)

    #expect(NotificationListVisibilityPolicy.visibleGroups(source, preferences: preferences).isEmpty)

    preferences.like = .init(include: "all", list: true, push: false)
    let restored = NotificationListVisibilityPolicy.visibleGroups(source, preferences: preferences)
    let group = try #require(restored.first)
    #expect(group.id == "likes")
    #expect(group.notifications.map { $0.uri } == [first.uri, second.uri])
    #expect(group.notifications.map { $0.isRead } == [true, false])
    #expect(group.hasUnreadNotifications)
    #expect(source[0].notifications.map { $0.uri } == [first.uri, second.uri])
  }

  @Test("Empty source and fully filtered groups do not create empty projected groups")
  func emptyGroupsAreOmitted() throws {
    let notification = try makeNotification(reason: "like")
    let groups = [
      makeGroup(id: "already-empty", notifications: []),
      makeGroup(id: "hidden", notifications: [notification])
    ]
    var preferences = NotificationPreferences()
    preferences.like = .init(include: "all", list: false, push: true)

    #expect(NotificationListVisibilityPolicy.visibleGroups([], preferences: preferences).isEmpty)
    #expect(NotificationListVisibilityPolicy.visibleGroups(groups, preferences: preferences).isEmpty)
  }

}

private extension NotificationListVisibilityPolicyTests {
  func makeNotification(
    reason: String,
    token: String = "event",
    viewer: AppBskyActorDefs.ViewerState? = nil,
    timestamp: TimeInterval = 1_000,
    isRead: Bool = false,
    reasonSubject: String? = nil
  ) throws -> AppBskyNotificationListNotifications.Notification {
    let author = AppBskyActorDefs.ProfileView(
      did: try DID(didString: "did:plc:author1"),
      handle: try Handle(handleString: "author1.bsky.social"),
      displayName: "Test Author",
      viewer: viewer
    )
    let subject = try reasonSubject.map { try ATProtocolURI(uriString: $0) }
    return AppBskyNotificationListNotifications.Notification(
      uri: try ATProtocolURI(uriString: "at://did:plc:author1/app.bsky.feed.post/\(token)"),
      cid: try CID.parse("bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"),
      author: author,
      reason: reason,
      reasonSubject: subject,
      record: .object([:]),
      isRead: isRead,
      indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: timestamp))
    )
  }

  func makeGroup(
    id: String,
    type: NotificationType = .like,
    notifications: [AppBskyNotificationListNotifications.Notification],
    pageNumber: Int = 0
  ) -> GroupedNotification {
    GroupedNotification(
      id: id, type: type, notifications: notifications,
      subjectPost: nil, parentPost: nil, pageNumber: pageNumber
    )
  }

  func makePost(token: String) throws -> AppBskyFeedDefs.PostView {
    AppBskyFeedDefs.PostView(
      uri: try ATProtocolURI(uriString: "at://did:plc:author1/app.bsky.feed.post/\(token)"),
      cid: try CID.parse("bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"),
      author: AppBskyActorDefs.ProfileViewBasic(
        did: try DID(didString: "did:plc:author1"),
        handle: try Handle(handleString: "author1.bsky.social")
      ),
      record: .object([:]),
      indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_000))
    )
  }
}
