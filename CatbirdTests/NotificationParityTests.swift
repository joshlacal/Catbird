//
//  NotificationParityTests.swift
//  CatbirdTests
//

import XCTest
import Petrel
@testable import Catbird

final class NotificationParityTests: XCTestCase {

  private func makeProfile(did: String, handle: String) -> AppBskyActorDefs.ProfileView {
    AppBskyActorDefs.ProfileView(
      did: try! DID(didString: did),
      handle: try! Handle(handleString: handle),
      displayName: "Test User",
      pronouns: nil,
      description: nil,
      avatar: nil,
      associated: nil,
      indexedAt: nil,
      createdAt: nil,
      viewer: nil,
      labels: nil,
      verification: nil,
      status: nil,
      debug: nil
    )
  }

  private func makeNotification(
    uriString: String,
    cidString: String = "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku",
    reason: String,
    reasonSubjectString: String? = nil,
    authorDid: String = "did:plc:author1",
    authorHandle: String = "author1.bsky.social",
    indexedAtDate: Date = Date()
  ) -> AppBskyNotificationListNotifications.Notification {
    let author = makeProfile(did: authorDid, handle: authorHandle)
    let uri = try! ATProtocolURI(uriString: uriString)
    let cid = try! CID.parse(cidString)
    let reasonSubject = reasonSubjectString.flatMap { try? ATProtocolURI(uriString: $0) }
    let indexedAt = ATProtocolDate(date: indexedAtDate)

    return AppBskyNotificationListNotifications.Notification(
      uri: uri,
      cid: cid,
      author: author,
      reason: reason,
      reasonSubject: reasonSubject,
      record: .object([:]),
      starterPack: nil,
      isRead: false,
      indexedAt: indexedAt,
      labels: nil
    )
  }

  func testAdditionalNotificationReasonsAreVisibleAndRoutable() async {
    let viewModel = NotificationsViewModel(client: nil)

    let starterPackNotification = makeNotification(
      uriString: "at://did:plc:user1/app.bsky.graph.starterpack/pack1",
      reason: "starterpack-joined",
      reasonSubjectString: "at://did:plc:user1/app.bsky.graph.starterpack/pack1",
      authorDid: "did:plc:user1"
    )

    let verifiedNotification = makeNotification(
      uriString: "at://did:plc:user2/app.bsky.actor.profile/self",
      reason: "verified",
      authorDid: "did:plc:user2"
    )

    let unverifiedNotification = makeNotification(
      uriString: "at://did:plc:user3/app.bsky.actor.profile/self",
      reason: "unverified",
      authorDid: "did:plc:user3"
    )

    let contactMatchNotification = makeNotification(
      uriString: "at://did:plc:user4/app.bsky.actor.profile/self",
      reason: "contact-match",
      authorDid: "did:plc:user4"
    )

    let starterPackType = viewModel.mapReasonToNotificationType(
      starterPackNotification.reason,
      notification: starterPackNotification
    )
    XCTAssertEqual(starterPackType, NotificationType.starterpackJoined)
    XCTAssertEqual(starterPackType?.icon, "person.2.badge.plus")

    let verifiedType = viewModel.mapReasonToNotificationType(
      verifiedNotification.reason,
      notification: verifiedNotification
    )
    XCTAssertEqual(verifiedType, NotificationType.verified)
    XCTAssertEqual(verifiedType?.icon, "checkmark.seal.fill")

    let unverifiedType = viewModel.mapReasonToNotificationType(
      unverifiedNotification.reason,
      notification: unverifiedNotification
    )
    XCTAssertEqual(unverifiedType, NotificationType.unverified)
    XCTAssertEqual(unverifiedType?.icon, "xmark.seal.fill")

    let contactMatchType = viewModel.mapReasonToNotificationType(
      contactMatchNotification.reason,
      notification: contactMatchNotification
    )
    XCTAssertEqual(contactMatchType, NotificationType.contactMatch)
    XCTAssertEqual(contactMatchType?.icon, "person.crop.circle.badge.checkmark")

    let groups = await viewModel.groupNotifications(
      [starterPackNotification, verifiedNotification, unverifiedNotification, contactMatchNotification],
      pageNumber: 0
    )

    XCTAssertEqual(groups.count, 4)
    let types: [NotificationType] = groups.map { $0.type }
    XCTAssertTrue(types.contains(.starterpackJoined))
    XCTAssertTrue(types.contains(.verified))
    XCTAssertTrue(types.contains(.unverified))
    XCTAssertTrue(types.contains(.contactMatch))
  }

  func testFeedGeneratorLikeIsDerivedFromLikeReasonSubject() {
    let viewModel = NotificationsViewModel(client: nil)

    let feedgenLikeNotification = makeNotification(
      uriString: "at://did:plc:liker1/app.bsky.feed.like/like1",
      reason: "like",
      reasonSubjectString: "at://did:plc:feedauthor/app.bsky.feed.generator/bestposts"
    )

    let postLikeNotification = makeNotification(
      uriString: "at://did:plc:liker2/app.bsky.feed.like/like2",
      reason: "like",
      reasonSubjectString: "at://did:plc:postauthor/app.bsky.feed.post/post1"
    )

    let feedgenType = viewModel.mapReasonToNotificationType(
      feedgenLikeNotification.reason,
      notification: feedgenLikeNotification
    )
    XCTAssertEqual(feedgenType, NotificationType.feedgenLike)

    let postLikeType = viewModel.mapReasonToNotificationType(
      postLikeNotification.reason,
      notification: postLikeNotification
    )
    XCTAssertEqual(postLikeType, NotificationType.like)
  }

  func testSubscribedPostsBuildNewestUniqueActivityBatch() async {
    let viewModel = NotificationsViewModel(client: nil)
    let now = Date()
    let subject = "did:plc:subscribedAuthor"

    var notifications: [AppBskyNotificationListNotifications.Notification] = []

    // Generate 27 notifications inside the 48-hour window (some with duplicate URIs)
    // 0 to 26 hours ago
    for i in 1...27 {
      let postNum = i <= 25 ? i : 25 // 26 and 27 reuse post 25 URI to test deduplication
      let notification = makeNotification(
        uriString: "at://\(subject)/app.bsky.feed.post/post\(postNum)",
        cidString: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku",
        reason: "subscribed-post",
        reasonSubjectString: "at://\(subject)/app.bsky.actor.profile/self",
        authorDid: subject,
        indexedAtDate: now.addingTimeInterval(-Double(i) * 3600) // 1h, 2h, ... ago (all inside 48h)
      )
      notifications.append(notification)
    }

    // 1 notification 52 hours ago (outside 48h window)
    let outsideNotification = makeNotification(
      uriString: "at://\(subject)/app.bsky.feed.post/postOld",
      cidString: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku",
      reason: "subscribed-post",
      reasonSubjectString: "at://\(subject)/app.bsky.actor.profile/self",
      authorDid: subject,
      indexedAtDate: now.addingTimeInterval(-52 * 3600)
    )
    notifications.append(outsideNotification)

    let groups = await viewModel.groupNotifications(notifications, pageNumber: 0)

    // Should create 2 distinct groups: inside 48h and outside 48h
    XCTAssertEqual(groups.count, 2)

    guard let insideGroup = groups.first(where: { $0.notifications.count > 1 }) else {
      XCTFail("Expected inside-window grouped notification")
      return
    }

    guard let outsideGroup = groups.first(where: { $0.notifications.count == 1 }) else {
      XCTFail("Expected outside-window separate notification")
      return
    }

    XCTAssertEqual(insideGroup.type, NotificationType.activitySubscription)
    XCTAssertEqual(outsideGroup.type, NotificationType.activitySubscription)

    // Build unique post URIs, newest first, max 25
    var uniqueURIs: [ATProtocolURI] = []
    for notification in insideGroup.notifications {
      if !uniqueURIs.contains(notification.uri) {
        uniqueURIs.append(notification.uri)
        if uniqueURIs.count == 25 { break }
      }
    }

    XCTAssertEqual(uniqueURIs.count, 25)
    // Newest post should be post1
    XCTAssertEqual(uniqueURIs.first?.uriString(), "at://\(subject)/app.bsky.feed.post/post1")
    // Oldest in the 25 unique batch should be post25
    XCTAssertEqual(uniqueURIs.last?.uriString(), "at://\(subject)/app.bsky.feed.post/post25")
    // Outside window post is not in the inside group batch
    XCTAssertFalse(uniqueURIs.contains(where: { $0.uriString().contains("postOld") }))
  }
}
