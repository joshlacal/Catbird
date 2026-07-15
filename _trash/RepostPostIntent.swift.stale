import AppIntents
import Petrel

@available(iOS 18.0, *)
struct RepostPostIntent: AppIntent {
  static var title: LocalizedStringResource = "Repost"
  static var description = IntentDescription("Repost a post on Bluesky.")

  @Parameter(title: "Post", requestValueDialog: "Which post would you like to repost?")
  var post: PostEntity

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let did = IntentAccountResolver.activeDID()
    let client = try await IntentClientProvider.shared.client(for: did)

    // Fetch the post to obtain its CID (required for the repost subject ref).
    let uri = try ATProtocolURI(uriString: post.id)
    let fetchOutput = try unwrapIntentResponse(
      await client.app.bsky.feed.getPosts(
        input: AppBskyFeedGetPosts.Parameters(uris: [uri])
      )
    )
    guard let postView = fetchOutput.posts.first else {
      throw IntentError.invalidParameter("Post not found: \(post.id)")
    }

    let postRef = ComAtprotoRepoStrongRef(uri: postView.uri, cid: postView.cid)
    let repost = AppBskyFeedRepost(
      subject: postRef,
      createdAt: ATProtocolDate(date: Date()),
      via: nil
    )
    let (responseCode, _) = try await client.com.atproto.repo.createRecord(
      input: ComAtprotoRepoCreateRecord.Input(
        repo: ATIdentifier(string: try client.getDid()),
        collection: try NSID(nsidString: "app.bsky.feed.repost"),
        record: ATProtocolValueContainer.knownType(repost)
      )
    )
    guard responseCode >= 200 && responseCode < 300 else {
      throw IntentError.httpError(responseCode)
    }

    return .result(dialog: "Reposted post by @\(post.authorHandle).")
  }
}
