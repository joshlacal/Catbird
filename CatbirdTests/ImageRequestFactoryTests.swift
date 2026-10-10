//
//  ImageRequestFactoryTests.swift
//  CatbirdTests
//
//  Tests for ImageRequestFactory verifying URL rewriting, nil handling,
//  and processor identity across display sizes and scales.
//

import CoreGraphics
import Foundation
import Nuke
import Testing
@testable import Catbird

@Suite("ImageRequestFactory Tests")
struct ImageRequestFactoryTests {

  // MARK: - URL Rewriting Tests

  @Test("Avatar URL rewriting converts /img/avatar/plain/ to /img/avatar_thumbnail/plain/ on cdn.bsky.app")
  func avatarURLRewritingStandard() throws {
    let sourceURL = try #require(
      URL(string: "https://cdn.bsky.app/img/avatar/plain/did:plc:abcdefghijklmnopqrstuvwx/avatar-cid@jpeg")
    )
    let request = try #require(ImageRequestFactory.avatar(sourceURL, pointSize: 40, scale: 2))

    let expectedURLString = "https://cdn.bsky.app/img/avatar_thumbnail/plain/did:plc:abcdefghijklmnopqrstuvwx/avatar-cid@jpeg"
    #expect(request.url?.absoluteString == expectedURLString)
    #expect(request.urlRequest?.url?.absoluteString == expectedURLString)
  }

  @Test("Avatar URL rewriting preserves query parameters and fragments")
  func avatarURLRewritingWithQueryAndFragment() throws {
    let sourceURL = try #require(
      URL(string: "https://cdn.bsky.app/img/avatar/plain/did:plc:abcdefghijklmnopqrstuvwx/example-cid@jpeg?quality=80&variant=small#face")
    )
    let request = try #require(ImageRequestFactory.avatar(sourceURL, pointSize: 40, scale: 3))

    let expectedURLString = "https://cdn.bsky.app/img/avatar_thumbnail/plain/did:plc:abcdefghijklmnopqrstuvwx/example-cid@jpeg?quality=80&variant=small#face"
    #expect(request.url?.absoluteString == expectedURLString)
  }

  @Test("Avatar URL already using avatar_thumbnail is not altered")
  func avatarURLAlreadyThumbnailPreserved() throws {
    let sourceURL = try #require(
      URL(string: "https://cdn.bsky.app/img/avatar_thumbnail/plain/did:plc:abcdefghijklmnopqrstuvwx/example-cid@webp")
    )
    let request = try #require(ImageRequestFactory.avatar(sourceURL, pointSize: 48, scale: 2))

    #expect(request.url?.absoluteString == sourceURL.absoluteString)
  }

  @Test("Avatar URL on non-bsky CDN host is not rewritten")
  func avatarURLNonBlueskyHostPreserved() throws {
    let hosts = [
      "https://images.example.test/img/avatar/plain/did:plc:123/cid@png",
      "https://cdn.bsky.social/img/avatar/plain/did:plc:123/cid@jpeg",
      "https://cdn.bsky.app.example.com/img/avatar/plain/did:plc:123/cid@jpeg"
    ]

    for rawURL in hosts {
      let url = try #require(URL(string: rawURL))
      let request = try #require(ImageRequestFactory.avatar(url, pointSize: 44, scale: 2))
      #expect(request.url?.absoluteString == rawURL)
    }
  }

  @Test("Non-avatar paths on cdn.bsky.app are not rewritten")
  func nonAvatarPathsPreserved() throws {
    let paths = [
      "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:123/cid@jpeg",
      "https://cdn.bsky.app/img/feed_thumbnail/plain/did:plc:123/cid@jpeg",
      "https://cdn.bsky.app/img/banner/plain/did:plc:123/cid@jpeg"
    ]

    for rawURL in paths {
      let url = try #require(URL(string: rawURL))
      let request = try #require(ImageRequestFactory.avatar(url, pointSize: 80, scale: 2))
      #expect(request.url?.absoluteString == rawURL)
    }
  }

  @Test("Generic image request preserves input URL verbatim without rewriting")
  func genericImageRequestPreservesURL() throws {
    let rawURL = "https://cdn.bsky.app/img/avatar/plain/did:plc:123/cid@jpeg"
    let url = try #require(URL(string: rawURL))
    let request = try #require(
      ImageRequestFactory.image(url, pointSize: CGSize(width: 100, height: 100), scale: 2)
    )

    #expect(request.url?.absoluteString == rawURL)
  }

  @Test("rewriteAvatarURL static helper matches avatar request behavior")
  func rewriteAvatarURLHelper() throws {
    let plain = try #require(URL(string: "https://cdn.bsky.app/img/avatar/plain/did:plc:123/cid@jpeg?q=1#head"))
    let rewritten = ImageRequestFactory.rewriteAvatarURL(plain)
    #expect(rewritten.absoluteString == "https://cdn.bsky.app/img/avatar_thumbnail/plain/did:plc:123/cid@jpeg?q=1#head")

    let optionalPlain: URL? = plain
    #expect(ImageRequestFactory.rewriteAvatarURL(optionalPlain)?.absoluteString == rewritten.absoluteString)

    let optionalNil: URL? = nil
    #expect(ImageRequestFactory.rewriteAvatarURL(optionalNil) == nil)
  }

  // MARK: - Nil Handling Tests

  @Test("Avatar with nil URL returns nil")
  func avatarWithNilURLReturnsNil() {
    let request = ImageRequestFactory.avatar(nil, pointSize: 40, scale: 3)
    #expect(request == nil)
  }

  @Test("Generic image with nil URL returns nil")
  func imageWithNilURLReturnsNil() {
    let sizeRequest = ImageRequestFactory.image(nil, pointSize: CGSize(width: 80, height: 80), scale: 2)
    #expect(sizeRequest == nil)

    let scalarRequest = ImageRequestFactory.image(nil, pointSize: 80, scale: 2)
    #expect(scalarRequest == nil)
  }

  // MARK: - Processor Identity & Cache Key Tests

  @Test("Two different point sizes yield different processor identifiers")
  func differentPointSizesYieldDifferentIdentifiers() throws {
    let url = try #require(URL(string: "https://cdn.bsky.app/img/avatar/plain/did:plc:123/cid@jpeg"))

    let request40 = try #require(ImageRequestFactory.avatar(url, pointSize: 40, scale: 2))
    let request80 = try #require(ImageRequestFactory.avatar(url, pointSize: 80, scale: 2))

    let id40 = try #require(request40.processors.first?.identifier)
    let id80 = try #require(request80.processors.first?.identifier)

    #expect(id40 != id80)
    #expect(id40.contains("s=(80.0, 80.0)"))
    #expect(id80.contains("s=(160.0, 160.0)"))
  }

  @Test("Same point size with different display scales yields different processor identifiers")
  func differentScalesYieldDifferentIdentifiers() throws {
    let url = try #require(URL(string: "https://cdn.bsky.app/img/avatar/plain/did:plc:123/cid@jpeg"))

    let request2x = try #require(ImageRequestFactory.avatar(url, pointSize: 40, scale: 2))
    let request3x = try #require(ImageRequestFactory.avatar(url, pointSize: 40, scale: 3))

    let id2x = try #require(request2x.processors.first?.identifier)
    let id3x = try #require(request3x.processors.first?.identifier)

    #expect(id2x != id3x)
    #expect(id2x.contains("s=(80.0, 80.0)"))
    #expect(id3x.contains("s=(120.0, 120.0)"))
  }

  @Test("Identical pixel dimensions yield identical processor identifiers")
  func identicalPixelSizesYieldSameIdentifier() throws {
    let url1 = try #require(URL(string: "https://cdn.bsky.app/img/avatar/plain/did:plc:1/cid1@jpeg"))
    let url2 = try #require(URL(string: "https://cdn.bsky.app/img/avatar/plain/did:plc:2/cid2@jpeg"))

    // 40pt @ 3x = 120px; 60pt @ 2x = 120px
    let requestA = try #require(ImageRequestFactory.avatar(url1, pointSize: 40, scale: 3))
    let requestB = try #require(ImageRequestFactory.avatar(url2, pointSize: 60, scale: 2))

    let idA = try #require(requestA.processors.first?.identifier)
    let idB = try #require(requestB.processors.first?.identifier)

    #expect(idA == idB)
    #expect(idA.contains("s=(120.0, 120.0)"))
  }

  @Test("Generic image request applies different processor identifiers for different sizes")
  func genericImageDifferentSizes() throws {
    let url = try #require(URL(string: "https://example.com/banner.jpg"))

    let bannerA = try #require(
      ImageRequestFactory.image(url, pointSize: CGSize(width: 300, height: 100), scale: 2)
    )
    let bannerB = try #require(
      ImageRequestFactory.image(url, pointSize: CGSize(width: 600, height: 200), scale: 2)
    )

    let idA = try #require(bannerA.processors.first?.identifier)
    let idB = try #require(bannerB.processors.first?.identifier)

    #expect(idA != idB)
    #expect(idA.contains("s=(600.0, 200.0)"))
    #expect(idB.contains("s=(1200.0, 400.0)"))
  }

  // MARK: - Processor Configuration & Defaults

  @Test("Avatar defaults: aspectFill content mode, high priority, single processor")
  func avatarDefaults() throws {
    let url = try #require(URL(string: "https://example.com/user.jpg"))
    let request = try #require(ImageRequestFactory.avatar(url, pointSize: 50, scale: 2))

    #expect(request.processors.count == 1)
    #expect(request.priority == .high)

    let id = try #require(request.processors.first?.identifier)
    #expect(id.contains("cm=.aspectFill"))
    #expect(id.contains("crop=false"))
    #expect(id.contains("upscale=false"))
  }

  @Test("Generic image defaults: aspectFit content mode, normal priority, single processor")
  func imageDefaults() throws {
    let url = try #require(URL(string: "https://example.com/photo.jpg"))
    let request = try #require(
      ImageRequestFactory.image(url, pointSize: CGSize(width: 200, height: 150), scale: 2)
    )

    #expect(request.processors.count == 1)
    #expect(request.priority == .normal)

    let id = try #require(request.processors.first?.identifier)
    #expect(id.contains("cm=.aspectFit"))
    #expect(id.contains("crop=false"))
    #expect(id.contains("upscale=false"))
  }

  @Test("Custom contentMode and priority overrides are respected")
  func customConfiguration() throws {
    let url = try #require(URL(string: "https://example.com/banner.jpg"))
    let request = try #require(
      ImageRequestFactory.image(
        url,
        pointSize: CGSize(width: 320, height: 160),
        scale: 2,
        contentMode: .aspectFill,
        priority: .veryHigh
      )
    )

    #expect(request.priority == .veryHigh)
    let id = try #require(request.processors.first?.identifier)
    #expect(id.contains("cm=.aspectFill"))
  }

  @Test("Invalid scale or pointSize clamps to minimum 1 pixel")
  func clampingEdgeCases() throws {
    let url = try #require(URL(string: "https://example.com/icon.png"))

    let zeroScale = try #require(ImageRequestFactory.avatar(url, pointSize: 40, scale: 0))
    let zeroId = try #require(zeroScale.processors.first?.identifier)
    // Scale 0 defaults to 1.0, so 40 * 1.0 = 40px
    #expect(zeroId.contains("s=(40.0, 40.0)"))

    let zeroSize = try #require(ImageRequestFactory.avatar(url, pointSize: 0, scale: 2))
    let zeroSizeId = try #require(zeroSize.processors.first?.identifier)
    // Size 0 clamps to 1 pixel
    #expect(zeroSizeId.contains("s=(1.0, 1.0)"))
  }
}
