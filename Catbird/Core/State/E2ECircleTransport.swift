#if DEBUG
import Foundation
import Petrel
import PetrelCatbird
import UIKit

struct E2EConstants {
  static let aliceDIDString = "did:plc:alicee2efixture"
  static let bobDIDString = "did:plc:bobe2efixture"
  static let aliceDID = try! DID(didString: aliceDIDString)
  static let bobDID = try! DID(didString: bobDIDString)

  static let familyURI = try! SpaceRef(uriString: "at://did:plc:alicee2efixture/space/blue.catbird.circle/family123")
  static let familyPostURI = try! ATProtocolURI(uriString: "at://did:plc:alicee2efixture/space/blue.catbird.circle/family123/did:plc:alicee2efixture/app.bsky.feed.post/post1")
  static let familyPostText = "Welcome to Family Circle"

  static let aliceOnlyURI = try! SpaceRef(uriString: "at://did:plc:alicee2efixture/space/blue.catbird.circle/aliceonly123")
  static let aliceOnlyPostURI = try! ATProtocolURI(uriString: "at://did:plc:alicee2efixture/space/blue.catbird.circle/aliceonly123/did:plc:alicee2efixture/app.bsky.feed.post/post2")
  static let aliceOnlyPostText = "Alice secret notes"

  static let publicAlicePostURI = try! ATProtocolURI(uriString: "at://did:plc:alicee2efixture/app.bsky.feed.post/publicpost1")
  static let publicAlicePostText = "Hello public world from Alice"
}

/// Shared in-memory storage for E2E circle tests.
actor E2ECircleStore {
  private var circles: [SpaceRef: BlueCatbirdCircleDefs.CircleSummary] = [:]
  private var posts: [ATProtocolURI: (post: AppBskyFeedDefs.PostView, circle: BlueCatbirdCircleDefs.CircleSummary, replyTo: ATProtocolURI?)] = [:]
  private var order: [ATProtocolURI] = []
  private var likes: [ATProtocolURI: Set<String>] = [:]
  private var mediaBlobs: [String: Data] = [:]
  private var notifications: [BlueCatbirdCircleDefs.Notification] = []

  private var opSeq: Int = 1
  private var postSeq: Int = 1
  private var circleSeq: Int = 1
  private var likeSeq: Int = 1

  init() {
    let family = BlueCatbirdCircleDefs.CircleSummary(
      uri: E2EConstants.familyURI,
      name: "Family",
      owner: E2EConstants.aliceDID,
      accessState: .value_active,
      muted: false,
      members: [E2EConstants.bobDID]
    )
    circles[E2EConstants.familyURI] = family

    let aliceOnly = BlueCatbirdCircleDefs.CircleSummary(
      uri: E2EConstants.aliceOnlyURI,
      name: "Alice Only",
      owner: E2EConstants.aliceDID,
      accessState: .value_active,
      muted: false,
      members: []
    )
    circles[E2EConstants.aliceOnlyURI] = aliceOnly

    let aliceAuthor = AppBskyActorDefs.ProfileViewBasic(
      did: E2EConstants.aliceDID,
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

    let post1 = AppBskyFeedDefs.PostView(
      uri: E2EConstants.familyPostURI,
      cid: CID.fromDAGCBOR(Data("post1-cid".utf8)),
      author: aliceAuthor,
      record: .knownType(
        AppBskyFeedPost(
          text: E2EConstants.familyPostText,
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
    posts[E2EConstants.familyPostURI] = (post: post1, circle: family, replyTo: nil)
    order.append(E2EConstants.familyPostURI)

    let post2 = AppBskyFeedDefs.PostView(
      uri: E2EConstants.aliceOnlyPostURI,
      cid: CID.fromDAGCBOR(Data("post2-cid".utf8)),
      author: aliceAuthor,
      record: .knownType(
        AppBskyFeedPost(
          text: E2EConstants.aliceOnlyPostText,
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
    posts[E2EConstants.aliceOnlyPostURI] = (post: post2, circle: aliceOnly, replyTo: nil)
    order.append(E2EConstants.aliceOnlyPostURI)

    let notif1 = BlueCatbirdCircleDefs.Notification(
      id: "notif-1",
      reason: .value_invite,
      actor: aliceAuthor,
      subject: nil,
      indexedAt: ATProtocolDate(date: Date()),
      circle: family
    )
    let notifBob = BlueCatbirdCircleDefs.Notification(
      id: "notif-bob-1",
      reason: .value_invite,
      actor: aliceAuthor,
      subject: nil,
      indexedAt: ATProtocolDate(date: Date()),
      circle: family
    )
    notifications = [notif1, notifBob]

    mediaBlobs["post1-cid"] = E2ECircleTransport.fixtureImageData
    mediaBlobs["post2-cid"] = E2ECircleTransport.fixtureImageData
  }

  private func isMember(space: SpaceRef, userDID: DID) -> Bool {
    guard let circle = circles.first(where: { $0.key.uriString() == space.uriString() })?.value else {
      return false
    }
    let userDIDString = userDID.didString()
    if circle.owner.didString() == userDIDString {
      return true
    }
    return (circle.members ?? []).contains { $0.didString() == userDIDString }
  }

  private func profile(for did: DID) -> AppBskyActorDefs.ProfileViewBasic {
    let isBob = did.didString() == E2EConstants.bobDIDString
    let handleString = isBob ? "bob.test" : "alice.test"
    let displayName = isBob ? "Bob" : "Alice"
    return AppBskyActorDefs.ProfileViewBasic(
      did: did,
      handle: try! Handle(handleString: handleString),
      displayName: displayName,
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
  }

  private func postWithViewerState(_ post: AppBskyFeedDefs.PostView, userDID: DID) -> AppBskyFeedDefs.PostView {
    let userLikes = likes[post.uri] ?? Set<String>()
    let isLiked = userLikes.contains(userDID.didString())
    let viewerLikeURI = isLiked ? (try? ATProtocolURI(uriString: "\(post.uri.uriString())/app.bsky.feed.like/viewer-like")) : nil
    let viewer = AppBskyFeedDefs.ViewerState(
      repost: nil,
      like: viewerLikeURI,
      bookmarked: nil,
      threadMuted: nil,
      replyDisabled: nil,
      embeddingDisabled: nil,
      pinned: nil
    )
    let totalLikes = (post.likeCount ?? 0) + userLikes.count

    return AppBskyFeedDefs.PostView(
      uri: post.uri,
      cid: post.cid,
      author: post.author,
      record: post.record,
      embed: post.embed,
      bookmarkCount: post.bookmarkCount,
      replyCount: post.replyCount,
      repostCount: post.repostCount,
      likeCount: totalLikes,
      quoteCount: post.quoteCount,
      indexedAt: post.indexedAt,
      viewer: viewer,
      labels: post.labels,
      threadgate: post.threadgate,
      debug: post.debug
    )
  }

  func capabilities(userDID: DID) -> CircleCapability {
    CircleCapability(enabled: true, protocolRevision: "2026-08-24", supportsImages: true)
  }

  func listCircles(userDID: DID, cursor: String?) -> CircleListPage {
    let userDIDString = userDID.didString()
    let accessible = circles.values.filter {
      $0.owner.didString() == userDIDString || ($0.members ?? []).contains { $0.didString() == userDIDString }
    }
    return CircleListPage(circles: Array(accessible), cursor: nil)
  }

  func getFeed(space: SpaceRef?, cursor: String?) throws -> CircleFeedPage {
    return CircleFeedPage(items: order.compactMap { uri -> BlueCatbirdCircleDefs.FeedItem? in
      guard let entry = posts[uri], entry.replyTo == nil else { return nil }
      if let space {
        guard entry.circle.uri.uriString() == space.uriString() else { return nil }
      }
      let postView = postWithViewerState(entry.post, userDID: E2EConstants.aliceDID)
      let fvp = AppBskyFeedDefs.FeedViewPost(post: postView, reply: nil, reason: nil, feedContext: nil, reqId: nil)
      return BlueCatbirdCircleDefs.FeedItem(post: fvp, circle: entry.circle)
    }, cursor: nil)
  }

  func getFeed(userDID: DID, space: SpaceRef?, cursor: String?) throws -> CircleFeedPage {
    let userDIDString = userDID.didString()
    if let space {
      guard isMember(space: space, userDID: userDID) else {
        throw CircleError.accessRemoved
      }
      let filtered = order.compactMap { uri -> BlueCatbirdCircleDefs.FeedItem? in
        guard let entry = posts[uri], entry.circle.uri.uriString() == space.uriString(), entry.replyTo == nil else { return nil }
        let postView = postWithViewerState(entry.post, userDID: userDID)
        let fvp = AppBskyFeedDefs.FeedViewPost(post: postView, reply: nil, reason: nil, feedContext: nil, reqId: nil)
        return BlueCatbirdCircleDefs.FeedItem(post: fvp, circle: entry.circle)
      }
      return CircleFeedPage(items: filtered, cursor: nil)
    }

    let items = order.compactMap { uri -> BlueCatbirdCircleDefs.FeedItem? in
      guard let entry = posts[uri],
            isMember(space: entry.circle.uri, userDID: userDID),
            entry.replyTo == nil else { return nil }
      let postView = postWithViewerState(entry.post, userDID: userDID)
      let fvp = AppBskyFeedDefs.FeedViewPost(post: postView, reply: nil, reason: nil, feedContext: nil, reqId: nil)
      return BlueCatbirdCircleDefs.FeedItem(post: fvp, circle: entry.circle)
    }
    return CircleFeedPage(items: items, cursor: nil)
  }

  func getPostThread(userDID: DID, uri: ATProtocolURI, space: SpaceRef) throws -> CircleThreadPage {
    guard isMember(space: space, userDID: userDID) else {
      throw CircleError.accessRemoved
    }
    guard let targetEntry = posts.first(where: { $0.key.uriString() == uri.uriString() })?.value else {
      let defaultCircle = circles.first(where: { $0.key.uriString() == space.uriString() })?.value ?? Array(circles.values)[0]
      let post = postWithViewerState(posts.values.first?.post ?? posts[E2EConstants.familyPostURI]!.post, userDID: userDID)
      let thread = AppBskyFeedDefs.ThreadViewPost(post: post, parent: nil, replies: [], threadContext: nil)
      return CircleThreadPage(thread: thread, circle: defaultCircle)
    }

    let directReplies = order.compactMap { replyURI -> AppBskyFeedDefs.ThreadViewPostRepliesUnion? in
      guard let entry = posts[replyURI],
            entry.replyTo?.uriString() == uri.uriString(),
            entry.circle.uri.uriString() == space.uriString() else { return nil }
      let postView = postWithViewerState(entry.post, userDID: userDID)
      let threadPost = AppBskyFeedDefs.ThreadViewPost(post: postView, parent: nil, replies: [], threadContext: nil)
      return .appBskyFeedDefsThreadViewPost(threadPost)
    }

    let mainPostView = postWithViewerState(targetEntry.post, userDID: userDID)
    let mainThread = AppBskyFeedDefs.ThreadViewPost(
      post: mainPostView,
      parent: nil,
      replies: directReplies,
      threadContext: nil
    )
    return CircleThreadPage(thread: mainThread, circle: targetEntry.circle)
  }

  func listNotifications(userDID: DID, cursor: String?) -> CircleNotificationPage {
    let accessible = notifications.filter { isMember(space: $0.circle.uri, userDID: userDID) }
    return CircleNotificationPage(notifications: accessible, cursor: nil)
  }

  func media(userDID: DID, space: SpaceRef, authorDID: DID, cid: CID) throws -> Data {
    guard isMember(space: space, userDID: userDID) else {
      throw CircleError.accessRemoved
    }
    return mediaBlobs[cid.string] ?? E2ECircleTransport.fixtureImageData
  }

  func createCircle(userDID: DID, name: String, memberDIDs: [DID]) -> CircleOperation {
    let rkey = "e2e-circle-\(circleSeq)"
    circleSeq += 1
    let newURI = try! SpaceRef(uriString: "at://\(userDID.didString())/space/blue.catbird.circle/\(rkey)")
    let newCircle = BlueCatbirdCircleDefs.CircleSummary(
      uri: newURI,
      name: name,
      owner: userDID,
      accessState: .value_active,
      muted: false,
      members: memberDIDs
    )
    circles[newURI] = newCircle

    let notif = BlueCatbirdCircleDefs.Notification(
      id: "notif-\(rkey)",
      reason: .value_invite,
      actor: profile(for: userDID),
      subject: nil,
      indexedAt: ATProtocolDate(date: Date()),
      circle: newCircle
    )
    notifications.insert(notif, at: 0)

    let opId = "op-create-\(opSeq)"
    opSeq += 1
    return CircleOperation(id: opId, status: .value_complete, space: newURI, error: nil)
  }

  func updateMember(userDID: DID, space: SpaceRef, memberDID: DID, action: CircleMemberAction) throws -> CircleOperation {
    guard let circle = circles.first(where: { $0.key.uriString() == space.uriString() })?.value,
          circle.owner.didString() == userDID.didString() else {
      throw CircleError.notAuthorized
    }
    var members = circle.members ?? []
    if action == .remove {
      members.removeAll { $0.didString() == memberDID.didString() }
    } else if !members.contains(where: { $0.didString() == memberDID.didString() }) {
      members.append(memberDID)
    }
    let updated = BlueCatbirdCircleDefs.CircleSummary(
      uri: circle.uri,
      name: circle.name,
      owner: circle.owner,
      accessState: circle.accessState,
      muted: circle.muted,
      members: members
    )
    circles[space] = updated
    let opId = "op-member-\(opSeq)"
    opSeq += 1
    return CircleOperation(id: opId, status: .value_complete, space: space, error: nil)
  }

  func updatePreferences(userDID: DID, space: SpaceRef, muted: Bool) throws -> Bool {
    guard isMember(space: space, userDID: userDID) else {
      throw CircleError.accessRemoved
    }
    if let circle = circles.first(where: { $0.key.uriString() == space.uriString() })?.value {
      let updated = BlueCatbirdCircleDefs.CircleSummary(
        uri: circle.uri,
        name: circle.name,
        owner: circle.owner,
        accessState: circle.accessState,
        muted: muted,
        members: circle.members
      )
      circles[space] = updated
    }
    return muted
  }

  func publishPost(userDID: DID, destination: CircleSummary, draft: CirclePostDraft) throws -> ATProtocolURI {
    guard isMember(space: destination.uri, userDID: userDID) else {
      throw CircleError.accessRemoved
    }
    let rkey = "e2e-post-\(postSeq)"
    postSeq += 1
    let postURI = try! ATProtocolURI(uriString: "\(destination.uri.uriString())/\(userDID.didString())/app.bsky.feed.post/\(rkey)")
    let author = profile(for: userDID)

    var replyToURI: ATProtocolURI? = nil
    var postEmbed: AppBskyFeedPost.AppBskyFeedPostEmbedUnion? = nil
    var postViewEmbed: AppBskyFeedDefs.PostViewEmbedUnion? = nil

    if let reply = draft.reply {
      replyToURI = reply.parent.uri
      if let parentKey = posts.keys.first(where: { $0.uriString() == reply.parent.uri.uriString() }),
         let parentEntry = posts[parentKey] {
        var updatedPost = parentEntry.post
        let newReplyCount = (updatedPost.replyCount ?? 0) + 1
        updatedPost = AppBskyFeedDefs.PostView(
          uri: updatedPost.uri,
          cid: updatedPost.cid,
          author: updatedPost.author,
          record: updatedPost.record,
          embed: updatedPost.embed,
          bookmarkCount: updatedPost.bookmarkCount,
          replyCount: newReplyCount,
          repostCount: updatedPost.repostCount,
          likeCount: updatedPost.likeCount,
          quoteCount: updatedPost.quoteCount,
          indexedAt: updatedPost.indexedAt,
          viewer: updatedPost.viewer,
          labels: updatedPost.labels,
          threadgate: updatedPost.threadgate,
          debug: updatedPost.debug
        )
        posts[parentKey] = (post: updatedPost, circle: parentEntry.circle, replyTo: parentEntry.replyTo)
      }
    }

    if let embed = draft.embed {
      postEmbed = embed
      switch embed {
      case .appBskyEmbedImages(let imagesEmbed):
        let viewImages = imagesEmbed.images.map { img in
          let cidStr = img.image.ref?.cid.string ?? img.image.cid ?? "image-cid"
          return AppBskyEmbedImages.ViewImage(
            thumb: try! URI(uriString: "https://catbird.blue/media?cid=\(cidStr)"),
            fullsize: try! URI(uriString: "https://catbird.blue/media?cid=\(cidStr)"),
            alt: img.alt,
            aspectRatio: img.aspectRatio
          )
        }
        postViewEmbed = .appBskyEmbedImagesView(AppBskyEmbedImages.View(images: viewImages))
      case .appBskyEmbedGallery(let galleryEmbed):
        let viewImages = galleryEmbed.items.compactMap { item -> AppBskyEmbedImages.ViewImage? in
          switch item {
          case .appBskyEmbedGalleryImage(let galleryImage):
            let cidStr = galleryImage.image.ref?.cid.string ?? galleryImage.image.cid ?? "image-cid"
            return AppBskyEmbedImages.ViewImage(
              thumb: try! URI(uriString: "https://catbird.blue/media?cid=\(cidStr)"),
              fullsize: try! URI(uriString: "https://catbird.blue/media?cid=\(cidStr)"),
              alt: galleryImage.alt,
              aspectRatio: galleryImage.aspectRatio
            )
          case .unexpected:
            return nil
          }
        }
        postViewEmbed = .appBskyEmbedImagesView(AppBskyEmbedImages.View(images: viewImages))
      default:
        break
      }
    }

    let post = AppBskyFeedDefs.PostView(
      uri: postURI,
      cid: CID.fromDAGCBOR(Data("\(rkey)-cid".utf8)),
      author: author,
      record: .knownType(
        AppBskyFeedPost(
          text: draft.text,
          entities: nil,
          facets: draft.facets,
          reply: draft.reply,
          embed: postEmbed,
          langs: draft.langs,
          labels: draft.labels,
          tags: nil,
          createdAt: ATProtocolDate(date: Date())
        )
      ),
      embed: postViewEmbed,
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
    posts[postURI] = (post: post, circle: destination, replyTo: replyToURI)
    order.insert(postURI, at: 0)
    return postURI
  }

  func like(userDID: DID, post: AppBskyFeedDefs.PostView, circle: CircleSummary) throws -> ATProtocolURI {
    guard isMember(space: circle.uri, userDID: userDID) else {
      throw CircleError.accessRemoved
    }
    var userLikes = likes[post.uri] ?? Set<String>()
    userLikes.insert(userDID.didString())
    likes[post.uri] = userLikes
    let likeURI = try! ATProtocolURI(uriString: "\(circle.uri.uriString())/\(userDID.didString())/app.bsky.feed.like/e2e-like-\(likeSeq)")
    likeSeq += 1
    return likeURI
  }

  func deleteLike(userDID: DID, uri: ATProtocolURI, circle: CircleSummary) {
    for (postURI, userSet) in likes {
      var s = userSet
      s.remove(userDID.didString())
      likes[postURI] = s
    }
  }

  func deletePost(userDID: DID, uri: ATProtocolURI, circle: CircleSummary) {
    posts.removeValue(forKey: uri)
    order.removeAll { $0.uriString() == uri.uriString() }
  }

  func deleteCircle(userDID: DID, space: SpaceRef) throws -> CircleOperation {
    guard let circle = circles.first(where: { $0.key.uriString() == space.uriString() })?.value,
          circle.owner.didString() == userDID.didString() else {
      throw CircleError.notAuthorized
    }
    circles.removeValue(forKey: space)
    for (uri, entry) in posts {
      if entry.circle.uri.uriString() == space.uriString() {
        posts.removeValue(forKey: uri)
        order.removeAll { $0.uriString() == uri.uriString() }
      }
    }
    let opId = "op-del-\(opSeq)"
    opSeq += 1
    return CircleOperation(id: opId, status: .value_complete, space: space, error: nil)
  }

  func uploadImage(imageData: Data) async -> Blob {
    try? await Task.sleep(nanoseconds: 2_000_000_000)
    let cidString = "bafybeie2eimagefixture\(mediaBlobs.count + 1)"
    mediaBlobs[cidString] = imageData
    let cid = (try? CID.parse(cidString)) ?? CID.fromBlob(imageData)
    let link = ATProtoLink(cid: cid)
    return Blob(type: "blob", ref: link, mimeType: "image/jpeg", size: imageData.count, cid: cid.string)
  }

  func enqueueGenericActivity(userDID: DID) {
    let targetCircle = circles.first(where: { $0.key.uriString() == E2EConstants.familyURI.uriString() })?.value ?? BlueCatbirdCircleDefs.CircleSummary(
      uri: E2EConstants.familyURI,
      name: "Family",
      owner: E2EConstants.aliceDID,
      accessState: .value_active,
      muted: false,
      members: [E2EConstants.bobDID]
    )
    let notif = BlueCatbirdCircleDefs.Notification(
      id: "push-1",
      reason: .value_reply,
      actor: profile(for: E2EConstants.bobDID),
      subject: E2EConstants.familyPostURI,
      indexedAt: ATProtocolDate(date: Date()),
      circle: targetCircle
    )
    notifications.insert(notif, at: 0)
  }
}

/// In-memory Circle transport for deterministic `--e2e-mode` UI tests.
final class E2ECircleTransport: CircleTransport, @unchecked Sendable {
  let publicEndpointCallCount: Int = 0
  let accountDID: DID
  let store: E2ECircleStore

  static let fixtureImageData: Data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
  var fixtureImageData: Data { Self.fixtureImageData }

  init(accountDID: DID = E2EConstants.aliceDID, store: E2ECircleStore = E2ECircleStore()) {
    self.accountDID = accountDID
    self.store = store
  }

  func capabilities() async throws -> CircleCapability {
    await store.capabilities(userDID: accountDID)
  }

  func listCircles(cursor: String?) async throws -> CircleListPage {
    await store.listCircles(userDID: accountDID, cursor: cursor)
  }

  func getFeed(space: SpaceRef?, cursor: String?) async throws -> CircleFeedPage {
    try await store.getFeed(userDID: accountDID, space: space, cursor: cursor)
  }

  func getPostThread(uri: ATProtocolURI, space: SpaceRef) async throws -> CircleThreadPage {
    try await store.getPostThread(userDID: accountDID, uri: uri, space: space)
  }

  func listNotifications(cursor: String?) async throws -> CircleNotificationPage {
    await store.listNotifications(userDID: accountDID, cursor: cursor)
  }

  func media(space: SpaceRef, authorDID: DID, cid: CID) async throws -> Data {
    try await store.media(userDID: accountDID, space: space, authorDID: authorDID, cid: cid)
  }

  func createCircle(name: String, memberDIDs: [DID]) async throws -> CircleOperation {
    await store.createCircle(userDID: accountDID, name: name, memberDIDs: memberDIDs)
  }

  func updateMember(space: SpaceRef, memberDID: DID, action: CircleMemberAction) async throws -> CircleOperation {
    try await store.updateMember(userDID: accountDID, space: space, memberDID: memberDID, action: action)
  }

  func updatePreferences(space: SpaceRef, muted: Bool) async throws -> Bool {
    try await store.updatePreferences(userDID: accountDID, space: space, muted: muted)
  }

  func report(post: ATProtocolURI, circle: CircleSummary, reason: CircleReportReason, details: String?) async throws -> UUID {
    UUID()
  }

  func activate(space: SpaceRef) async throws -> CircleAccessState {
    .active
  }

  func publishPost(destination: CircleSummary, draft: CirclePostDraft) async throws -> ATProtocolURI {
    try await store.publishPost(userDID: accountDID, destination: destination, draft: draft)
  }

  func like(post: AppBskyFeedDefs.PostView, circle: CircleSummary) async throws -> ATProtocolURI {
    try await store.like(userDID: accountDID, post: post, circle: circle)
  }

  func deletePost(uri: ATProtocolURI, circle: CircleSummary) async throws {
    await store.deletePost(userDID: accountDID, uri: uri, circle: circle)
  }

  func deleteLike(uri: ATProtocolURI, circle: CircleSummary) async throws {
    await store.deleteLike(userDID: accountDID, uri: uri, circle: circle)
  }

  func deleteCircle(space: SpaceRef) async throws -> CircleOperation {
    try await store.deleteCircle(userDID: accountDID, space: space)
  }

  func getOperation(id: String) async throws -> CircleOperation {
    CircleOperation(id: id, status: .value_complete, space: E2EConstants.familyURI, error: nil)
  }

  func retryOperation(id: String) async throws -> CircleOperation {
    CircleOperation(id: id, status: .value_complete, space: E2EConstants.familyURI, error: nil)
  }

  func uploadImage(_ data: Data) async throws -> Blob {
    await store.uploadImage(imageData: data)
  }

  func enqueueGenericActivity() async {
    await store.enqueueGenericActivity(userDID: accountDID)
  }
}
#endif
