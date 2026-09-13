import Foundation
import Petrel

struct FeedDiscoveryPage {
  let feeds: [AppBskyFeedDefs.GeneratorView]
  let cursor: String?
}

@MainActor
protocol FeedDiscoveryProviding {
  func page(query: String?, cursor: String?) async throws -> FeedDiscoveryPage
}

@MainActor
struct FeedDiscoveryProvider: FeedDiscoveryProviding {
  let client: ATProtoClient

  func page(query: String?, cursor: String?) async throws -> FeedDiscoveryPage {
    let parameters = AppBskyUnspeccedGetPopularFeedGenerators.Parameters(
      limit: 20, cursor: cursor, query: query)
    let (status, output) = try await client.app.bsky.unspecced.getPopularFeedGenerators(input: parameters)
    guard status == 200, let output else {
      throw NSError(domain: "FeedDiscovery", code: status,
                    userInfo: [NSLocalizedDescriptionKey: "Feeds could not be loaded. Please try again."])
    }
    return FeedDiscoveryPage(feeds: output.feeds, cursor: output.cursor)
  }
}
