import AppIntents
import Petrel

@available(iOS 18.0, *)
struct LikePostIntent: AppIntent {
  static var title: LocalizedStringResource = "Like Post"
  static var description = IntentDescription("Like a post on Bluesky.")

  @Parameter(title: "Post", requestValueDialog: "Which post would you like to like?")
  var post: PostEntity

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let did = IntentAccountResolver.activeDID()
    let client = try await IntentClientProvider.shared.client(for: did)

    // Fetch the post to obtain its CID (required for the like subject ref).
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
    let like = AppBskyFeedLike(
      subject: postRef,
      createdAt: ATProtocolDate(date: Date()),
      via: nil
    )
    let (responseCode, _) = try await client.com.atproto.repo.createRecord(
      input: ComAtprotoRepoCreateRecord.Input(
        repo: ATIdentifier(string: try client.getDid()),
        collection: try NSID(nsidString: "app.bsky.feed.like"),
        record: ATProtocolValueContainer.knownType(like)
      )
    )
    guard responseCode >= 200 && responseCode < 300 else {
      throw IntentError.httpError(responseCode)
    }

    return .result(dialog: "Liked post by @\(post.authorHandle).")
  }
}
