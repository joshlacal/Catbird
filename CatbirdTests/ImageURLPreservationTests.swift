import CoreGraphics
import Foundation
import Nuke
import Petrel
import Testing
@testable import Catbird

private let suppliedImageURLs = [
  "https://cdn.bsky.app/img/feed_thumbnail/plain/did:plc:abcdefghijklmnopqrstuvwx/example-cid@jpeg",
  "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:abcdefghijklmnopqrstuvwx/example-cid@png",
  "https://cdn.bsky.app/img/avatar_thumbnail/plain/did:plc:abcdefghijklmnopqrstuvwx/example-cid@webp",
  "https://cdn.bsky.app/img/avatar/plain/did:plc:abcdefghijklmnopqrstuvwx/example-cid@avif",
  "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:abcdefghijklmnopqrstuvwx/example-cid@jxl",
  "https://cdn.bsky.social/img/feed_thumbnail/plain/did:plc:abcdefghijklmnopqrstuvwx/example-cid@jpeg",
  "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:abcdefghijklmnopqrstuvwx/example-cid",
  "https://cdn.bsky.app/img/feed_thumbnail/plain/did:plc:abcdefghijklmnopqrstuvwx/example-cid@jpeg?quality=80&variant=small#preview",
  "https://cdn.bsky.app/img/avatar_thumbnail/plain/did:plc:abcdefghijklmnopqrstuvwx/example%40cid@png?label=a%2Fb#face",
  "https://images.example.test/picture@jpeg?source=cdn.bsky.app#detail",
  "https://cdn.bsky.app.example.test/image@png",
  "https://images.example.test/cdn.bsky.social/image.webp"
]

@Suite("API image URL preservation")
@MainActor
struct ImageURLPreservationTests {
  @Test(arguments: suppliedImageURLs)
  func feedRequestsPreserveSuppliedURL(_ suppliedURL: String) throws {
    let url = try #require(URL(string: suppliedURL))
    let request = ImageLoadingManager.imageRequest(for: url, targetSize: CGSize(width: 80, height: 80))

    #expect(request.url?.absoluteString == suppliedURL)
    #expect(request.urlRequest?.url?.absoluteString == suppliedURL)
    #expect(request.imageId == suppliedURL)
  }

  @Test(arguments: suppliedImageURLs)
  func avatarRequestsPreserveSuppliedURL(_ suppliedURL: String) throws {
    let url = try #require(URL(string: suppliedURL))
    let request = try #require(AsyncProfileImage.resizedRequest(for: url, sizeInPoints: 40))

    #expect(request.url?.absoluteString == suppliedURL)
    #expect(request.urlRequest?.url?.absoluteString == suppliedURL)
    #expect(request.imageId == suppliedURL)
  }

  @Test func missingAvatarDoesNotCreateRequest() {
    #expect(AsyncProfileImage.resizedRequest(for: nil, sizeInPoints: 40) == nil)
  }

  @Test func avatarThumbnailVariantRetainsFormatQueryAndFragment() throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "did": "did:plc:abcdefghijklmnopqrstuvwx",
      "handle": "images.example.test",
      "avatar": "https://cdn.bsky.app/img/avatar/plain/did:plc:abcdefghijklmnopqrstuvwx/example-cid@jpeg?quality=80#face"
    ])
    let profile = try JSONDecoder().decode(AppBskyActorDefs.ProfileViewBasic.self, from: data)
    let url = try #require(profile.finalAvatarURL())
    let request = try #require(AsyncProfileImage.resizedRequest(for: url, sizeInPoints: 40))

    #expect(request.url?.absoluteString == "https://cdn.bsky.app/img/avatar_thumbnail/plain/did:plc:abcdefghijklmnopqrstuvwx/example-cid@jpeg?quality=80#face")
  }

  @Test func resizeAndPriorityRemainUnchanged() throws {
    let url = try #require(URL(string: suppliedImageURLs[0]))
    let feed = ImageLoadingManager.imageRequest(for: url, targetSize: CGSize(width: 79.6, height: 80.4))
    let feedResize = ImageProcessors.Resize(size: CGSize(width: 80, height: 80), contentMode: .aspectFill, crop: false, upscale: false)
    #expect(feed.processors.count == 1)
    #expect(feed.processors.first?.identifier == feedResize.identifier)
    #expect(feed.priority == .high)
    #expect(feed.userInfo[.thumbnailKey] == nil)
    #expect(ImageLoadingManager.imageRequest(for: url, targetSize: CGSize(width: 320, height: 320)).priority == .normal)
    #expect(ImageLoadingManager.imageRequest(for: url, targetSize: CGSize(width: 1000, height: 1000)).priority == .low)

    let avatar = try #require(AsyncProfileImage.resizedRequest(for: url, sizeInPoints: 40))
    let pixels = (40 * PlatformScreenInfo.scale).rounded(.toNearestOrAwayFromZero)
    let avatarResize = ImageProcessors.Resize(size: CGSize(width: pixels, height: pixels), unit: .pixels, contentMode: .aspectFill)
    #expect(avatar.processors.count == 1)
    #expect(avatar.processors.first?.identifier == avatarResize.identifier)
    #expect(avatar.priority == .high)
    #expect(avatar.userInfo[.thumbnailKey] == nil)
  }

  @Test(arguments: suppliedImageURLs)
  func cacheIdentityMatchesDirectURLRequest(_ suppliedURL: String) throws {
    let url = try #require(URL(string: suppliedURL))
    let pipeline = makeIsolatedPipeline()
    let feed = ImageLoadingManager.imageRequest(for: url, targetSize: CGSize(width: 80, height: 80))
    let direct = ImageRequest(url: url, processors: [
      ImageProcessors.Resize(size: CGSize(width: 80, height: 80), contentMode: .aspectFill, crop: false, upscale: false)
    ])
    let prefetch = ImageRequest(url: url)

    #expect(pipeline.cache.makeImageCacheKey(for: feed) == pipeline.cache.makeImageCacheKey(for: direct))
    #expect(pipeline.cache.makeDataCacheKey(for: feed) == pipeline.cache.makeDataCacheKey(for: direct))
    // Raw prefetch and display requests keep the same original-resource identity.
    // Resized image cache entries still include the processor and remain separate.
    #expect(feed.imageId == prefetch.imageId)
    #expect(feed.urlRequest == prefetch.urlRequest)
    #expect(pipeline.cache.makeImageCacheKey(for: feed) != pipeline.cache.makeImageCacheKey(for: prefetch))
  }

  @Test func explicitFormatsAndResolutionVariantsKeepSeparateCacheEntries() throws {
    let pipeline = makeIsolatedPipeline()
    let jpegURL = try #require(URL(string: "https://cdn.bsky.app/img/feed_thumbnail/plain/did:plc:abcdefghijklmnopqrstuvwx/example-cid@jpeg"))
    let jxlURL = try #require(URL(string: "https://cdn.bsky.app/img/feed_thumbnail/plain/did:plc:abcdefghijklmnopqrstuvwx/example-cid@jxl"))
    let fullsizeURL = try #require(URL(string: "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:abcdefghijklmnopqrstuvwx/example-cid@jpeg"))
    let size = CGSize(width: 80, height: 80)
    let jpeg = ImageLoadingManager.imageRequest(for: jpegURL, targetSize: size)
    let jxl = ImageLoadingManager.imageRequest(for: jxlURL, targetSize: size)
    let fullsize = ImageLoadingManager.imageRequest(for: fullsizeURL, targetSize: size)
    let repeated = ImageLoadingManager.imageRequest(for: jpegURL, targetSize: size)

    #expect(pipeline.cache.makeImageCacheKey(for: jpeg) != pipeline.cache.makeImageCacheKey(for: jxl))
    #expect(pipeline.cache.makeDataCacheKey(for: jpeg) != pipeline.cache.makeDataCacheKey(for: jxl))
    #expect(pipeline.cache.makeImageCacheKey(for: jpeg) != pipeline.cache.makeImageCacheKey(for: fullsize))
    #expect(pipeline.cache.makeDataCacheKey(for: jpeg) != pipeline.cache.makeDataCacheKey(for: fullsize))
    #expect(pipeline.cache.makeImageCacheKey(for: jpeg) == pipeline.cache.makeImageCacheKey(for: repeated))
    #expect(pipeline.cache.makeDataCacheKey(for: jpeg) == pipeline.cache.makeDataCacheKey(for: repeated))
  }

  private func makeIsolatedPipeline() -> ImagePipeline {
    let session = URLSessionConfiguration.ephemeral
    session.urlCache = nil
    var configuration = ImagePipeline.Configuration(dataLoader: DataLoader(configuration: session))
    configuration.imageCache = nil
    configuration.dataCache = nil
    return ImagePipeline(configuration: configuration)
  }
}
