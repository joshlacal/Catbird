import Foundation
import Petrel

/// A post staged for sharing into a Bluesky conversation. Set by the share
/// picker, consumed once by `ConversationView` when the target convo opens.
struct PendingChatShare {
  let convoId: String
  /// Strong ref sent as the `app.bsky.embed.record` message embed.
  let postRef: ComAtprotoRepoStrongRef
  /// Preview rendered in the composer's staged-post strip.
  let previewEmbed: ChatSharedPostPreview

  static func makePreviewEmbed(from post: AppBskyFeedDefs.PostView) -> ChatSharedPostPreview {
    let postText: String
    if case .knownType(let record) = post.record,
       let feedPost = record as? AppBskyFeedPost {
      postText = feedPost.text
    } else {
      postText = ""
    }

    return ChatSharedPostPreview(
      authorDisplayName: post.author.displayName,
      authorHandle: post.author.handle.description,
      text: postText
    )
  }
}
