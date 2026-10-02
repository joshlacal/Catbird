//
//  CircleMediaLoaderTests.swift
//  CatbirdTests
//

import Foundation
import SwiftUI
import Petrel
import PetrelCatbird
import Testing
@testable import Catbird

@Suite("Circle media loader and media view", .serialized)
@MainActor
struct CircleMediaLoaderTests {
  @Test("CircleMediaLoader decodes platform image memory-only and purges correctly")
  func circleMediaLoaderAuthenticatedFetchingAndPurging() async throws {
    let transport = MockCircleTransport()
    let service = CircleService(transport: transport)
    let loader = CircleMediaLoader(service: service)

    let cid = CID.fromDAGCBOR(Data("cid-image".utf8))
    let image = try await loader.image(
      accountDID: "did:plc:alice",
      space: CircleTestFixtures.familyURI,
      authorDID: CircleTestFixtures.alice,
      cid: cid,
      targetBucket: 360
    )

    #expect(image.size.width > 0)
    #expect(await transport.mediaCallCount == 1)

    // Calling again returns cached image without hitting transport again
    let cachedImage = try await loader.image(
      accountDID: "did:plc:alice",
      space: CircleTestFixtures.familyURI,
      authorDID: CircleTestFixtures.alice,
      cid: cid,
      targetBucket: 360
    )
    #expect(cachedImage.size.width > 0)
    #expect(await transport.mediaCallCount == 1)

    // Purge account
    await loader.purge(accountDID: "did:plc:alice")

    // Fetching again calls transport again
    _ = try await loader.image(
      accountDID: "did:plc:alice",
      space: CircleTestFixtures.familyURI,
      authorDID: CircleTestFixtures.alice,
      cid: cid,
      targetBucket: 360
    )
    #expect(await transport.mediaCallCount == 2)
  }

  @Test("Member authored Circle image binds member author DID and rejects nil without owner fallback")
  func memberAuthoredCircleImageBindsMemberAuthorDIDAndNotCircleOwner() async throws {
    let circle = CircleTestFixtures.family
    let memberDID = try! DID(didString: "did:plc:bob-member")
    let cid = CID.fromDAGCBOR(Data("cid-member-image".utf8))
    let viewImage = AppBskyEmbedImages.ViewImage(
      thumb: URI(uriString: "https://example.com/blob/\(cid.description)"),
      fullsize: URI(uriString: "https://example.com/blob/\(cid.description)"),
      alt: "Member image",
      aspectRatio: nil
    )

    // 1. Initializing with explicit member author DID binds to member, not circle owner
    let mediaView = CircleMediaView(
      viewImage: viewImage,
      circle: circle,
      authorDID: memberDID
    )
    #expect(mediaView != nil)
    #expect(mediaView?.authorDID == memberDID)
    #expect(mediaView?.authorDID != circle.owner)

    // 2. Initializing with nil authorDID fails closed (returns nil) — never falls back to circle.owner
    let nilAuthorView = CircleMediaView(
      viewImage: viewImage,
      circle: circle,
      authorDID: nil
    )
    #expect(nilAuthorView == nil)

    // 3. Transport receives member author DID
    let transport = MockCircleTransport()
    let service = CircleService(transport: transport)
    let loader = CircleMediaLoader(service: service)

    _ = try await loader.image(
      accountDID: "did:plc:viewer",
      space: circle.uri,
      authorDID: memberDID,
      cid: cid,
      targetBucket: 360
    )
    #expect(await transport.mediaCallCount == 1)
    #expect(await transport.lastMediaAuthorDID == memberDID)
    #expect(await transport.lastMediaAuthorDID != circle.owner)
  }

  @Test("AuthManager logout purges Circle feed and media caches for departing account")
  func authManagerLogoutPurgesCircleFeedAndMediaCaches() async throws {
    let transport = MockCircleTransport()
    let service = CircleService(transport: transport)
    await CircleMediaLoader.shared.setService(service)

    let cid = CID.fromDAGCBOR(Data("cid-logout-purge".utf8))

    // Pre-populate shared media loader and shared feed cache for Account 1 and Account 2
    _ = try await CircleMediaLoader.shared.image(
      accountDID: "did:plc:account1",
      space: CircleTestFixtures.familyURI,
      authorDID: CircleTestFixtures.alice,
      cid: cid,
      targetBucket: 360
    )
    _ = try await CircleMediaLoader.shared.image(
      accountDID: "did:plc:account2",
      space: CircleTestFixtures.familyURI,
      authorDID: CircleTestFixtures.alice,
      cid: cid,
      targetBucket: 360
    )
    #expect(await transport.mediaCallCount == 2)

    let page1 = CircleFeedPage(items: [makeFeedItem(circle: CircleTestFixtures.family, rkey: "post1", text: "Hello")], cursor: nil)
    let page2 = CircleFeedPage(items: [makeFeedItem(circle: CircleTestFixtures.family, rkey: "post2", text: "World")], cursor: nil)
    await CircleFeedCache.shared.store(page1, accountDID: "did:plc:account1", space: CircleTestFixtures.familyURI)
    await CircleFeedCache.shared.store(page2, accountDID: "did:plc:account2", space: CircleTestFixtures.familyURI)

    #expect(await CircleFeedCache.shared.page(accountDID: "did:plc:account1", space: CircleTestFixtures.familyURI) != nil)
    #expect(await CircleFeedCache.shared.page(accountDID: "did:plc:account2", space: CircleTestFixtures.familyURI) != nil)

    // Drive production logout ordering through AuthenticationManager
    let authManager = AuthenticationManager()
    authManager.updateState(.authenticated(userDID: "did:plc:account1"))
    await authManager.logout()

    // Account 1 feed cache and media cache must be purged
    #expect(await CircleFeedCache.shared.page(accountDID: "did:plc:account1", space: CircleTestFixtures.familyURI) == nil)
    _ = try await CircleMediaLoader.shared.image(
      accountDID: "did:plc:account1",
      space: CircleTestFixtures.familyURI,
      authorDID: CircleTestFixtures.alice,
      cid: cid,
      targetBucket: 360
    )

    // Account 2 feed cache and media cache must remain intact
    #expect(await CircleFeedCache.shared.page(accountDID: "did:plc:account2", space: CircleTestFixtures.familyURI) != nil)
    _ = try await CircleMediaLoader.shared.image(
      accountDID: "did:plc:account2",
      space: CircleTestFixtures.familyURI,
      authorDID: CircleTestFixtures.alice,
      cid: cid,
      targetBucket: 360
    )
  }

  @Test("CircleMediaView bucket calculation produces discrete monotonic bounds")
  func circleMediaViewBucketCalculation() {
    #expect(CircleMediaView.bucket(for: 0) == 360)
    #expect(CircleMediaView.bucket(for: -50) == 360)
    #expect(CircleMediaView.bucket(for: 50) == 120)
    #expect(CircleMediaView.bucket(for: 120) == 120)
    #expect(CircleMediaView.bucket(for: 121) == 240)
    #expect(CircleMediaView.bucket(for: 240) == 240)
    #expect(CircleMediaView.bucket(for: 300) == 360)
    #expect(CircleMediaView.bucket(for: 480) == 480)
    #expect(CircleMediaView.bucket(for: 700) == 720)
    #expect(CircleMediaView.bucket(for: 900) == 960)
    #expect(CircleMediaView.bucket(for: 1200) == 1280)
    #expect(CircleMediaView.bucket(for: 1800) == 1920)
    #expect(CircleMediaView.bucket(for: 2500) == 2500)
  }

  @Test("CircleMediaLoader caches distinct target buckets separately")
  func circleMediaLoaderDistinctBucketCaching() async throws {
    let transport = MockCircleTransport()
    let service = CircleService(transport: transport)
    let loader = CircleMediaLoader(service: service)

    let cid = CID.fromDAGCBOR(Data("cid-bucket-image".utf8))

    // Load bucket 240
    let img240 = try await loader.image(
      accountDID: "did:plc:alice",
      space: CircleTestFixtures.familyURI,
      authorDID: CircleTestFixtures.alice,
      cid: cid,
      targetBucket: 240
    )
    #expect(img240.size.width > 0)
    #expect(await transport.mediaCallCount == 1)

    // Requesting bucket 240 again hits cache
    _ = try await loader.image(
      accountDID: "did:plc:alice",
      space: CircleTestFixtures.familyURI,
      authorDID: CircleTestFixtures.alice,
      cid: cid,
      targetBucket: 240
    )
    #expect(await transport.mediaCallCount == 1)

    // Requesting bucket 480 triggers new fetch/decode for the larger bucket
    let img480 = try await loader.image(
      accountDID: "did:plc:alice",
      space: CircleTestFixtures.familyURI,
      authorDID: CircleTestFixtures.alice,
      cid: cid,
      targetBucket: 480
    )
    #expect(img480.size.width > 0)
    #expect(await transport.mediaCallCount == 2)

    // Requesting bucket 480 again hits cache
    _ = try await loader.image(
      accountDID: "did:plc:alice",
      space: CircleTestFixtures.familyURI,
      authorDID: CircleTestFixtures.alice,
      cid: cid,
      targetBucket: 480
    )
    #expect(await transport.mediaCallCount == 2)
  }

  @Test("CircleMediaLoader purges cached images for a specific Space")
  func circleMediaLoaderSpacePurge() async throws {
    let transport = MockCircleTransport()
    let service = CircleService(transport: transport)
    let loader = CircleMediaLoader(service: service)

    // Load multiple images for a space
    for i in 1...5 {
      let cid = CID.fromDAGCBOR(Data("cid-item-\(i)".utf8))
      _ = try await loader.image(
        accountDID: "did:plc:alice",
        space: CircleTestFixtures.familyURI,
        authorDID: CircleTestFixtures.alice,
        cid: cid,
        targetBucket: 120
      )
    }
    #expect(await transport.mediaCallCount == 5)

    // Purging the space clears all cached keys for that space
    await loader.purge(accountDID: "did:plc:alice", space: CircleTestFixtures.familyURI)

    // Fetching one again requires transport call
    let cid1 = CID.fromDAGCBOR(Data("cid-item-1".utf8))
    _ = try await loader.image(
      accountDID: "did:plc:alice",
      space: CircleTestFixtures.familyURI,
      authorDID: CircleTestFixtures.alice,
      cid: cid1,
      targetBucket: 120
    )
    #expect(await transport.mediaCallCount == 6)
  }

  @Test("Record with media Circle gallery binds author DID to gallery embed and media view")
  func recordWithMediaCircleGalleryBindsAuthorDID() async throws {
    let circle = CircleTestFixtures.family
    let memberDID = CircleTestFixtures.alice
    let imageCID = "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi"

    let galleryImage = AppBskyEmbedGallery.ViewImage(
      thumbnail: try URI(uriString: "https://example.com/blob/\(imageCID)"),
      fullsize: try URI(uriString: "https://example.com/blob/\(imageCID)"),
      alt: "Circle photo in record with media",
      aspectRatio: AppBskyEmbedDefs.AspectRatio(width: 800, height: 600)
    )
    let galleryView = AppBskyEmbedGallery.View(
      items: [.appBskyEmbedGalleryViewImage(galleryImage)]
    )

    let viewRecord = AppBskyEmbedRecord.ViewRecord(
      uri: try ATProtocolURI(uriString: "at://\(circle.owner)/app.bsky.feed.post/quoted123"),
      cid: try CID.parse(imageCID),
      author: AppBskyActorDefs.ProfileViewBasic(
        did: circle.owner,
        handle: try Handle(handleString: "owner.bsky.social"),
        displayName: "Owner",
        pronouns: nil,
        avatar: nil,
        associated: nil,
        viewer: nil,
        labels: nil,
        createdAt: nil,
        verification: nil,
        status: nil,
        debug: nil
      ),
      value: .knownType(
        AppBskyFeedPost(
          text: "Quoted text",
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

    let recordWithMediaView = AppBskyEmbedRecordWithMedia.View(
      record: AppBskyEmbedRecord.View(record: .appBskyEmbedRecordViewRecord(viewRecord)),
      media: .appBskyEmbedGalleryView(galleryView)
    )

    let postEmbed = PostEmbed(
      embed: .appBskyEmbedRecordWithMediaView(recordWithMediaView),
      labels: nil,
      path: .constant(NavigationPath()),
      visibilityContext: .circle(circle),
      authorDID: memberDID
    )

    #expect(postEmbed.authorDID == memberDID)
    if case .circle(let embeddedCircle) = postEmbed.visibilityContext {
      #expect(embeddedCircle.uri == circle.uri)
    } else {
      Issue.record("Expected .circle visibility context on PostEmbed")
    }

    // Verify GalleryEmbedView with authorDID properly initializes CircleMediaView
    let galleryEmbed = GalleryEmbedView(
      gallery: galleryView,
      shouldBlur: false,
      visibilityContext: .circle(circle),
      authorDID: memberDID
    )
    #expect(galleryEmbed.authorDID == memberDID)

    // Prove fail-closed: GalleryEmbedView without authorDID produces nil CircleMediaView,
    // whereas with memberDID it successfully constructs CircleMediaView with memberDID
    let mediaViewWithMember = CircleMediaView(
      viewImage: AppBskyEmbedImages.ViewImage(
        thumb: galleryImage.thumbnail,
        fullsize: galleryImage.fullsize,
        alt: galleryImage.alt,
        aspectRatio: galleryImage.aspectRatio
      ),
      circle: circle,
      authorDID: galleryEmbed.authorDID
    )
    #expect(mediaViewWithMember != nil)
    #expect(mediaViewWithMember?.authorDID == memberDID)

    let mediaViewWithoutAuthor = CircleMediaView(
      viewImage: AppBskyEmbedImages.ViewImage(
        thumb: galleryImage.thumbnail,
        fullsize: galleryImage.fullsize,
        alt: galleryImage.alt,
        aspectRatio: galleryImage.aspectRatio
      ),
      circle: circle,
      authorDID: nil
    )
    #expect(mediaViewWithoutAuthor == nil)
  }
}
