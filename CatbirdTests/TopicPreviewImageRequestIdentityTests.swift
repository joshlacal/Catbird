import Foundation
import Nuke
import Testing
@testable import Catbird

@Suite("Trending image display request identity")
@MainActor
struct TopicPreviewImageRequestIdentityTests {
  @Test("Display resize variants at the same URL have distinct prefetch identities")
  func displayResizeVariants() throws {
    let url = try #require(URL(string: "https://cdn.example.test/shared.jpg"))
    let card = TrendingTopicImageRequests.request(url, size: CGSize(width: 62, height: 72))
    let avatar = TrendingTopicImageRequests.request(url, size: CGSize(width: 26, height: 26))
    let identity = TrendingTopicImageRequests.identity
    #expect(identity(card) != identity(avatar))
    #expect(identity(card) == identity(TrendingTopicImageRequests.request(url, size: CGSize(width: 62, height: 72))))
    var ownership = TopicPreviewImagePrefetchOwnership<ImageRequest, TrendingTopicImageRequests.Identity>()
    #expect(ownership.append([card, avatar, card], owner: .search, identity: identity).count == 2)
    #expect(ownership.remove(owner: .search, identity: identity).count == 2)
    #expect(ownership.requests.isEmpty)
  }

  @Test("Identity includes Nuke load options, decode scale, thumbnails and ordered processors")
  func nukeRequestKeyFields() throws {
    let url = try #require(URL(string: "https://cdn.example.test/shared.jpg"))
    let base = TrendingTopicImageRequests.request(url, size: CGSize(width: 62, height: 72))
    let identity = TrendingTopicImageRequests.identity
    var changed = base
    changed.priority = .high
    #expect(identity(changed) == identity(base), "Nuke's prefetcher overrides priority")
    changed = base
    changed.options = .reloadIgnoringCachedData
    #expect(identity(changed) != identity(base))
    changed = base
    changed.userInfo[.scaleKey] = NSNumber(value: 2)
    #expect(identity(changed) != identity(base))
    changed = base
    changed.userInfo[.thumbnailKey] = ImageRequest.ThumbnailOptions(maxPixelSize: 100)
    #expect(identity(changed) != identity(base))
    let avatar = TrendingTopicImageRequests.request(url, size: CGSize(width: 26, height: 26))
    changed = base
    changed.processors += avatar.processors
    var reordered = changed
    reordered.processors.reverse()
    #expect(identity(changed) != identity(reordered))
    var resource = URLRequest(url: url)
    resource.cachePolicy = .reloadIgnoringLocalCacheData
    resource.allowsCellularAccess = false
    let restricted = ImageRequest(urlRequest: resource, processors: base.processors, priority: .low)
    #expect(identity(restricted).cachePolicy == resource.cachePolicy)
    #expect(!identity(restricted).allowsCellularAccess)
    #expect(identity(restricted) != identity(base))
  }
}
