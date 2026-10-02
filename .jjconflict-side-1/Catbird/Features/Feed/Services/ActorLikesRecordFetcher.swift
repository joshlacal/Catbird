import Foundation
import Petrel

enum ActorLikesRecordFetcher {
  static func fetchLikedPosts(
    client: ATProtoClient,
    actorDID: String,
    cursor: String?,
    limit: Int = 25
  ) async throws -> (posts: [AppBskyFeedDefs.PostView], cursor: String?) {
    let pdsURL = try await client.resolveDIDToPDSURL(did: actorDID)
    let pdsClient = await ATProtoClient(baseURL: pdsURL)

    let (responseCode, recordsOutput) = try await pdsClient.com.atproto.repo.listRecords(
      input: ComAtprotoRepoListRecords.Parameters(
        repo: try ATIdentifier(string: actorDID),
        collection: try NSID(nsidString: "app.bsky.feed.like"),
        limit: limit,
        cursor: cursor,
        reverse: true
      )
    )

    guard responseCode == 200, let recordsOutput else {
      throw FeedError.requestFailed(statusCode: responseCode)
    }

    let postURIs = recordsOutput.records.compactMap { record in
      subjectURI(from: record.value)
    }

    guard !postURIs.isEmpty else {
      return ([], recordsOutput.cursor)
    }

    var hydratedPostsByURI: [String: AppBskyFeedDefs.PostView] = [:]
    for chunk in postURIs.chunked(into: 25) {
      let (_, postsOutput) = try await client.app.bsky.feed.getPosts(
        input: AppBskyFeedGetPosts.Parameters(uris: chunk)
      )

      for post in postsOutput?.posts ?? [] {
        hydratedPostsByURI[post.uri.uriString()] = post
      }
    }

    let orderedPosts = postURIs.compactMap { hydratedPostsByURI[$0.uriString()] }
    return (orderedPosts, recordsOutput.cursor)
  }

  private static func subjectURI(from value: ATProtocolValueContainer) -> ATProtocolURI? {
    if case let .knownType(record) = value,
       let like = record as? AppBskyFeedLike
    {
      return like.subject.uri
    }

    if case let .unknownType(_, wrappedValue) = value {
      return subjectURI(from: wrappedValue)
    }

    guard case let .object(record) = value,
          case let .object(subject)? = record["subject"],
          case let .string(uriString)? = subject["uri"]
    else {
      return nil
    }

    return try? ATProtocolURI(uriString: uriString)
  }
}

private extension Array {
  func chunked(into size: Int) -> [[Element]] {
    stride(from: startIndex, to: endIndex, by: size).map {
      Array(self[$0..<Swift.min($0 + size, endIndex)])
    }
  }
}
