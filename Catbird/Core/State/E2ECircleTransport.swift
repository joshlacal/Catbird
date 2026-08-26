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
  static let familyCircleId = try! TID(tidString: "3l7familycircle")
  static let familyPostURI = try! ATProtocolURI(uriString: "at://did:plc:alicee2efixture/space/blue.catbird.circle/family123/did:plc:alicee2efixture/app.bsky.feed.post/post1")
  static let familyPostText = "Welcome to Family Circle"

  static let aliceOnlyURI = try! SpaceRef(uriString: "at://did:plc:alicee2efixture/space/blue.catbird.circle/aliceonly123")
  static let aliceOnlyCircleId = try! TID(tidString: "3l7alicecircle")
  static let aliceOnlyPostURI = try! ATProtocolURI(uriString: "at://did:plc:alicee2efixture/space/blue.catbird.circle/aliceonly123/did:plc:alicee2efixture/app.bsky.feed.post/post2")
  static let aliceOnlyPostText = "Alice secret notes"

  static let publicAlicePostURI = try! ATProtocolURI(uriString: "at://did:plc:alicee2efixture/app.bsky.feed.post/publicpost1")
  static let publicAlicePostText = "Hello public world from Alice"
}

/// Shared in-memory storage for E2E circle tests.
actor E2ECircleStore {
  struct StoredMedia: Sendable {
    let space: SpaceRef
    let authorDID: DID
    let cid: CID
    let data: Data
  }

  private var circles: [SpaceRef: BlueCatbirdCircleDefs.CircleSummary] = [:]
  private var members: [SpaceRef: Set<DID>] = [:]
  private var posts: [ATProtocolURI: (post: AppBskyFeedDefs.PostView, circle: BlueCatbirdCircleDefs.CircleSummary, replyTo: ATProtocolURI?)] = [:]
  private var order: [ATProtocolURI] = []
  private var likes: [ATProtocolURI: Set<String>] = [:]
  private var mediaBlobs: [String: StoredMedia] = [:]
  private var notifications: [(recipient: DID, notification: BlueCatbirdCircleDefs.Notification)] = []
  private var postSeq: Int = 1
  private var circleSeq: Int = 1
  private var likeSeq: Int = 1

  init() {
    let family = BlueCatbirdCircleDefs.CircleSummary(
      uri: E2EConstants.familyURI,
      circleId: E2EConstants.familyCircleId,
      name: "Family",
      owner: E2EConstants.aliceDID,
      memberCount: 1,
      muted: false
    )
    circles[E2EConstants.familyURI] = family
    members[E2EConstants.familyURI] = [E2EConstants.bobDID]

    let aliceOnly = BlueCatbirdCircleDefs.CircleSummary(
      uri: E2EConstants.aliceOnlyURI,
      circleId: E2EConstants.aliceOnlyCircleId,
      name: "Alice Only",
      owner: E2EConstants.aliceDID,
      memberCount: 0,
      muted: false
    )
    circles[E2EConstants.aliceOnlyURI] = aliceOnly
    members[E2EConstants.aliceOnlyURI] = []

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
    notifications = [
      (recipient: E2EConstants.aliceDID, notification: notif1),
      (recipient: E2EConstants.bobDID, notification: notifBob)
    ]

    let post1CID = CID.fromDAGCBOR(Data("post1-cid".utf8))
    let post2CID = CID.fromDAGCBOR(Data("post2-cid".utf8))
    mediaBlobs[post1CID.string] = StoredMedia(
      space: E2EConstants.familyURI,
      authorDID: E2EConstants.aliceDID,
      cid: post1CID,
      data: E2ECircleTransport.fixtureImageData
    )
    mediaBlobs[post2CID.string] = StoredMedia(
      space: E2EConstants.aliceOnlyURI,
      authorDID: E2EConstants.aliceDID,
      cid: post2CID,
      data: E2ECircleTransport.fixtureImageData
    )
  }

  private func isMember(space: SpaceRef, userDID: DID) -> Bool {
    guard let circle = circles.first(where: { $0.key.uriString() == space.uriString() })?.value else {
      return false
    }
    let userDIDString = userDID.didString()
    if circle.owner.didString() == userDIDString {
      return true
    }
    let spaceMembers = members[circle.uri] ?? []
    return spaceMembers.contains { $0.didString() == userDIDString }
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
      pinned: nil,
      knownLikers: nil
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
    CircleCapability(enabled: true, protocolRevision: "2026-08-26", supportsImages: true)
  }

  func listCircles(userDID: DID, cursor: String?) -> CircleListPage {
    let userDIDString = userDID.didString()
    let accessible = circles.values.filter { circle in
      if circle.owner.didString() == userDIDString { return true }
      let spaceMembers = members[circle.uri] ?? []
      return spaceMembers.contains { $0.didString() == userDIDString }
    }
    return CircleListPage(circles: Array(accessible), cursor: nil)
  }

  func getFeed(userDID: DID, space: SpaceRef?, cursor: String?) throws -> CircleFeedPage {
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

  func getPostThread(userDID: DID, uri: ATProtocolURI, space: SpaceRef?) throws -> CircleThreadPage {
    if let space {
      guard isMember(space: space, userDID: userDID) else {
        throw CircleError.accessRemoved
      }
    }
    guard let targetEntry = posts.first(where: { $0.key.uriString() == uri.uriString() })?.value else {
      guard let defaultCircle = circles.values.first(where: { isMember(space: $0.uri, userDID: userDID) }) else {
        throw CircleError.accessRemoved
      }
      let samplePost = posts.values.first?.post ?? posts[E2EConstants.familyPostURI]!.post
      let post = postWithViewerState(samplePost, userDID: userDID)
      let mainThread = AppBskyFeedDefs.ThreadViewPost(post: post, parent: nil, replies: nil, threadContext: nil)
      return CircleThreadPage(thread: mainThread, circle: defaultCircle)
    }
    guard isMember(space: targetEntry.circle.uri, userDID: userDID) else {
      throw CircleError.accessRemoved
    }

    let directReplies = posts.compactMap { (postURI, entry) -> AppBskyFeedDefs.ThreadViewPost? in
      guard entry.replyTo?.uriString() == uri.uriString() else { return nil }
      let replyView = postWithViewerState(entry.post, userDID: userDID)
      return AppBskyFeedDefs.ThreadViewPost(post: replyView, parent: nil, replies: nil, threadContext: nil)
    }

    let replyUnions = directReplies.map {
      AppBskyFeedDefs.ThreadViewPostRepliesUnion.appBskyFeedDefsThreadViewPost($0)
    }

    var parentThread: AppBskyFeedDefs.ThreadViewPostParentUnion? = nil
    if let parentURI = targetEntry.replyTo, let parentEntry = posts[parentURI] {
      let parentPostView = postWithViewerState(parentEntry.post, userDID: userDID)
      let parentViewPost = AppBskyFeedDefs.ThreadViewPost(post: parentPostView, parent: nil, replies: nil, threadContext: nil)
      parentThread = .appBskyFeedDefsThreadViewPost(parentViewPost)
    }

    let mainPost = postWithViewerState(targetEntry.post, userDID: userDID)
    let mainThread = AppBskyFeedDefs.ThreadViewPost(
      post: mainPost,
      parent: parentThread,
      replies: replyUnions.isEmpty ? nil : replyUnions,
      threadContext: nil
    )
    return CircleThreadPage(thread: mainThread, circle: targetEntry.circle)
  }

  func listNotifications(userDID: DID, cursor: String?) -> CircleNotificationPage {
    let userDIDString = userDID.didString()
    let accessible = notifications.compactMap { entry -> BlueCatbirdCircleDefs.Notification? in
      guard entry.recipient.didString() == userDIDString,
            isMember(space: entry.notification.circle.uri, userDID: userDID) else {
        return nil
      }
      return entry.notification
    }
    return CircleNotificationPage(notifications: accessible, cursor: nil)
  }

  func media(userDID: DID, space: SpaceRef, authorDID: DID, cid: CID) throws -> Data {
    guard isMember(space: space, userDID: userDID) else {
      throw CircleError.accessRemoved
    }
    guard let stored = mediaBlobs[cid.string] else {
      throw CircleError.invalidParameter("media not found")
    }
    guard stored.space.uriString() == space.uriString(),
          stored.authorDID.didString() == authorDID.didString() else {
      throw CircleError.notAuthorized
    }
    return stored.data
  }

  func updatePreferences(userDID: DID, space: SpaceRef, muted: Bool) throws -> Bool {
    guard isMember(space: space, userDID: userDID) else {
      throw CircleError.accessRemoved
    }
    if let circle = circles.first(where: { $0.key.uriString() == space.uriString() })?.value {
      let updated = BlueCatbirdCircleDefs.CircleSummary(
        uri: circle.uri,
        circleId: circle.circleId,
        name: circle.name,
        owner: circle.owner,
        memberCount: circle.memberCount,
        muted: muted
      )
      circles[space] = updated
    }
    return muted
  }

  func report(userDID: DID, post: ATProtocolURI, circle: SpaceRef, reason: CircleReportReason, details: String?) throws -> UUID {
    guard isMember(space: circle, userDID: userDID) else {
      throw CircleError.accessRemoved
    }
    return UUID()
  }

  func activateCircle(userDID: DID, space: SpaceRef) throws -> BlueCatbirdCircleDefs.CircleSummary {
    guard let circle = circles.first(where: { $0.key.uriString() == space.uriString() })?.value else {
      throw CircleError.invalidParameter("space not found")
    }
    guard isMember(space: space, userDID: userDID) else {
      throw CircleError.notAuthorized
    }
    return circle
  }

  func createSpace(userDID: DID, skey: String?, circleId: String?, name: String, memberDIDs: [DID]) throws -> BlueCatbirdCircleDefs.CircleSummary {
    let skeyStr = skey ?? "e2e-space-\(circleSeq)"
    let circleIdStr = circleId ?? "3l7circle\(circleSeq)"
    circleSeq += 1
    let newURI = try SpaceRef(uriString: "at://\(userDID.didString())/space/blue.catbird.circle/\(skeyStr)")
    let tid = try TID(tidString: circleIdStr)
    let newCircle = BlueCatbirdCircleDefs.CircleSummary(
      uri: newURI,
      circleId: tid,
      name: name,
      owner: userDID,
      memberCount: memberDIDs.count,
      muted: false
    )
    circles[newURI] = newCircle
    members[newURI] = Set(memberDIDs)

    let notif = BlueCatbirdCircleDefs.Notification(
      id: "notif-\(skeyStr)",
      reason: .value_invite,
      actor: profile(for: userDID),
      subject: nil,
      indexedAt: ATProtocolDate(date: Date()),
      circle: newCircle
    )
    notifications.insert((recipient: userDID, notification: notif), at: 0)
    for member in memberDIDs {
      let memberNotif = BlueCatbirdCircleDefs.Notification(
        id: "notif-\(skeyStr)-\(member.didString())",
        reason: .value_invite,
        actor: profile(for: userDID),
        subject: nil,
        indexedAt: ATProtocolDate(date: Date()),
        circle: newCircle
      )
      notifications.insert((recipient: member, notification: memberNotif), at: 0)
    }
    return newCircle
  }

  func deleteSpace(userDID: DID, space: SpaceRef) throws {
    guard let circle = circles.first(where: { $0.key.uriString() == space.uriString() })?.value,
          circle.owner.didString() == userDID.didString() else {
      throw CircleError.notAuthorized
    }
    circles.removeValue(forKey: space)
    members.removeValue(forKey: space)
    for (uri, entry) in posts {
      if entry.circle.uri.uriString() == space.uriString() {
        posts.removeValue(forKey: uri)
        order.removeAll { $0.uriString() == uri.uriString() }
      }
    }
    notifications.removeAll { $0.notification.circle.uri.uriString() == space.uriString() }
  }

  func addMember(userDID: DID, space: SpaceRef, did: DID) throws {
    guard let circle = circles.first(where: { $0.key.uriString() == space.uriString() })?.value,
          circle.owner.didString() == userDID.didString() else {
      throw CircleError.notAuthorized
    }
    var spaceMembers = members[space] ?? Set()
    spaceMembers.insert(did)
    members[space] = spaceMembers

    let updated = BlueCatbirdCircleDefs.CircleSummary(
      uri: circle.uri,
      circleId: circle.circleId,
      name: circle.name,
      owner: circle.owner,
      memberCount: spaceMembers.count,
      muted: circle.muted
    )
    circles[space] = updated

    let memberNotif = BlueCatbirdCircleDefs.Notification(
      id: "notif-add-\(space.skey ?? "")-\(did.didString())",
      reason: .value_invite,
      actor: profile(for: userDID),
      subject: nil,
      indexedAt: ATProtocolDate(date: Date()),
      circle: updated
    )
    notifications.insert((recipient: did, notification: memberNotif), at: 0)
  }

  func removeMember(userDID: DID, space: SpaceRef, did: DID) throws {
    guard let circle = circles.first(where: { $0.key.uriString() == space.uriString() })?.value,
          circle.owner.didString() == userDID.didString() else {
      throw CircleError.notAuthorized
    }
    var spaceMembers = members[space] ?? Set()
    spaceMembers.remove(did)
    members[space] = spaceMembers

    let updated = BlueCatbirdCircleDefs.CircleSummary(
      uri: circle.uri,
      circleId: circle.circleId,
      name: circle.name,
      owner: circle.owner,
      memberCount: spaceMembers.count,
      muted: circle.muted
    )
    circles[space] = updated
  }

  func listMembers(userDID: DID, space: SpaceRef) throws -> [DID] {
    guard let circle = circles.first(where: { $0.key.uriString() == space.uriString() })?.value else {
      throw CircleError.invalidParameter("space not found")
    }
    guard circle.owner.didString() == userDID.didString() else {
      throw CircleError.notAuthorized
    }
    return Array(members[space] ?? Set())
  }

  func publishPost(userDID: DID, destination: CircleSummary, draft: CirclePostDraft) throws -> ATProtocolURI {
    guard isMember(space: destination.uri, userDID: userDID) else {
      throw CircleError.accessRemoved
    }
    let rkey = "e2e-post-\(postSeq)"
    postSeq += 1
    let postURI = try ATProtocolURI(uriString: "\(destination.uri.uriString())/\(userDID.didString())/app.bsky.feed.post/\(rkey)")
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
      case .appBskyEmbedImages(let images):
        let viewImages = images.images.map { img -> AppBskyEmbedImages.ViewImage in
          let imageCID = img.image.cid
          return AppBskyEmbedImages.ViewImage(
            thumb: try! URI(uriString: "https://example.com/blob/\(imageCID)"),
            fullsize: try! URI(uriString: "https://example.com/blob/\(imageCID)"),
            alt: img.alt,
            aspectRatio: img.aspectRatio
          )
        }
        postViewEmbed = .appBskyEmbedImagesView(AppBskyEmbedImages.View(images: viewImages))
      case .appBskyEmbedRecord(let rec):
        let viewRecord = AppBskyEmbedRecord.ViewRecord(
          uri: rec.record.uri,
          cid: rec.record.cid,
          author: author,
          value: .knownType(
            AppBskyFeedPost(
              text: "Quoted post",
              entities: nil,
              facets: nil,
              reply: nil,
              embed: nil,
              langs: nil,
              labels: nil,
              tags: nil,
              createdAt: ATProtocolDate(date: Date())
            )
          ),
          labels: nil,
          replyCount: 0,
          repostCount: 0,
          likeCount: 0,
          quoteCount: 0,
          embeds: nil,
          indexedAt: ATProtocolDate(date: Date())
        )
        postViewEmbed = .appBskyEmbedRecordView(AppBskyEmbedRecord.View(record: .appBskyEmbedRecordViewRecord(viewRecord)))
      case .appBskyEmbedRecordWithMedia(let rwm):
        let viewRecord = AppBskyEmbedRecord.ViewRecord(
          uri: rwm.record.record.uri,
          cid: rwm.record.record.cid,
          author: author,
          value: .knownType(
            AppBskyFeedPost(
              text: "Quoted post",
              entities: nil,
              facets: nil,
              reply: nil,
              embed: nil,
              langs: nil,
              labels: nil,
              tags: nil,
              createdAt: ATProtocolDate(date: Date())
            )
          ),
          labels: nil,
          replyCount: 0,
          repostCount: 0,
          likeCount: 0,
          quoteCount: 0,
          embeds: nil,
          indexedAt: ATProtocolDate(date: Date())
        )
        let mediaUnion: AppBskyEmbedRecordWithMedia.ViewMediaUnion?
        switch rwm.media {
        case .appBskyEmbedImages(let imgs):
          let viewImages = imgs.images.map { img in
            AppBskyEmbedImages.ViewImage(
              thumb: try! URI(uriString: "https://example.com/blob/\(img.image.cid)"),
              fullsize: try! URI(uriString: "https://example.com/blob/\(img.image.cid)"),
              alt: img.alt,
              aspectRatio: img.aspectRatio
            )
          }
          mediaUnion = .appBskyEmbedImagesView(AppBskyEmbedImages.View(images: viewImages))
        case .appBskyEmbedVideo(let vid):
          // The blob ref already carries a real CID; parsing one from a string
          // would just reintroduce a failure path the fixture cannot handle.
          if let ref = vid.video.ref {
            mediaUnion = .appBskyEmbedVideoView(
              AppBskyEmbedVideo.View(
                cid: ref.cid,
                playlist: try! URI(uriString: "https://example.com/video/\(ref.cid)/playlist.m3u8"),
                thumbnail: nil,
                alt: vid.alt,
                aspectRatio: vid.aspectRatio,
                presentation: nil
              )
            )
          } else {
            mediaUnion = nil
          }
        case .appBskyEmbedExternal(let ext):
          mediaUnion = .appBskyEmbedExternalView(
            AppBskyEmbedExternal.View(
              external: AppBskyEmbedExternal.ViewExternal(
                uri: ext.external.uri,
                title: ext.external.title,
                description: ext.external.description,
                thumb: nil,
                createdAt: nil,
                updatedAt: nil,
                readingTime: nil,
                labels: nil,
                source: nil,
                associatedRefs: nil,
                associatedProfiles: nil
              )
            )
          )
        default:
          // Fixture covers images, video and external only. Anything else
          // yields no recordWithMedia embed rather than a fabricated value.
          mediaUnion = nil
        }
        if let mediaUnion {
          postViewEmbed = .appBskyEmbedRecordWithMediaView(
            AppBskyEmbedRecordWithMedia.View(
              record: AppBskyEmbedRecord.View(record: .appBskyEmbedRecordViewRecord(viewRecord)),
              media: mediaUnion
            )
          )
        }
      default:
        break
      }
    }

    let postRecord = AppBskyFeedPost(
      text: draft.text,
      entities: nil,
      facets: draft.facets,
      reply: draft.reply,
      embed: postEmbed,
      langs: draft.langs,
      labels: draft.labels,
      tags: nil,
      createdAt: draft.createdAt
    )

    let postCID = CID.fromDAGCBOR(Data("e2e-post-cid-\(rkey)".utf8))
    let post = AppBskyFeedDefs.PostView(
      uri: postURI,
      cid: postCID,
      author: author,
      record: .knownType(postRecord),
      embed: postViewEmbed,
      bookmarkCount: nil,
      replyCount: 0,
      repostCount: 0,
      likeCount: 0,
      quoteCount: nil,
      indexedAt: ATProtocolDate(date: Date()),
      viewer: AppBskyFeedDefs.ViewerState(
        repost: nil,
        like: nil,
        bookmarked: nil,
        threadMuted: nil,
        replyDisabled: nil,
        embeddingDisabled: nil,
        pinned: nil,
        knownLikers: nil
      ),
      labels: nil,
      threadgate: nil,
      debug: nil
    )
    posts[postURI] = (post: post, circle: destination, replyTo: replyToURI)
    order.insert(postURI, at: 0)
    return postURI
  }

  func like(userDID: DID, post: ATProtocolURI, circle: SpaceRef) throws -> ATProtocolURI {
    guard isMember(space: circle, userDID: userDID) else {
      throw CircleError.accessRemoved
    }
    var userLikes = likes[post] ?? Set<String>()
    userLikes.insert(userDID.didString())
    likes[post] = userLikes
    let likeURI = try ATProtocolURI(uriString: "\(circle.uriString())/\(userDID.didString())/app.bsky.feed.like/e2e-like-\(likeSeq)")
    likeSeq += 1
    return likeURI
  }

  func deleteLike(userDID: DID, uri: ATProtocolURI, circle: SpaceRef) {
    for (postURI, userSet) in likes {
      var s = userSet
      s.remove(userDID.didString())
      likes[postURI] = s
    }
  }

  func deletePost(userDID: DID, uri: ATProtocolURI, circle: SpaceRef) {
    posts.removeValue(forKey: uri)
    order.removeAll { $0.uriString() == uri.uriString() }
  }

  func uploadImage(imageData: Data) async -> Blob {
    let cid = CID.fromBlob(imageData)
    let cidString = cid.string
    let link = ATProtoLink(cid: cid)
    mediaBlobs[cidString] = StoredMedia(
      space: E2EConstants.familyURI,
      authorDID: E2EConstants.aliceDID,
      cid: cid,
      data: imageData
    )
    return Blob(type: "blob", ref: link, mimeType: "image/jpeg", size: imageData.count, cid: cidString)
  }

  func enqueueGenericActivity(userDID: DID) {
    let targetCircle = circles.first(where: { $0.key.uriString() == E2EConstants.familyURI.uriString() })?.value ?? BlueCatbirdCircleDefs.CircleSummary(
      uri: E2EConstants.familyURI,
      circleId: E2EConstants.familyCircleId,
      name: "Family",
      owner: E2EConstants.aliceDID,
      memberCount: 1,
      muted: false
    )
    let notif = BlueCatbirdCircleDefs.Notification(
      id: "push-1",
      reason: .value_reply,
      actor: profile(for: E2EConstants.bobDID),
      subject: E2EConstants.familyPostURI,
      indexedAt: ATProtocolDate(date: Date()),
      circle: targetCircle
    )
    notifications.insert((recipient: userDID, notification: notif), at: 0)
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

  func updatePreferences(space: SpaceRef, muted: Bool) async throws -> Bool {
    try await store.updatePreferences(userDID: accountDID, space: space, muted: muted)
  }

  func report(post: ATProtocolURI, circle: CircleSummary, reason: CircleReportReason, details: String?) async throws -> UUID {
    try await store.report(userDID: accountDID, post: post, circle: circle.uri, reason: reason, details: details)
  }

  func activateCircle(space: SpaceRef) async throws -> CircleSummary {
    try await store.activateCircle(userDID: accountDID, space: space)
  }

  func publishPost(destination: CircleSummary, draft: CirclePostDraft) async throws -> ATProtocolURI {
    try await store.publishPost(userDID: accountDID, destination: destination, draft: draft)
  }

  func like(post: AppBskyFeedDefs.PostView, circle: CircleSummary) async throws -> ATProtocolURI {
    try await store.like(userDID: accountDID, post: post.uri, circle: circle.uri)
  }

  func deletePost(uri: ATProtocolURI, circle: CircleSummary) async throws {
    await store.deletePost(userDID: accountDID, uri: uri, circle: circle.uri)
  }

  func deleteLike(uri: ATProtocolURI, circle: CircleSummary) async throws {
    await store.deleteLike(userDID: accountDID, uri: uri, circle: circle.uri)
  }

  func createSpace(skey: String, circleId: String, name: String, memberDIDs: [DID]) async throws -> CircleSummary {
    try await store.createSpace(userDID: accountDID, skey: skey, circleId: circleId, name: name, memberDIDs: memberDIDs)
  }

  func deleteSpace(space: SpaceRef) async throws {
    try await store.deleteSpace(userDID: accountDID, space: space)
  }

  func addMember(space: SpaceRef, did: DID) async throws {
    try await store.addMember(userDID: accountDID, space: space, did: did)
  }

  func removeMember(space: SpaceRef, did: DID) async throws {
    try await store.removeMember(userDID: accountDID, space: space, did: did)
  }

  func listMembers(space: SpaceRef) async throws -> [DID] {
    try await store.listMembers(userDID: accountDID, space: space)
  }

  func uploadImage(_ data: Data) async throws -> Blob {
    await store.uploadImage(imageData: data)
  }

  func enqueueGenericActivity() async {
    await store.enqueueGenericActivity(userDID: accountDID)
  }
}
#endif
