#if DEBUG
import Foundation
import Petrel
import PetrelCatbird

/// In-memory Circle transport for deterministic `--e2e-mode` UI tests.
actor E2ECircleTransport: CircleTransport {
  let publicEndpointCallCount: Int = 0

  private let aliceDID = try! DID(didString: "did:plc:alicee2efixture")
  private let bobDID = try! DID(didString: "did:plc:bobtest123")
  private let familyURI = try! SpaceRef(uriString: "at://did:plc:alicee2efixture/space/blue.catbird.circle/family123")

  private var circles: [CircleSummary]
  private var feedItems: [BlueCatbirdCircleDefs.FeedItem]
  private var notifications: [BlueCatbirdCircleDefs.Notification]

  init() {
    let family = BlueCatbirdCircleDefs.CircleSummary(
      uri: try! SpaceRef(uriString: "at://did:plc:alicee2efixture/space/blue.catbird.circle/family123"),
      name: "Family",
      owner: try! DID(didString: "did:plc:alicee2efixture"),
      accessState: .value_active,
      muted: false,
      members: [try! DID(didString: "did:plc:bobtest123")]
    )
    self.circles = [family]

    let author = AppBskyActorDefs.ProfileViewBasic(
      did: try! DID(didString: "did:plc:alicee2efixture"),
      handle: try! Handle(handleString: "alice.test"),
      displayName: "Alice",
      pronouns: nil,
      avatar: nil,
      associated: nil,
      viewer: nil,
      labels: nil,
      createdAt: nil,
      verification: nil,
      status: nil,
      debug: nil
    )
    let postURI = try! ATProtocolURI(uriString: "at://did:plc:alicee2efixture/space/blue.catbird.circle/family123/app.bsky.feed.post/post1")
    let post = AppBskyFeedDefs.PostView(
      uri: postURI,
      cid: CID.fromDAGCBOR(Data("post1-cid".utf8)),
      author: author,
      record: .knownType(
        AppBskyFeedPost(
          text: "Welcome to Family Circle",
          entities: nil,
          facets: nil,
          reply: nil,
          embed: nil,
          langs: [LanguageCodeContainer(languageCode: "en")],
          labels: nil,
          tags: nil,
          createdAt: ATProtocolDate(date: Date())
        )
      ),
      embed: nil,
      bookmarkCount: nil,
      replyCount: 0,
      repostCount: 0,
      likeCount: 0,
      quoteCount: nil,
      indexedAt: ATProtocolDate(date: Date()),
      viewer: nil,
      labels: nil,
      threadgate: nil,
      debug: nil
    )
    let feedItem = BlueCatbirdCircleDefs.FeedItem(
      post: AppBskyFeedDefs.FeedViewPost(post: post, reply: nil, reason: nil, feedContext: nil, reqId: nil),
      circle: family
    )
    self.feedItems = [feedItem]

    let notif = BlueCatbirdCircleDefs.Notification(
      id: "notif-1",
      reason: .value_invite,
      actor: author,
      subject: nil,
      indexedAt: ATProtocolDate(date: Date()),
      circle: family
    )
    self.notifications = [notif]
  }

  func capabilities() async throws -> CircleCapability {
    CircleCapability(enabled: true, protocolRevision: "2026-08-24", supportsImages: true)
  }

  func listCircles(cursor: String?) async throws -> CircleListPage {
    CircleListPage(circles: circles, cursor: nil)
  }

  func getFeed(space: SpaceRef?, cursor: String?) async throws -> CircleFeedPage {
    if let space {
      let filtered = feedItems.filter { $0.circle.uri == space }
      return CircleFeedPage(items: filtered, cursor: nil)
    }
    return CircleFeedPage(items: feedItems, cursor: nil)
  }

  func getPostThread(uri: ATProtocolURI, space: SpaceRef) async throws -> CircleThreadPage {
    let circle = circles.first(where: { $0.uri == space }) ?? circles[0]
    let matchingItem = feedItems.first(where: { $0.post.post.uri == uri })
    let post = matchingItem?.post.post ?? feedItems[0].post.post
    let thread = AppBskyFeedDefs.ThreadViewPost(post: post, parent: nil, replies: [], threadContext: nil)
    return CircleThreadPage(thread: thread, circle: circle)
  }

  func listNotifications(cursor: String?) async throws -> CircleNotificationPage {
    CircleNotificationPage(notifications: notifications, cursor: nil)
  }

  func media(space: SpaceRef, authorDID: DID, cid: CID) async throws -> Data {
    Data()
  }

  func createCircle(name: String, memberDIDs: [DID]) async throws -> CircleOperation {
    let newURI = try! SpaceRef(uriString: "at://\(aliceDID.didString())/space/blue.catbird.circle/\(UUID().uuidString)")
    let newCircle = BlueCatbirdCircleDefs.CircleSummary(
      uri: newURI,
      name: name,
      owner: aliceDID,
      accessState: .value_active,
      muted: false,
      members: memberDIDs
    )
    circles.append(newCircle)
    return CircleOperation(id: "op-create-\(UUID().uuidString)", status: .value_complete, space: newURI, error: nil)
  }

  func updateMember(space: SpaceRef, memberDID: DID, action: CircleMemberAction) async throws -> CircleOperation {
    if let idx = circles.firstIndex(where: { $0.uri == space }) {
      var members = circles[idx].members ?? []
      if action == .remove {
        members.removeAll { $0 == memberDID }
      } else if !members.contains(memberDID) {
        members.append(memberDID)
      }
      circles[idx] = BlueCatbirdCircleDefs.CircleSummary(
        uri: circles[idx].uri,
        name: circles[idx].name,
        owner: circles[idx].owner,
        accessState: circles[idx].accessState,
        muted: circles[idx].muted,
        members: members
      )
    }
    return CircleOperation(id: "op-member-\(UUID().uuidString)", status: .value_complete, space: space, error: nil)
  }

  func updatePreferences(space: SpaceRef, muted: Bool) async throws -> Bool {
    if let idx = circles.firstIndex(where: { $0.uri == space }) {
      circles[idx] = BlueCatbirdCircleDefs.CircleSummary(
        uri: circles[idx].uri,
        name: circles[idx].name,
        owner: circles[idx].owner,
        accessState: circles[idx].accessState,
        muted: muted,
        members: circles[idx].members
      )
    }
    return muted
  }

  func report(post: ATProtocolURI, circle: CircleSummary, reason: CircleReportReason, details: String?) async throws -> UUID {
    UUID()
  }

  func activate(space: SpaceRef) async throws -> CircleAccessState {
    .active
  }

  func publishPost(destination: CircleSummary, draft: CirclePostDraft) async throws -> ATProtocolURI {
    let rkey = UUID().uuidString
    let postURI = try! ATProtocolURI(uriString: "\(destination.uri.uriString())/app.bsky.feed.post/\(rkey)")
    let author = AppBskyActorDefs.ProfileViewBasic(
      did: aliceDID,
      handle: try! Handle(handleString: "alice.test"),
      displayName: "Alice",
      pronouns: nil,
      avatar: nil,
      associated: nil,
      viewer: nil,
      labels: nil,
      createdAt: nil,
      verification: nil,
      status: nil,
      debug: nil
    )
    let post = AppBskyFeedDefs.PostView(
      uri: postURI,
      cid: CID.fromDAGCBOR(Data("post-\(rkey)".utf8)),
      author: author,
      record: .knownType(
        AppBskyFeedPost(
          text: draft.text,
          entities: nil,
          facets: nil,
          reply: nil,
          embed: nil,
          langs: draft.langs,
          labels: nil,
          tags: nil,
          createdAt: ATProtocolDate(date: Date())
        )
      ),
      embed: nil,
      bookmarkCount: nil,
      replyCount: 0,
      repostCount: 0,
      likeCount: 0,
      quoteCount: nil,
      indexedAt: ATProtocolDate(date: Date()),
      viewer: nil,
      labels: nil,
      threadgate: nil,
      debug: nil
    )
    let item = BlueCatbirdCircleDefs.FeedItem(
      post: AppBskyFeedDefs.FeedViewPost(post: post, reply: nil, reason: nil, feedContext: nil, reqId: nil),
      circle: destination
    )
    feedItems.insert(item, at: 0)
    return postURI
  }

  func like(post: AppBskyFeedDefs.PostView, circle: CircleSummary) async throws -> ATProtocolURI {
    try! ATProtocolURI(uriString: "\(circle.uri.uriString())/app.bsky.feed.like/\(UUID().uuidString)")
  }

  func deletePost(uri: ATProtocolURI, circle: CircleSummary) async throws {
    feedItems.removeAll { $0.post.post.uri == uri }
  }

  func deleteLike(uri: ATProtocolURI, circle: CircleSummary) async throws {}

  func deleteCircle(space: SpaceRef) async throws -> CircleOperation {
    circles.removeAll { $0.uri == space }
    feedItems.removeAll { $0.circle.uri == space }
    return CircleOperation(id: "op-del-\(UUID().uuidString)", status: .value_complete, space: space, error: nil)
  }

  func getOperation(id: String) async throws -> CircleOperation {
    CircleOperation(id: id, status: .value_complete, space: familyURI, error: nil)
  }

  func retryOperation(id: String) async throws -> CircleOperation {
    CircleOperation(id: id, status: .value_complete, space: familyURI, error: nil)
  }
}
#endif
