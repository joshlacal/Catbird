import CatbirdMLSCore
import Foundation
import Petrel

/// A post staged for sharing into a Bluesky conversation. Set by the share
/// picker, consumed once by `ConversationView` when the target convo opens.
struct PendingChatShare {
  let convoId: String
  /// Strong ref sent as the `app.bsky.embed.record` message embed.
  let postRef: ComAtprotoRepoStrongRef
  /// Rich preview rendered in the composer's embed strip (reuses the MLS
  /// composer's post-card preview; nothing MLS is sent on the wire).
  let previewEmbed: MLSEmbedData

  static func makePreviewEmbed(from post: AppBskyFeedDefs.PostView) -> MLSEmbedData {
    let postText: String
    if case .knownType(let record) = post.record,
       let feedPost = record as? AppBskyFeedPost {
      postText = feedPost.text
    } else {
      postText = ""
    }

    var images: [MLSPostImage]?
    if let embed = post.embed {
      switch embed {
      case .appBskyEmbedImagesView(let imagesView):
        let mapped = imagesView.images.compactMap { imageView -> MLSPostImage? in
          guard let fullsize = imageView.fullsize.url, let thumb = imageView.thumb.url else {
            return nil
          }
          return MLSPostImage(thumb: thumb, fullsize: fullsize, alt: imageView.alt)
        }
        images = mapped.isEmpty ? nil : mapped
      case .appBskyEmbedGalleryView(let galleryView):
        let mapped = galleryView.items.compactMap { item -> MLSPostImage? in
          guard case .appBskyEmbedGalleryViewImage(let image) = item,
                let fullsize = image.fullsize.url, let thumb = image.thumbnail.url else {
            return nil
          }
          return MLSPostImage(thumb: thumb, fullsize: fullsize, alt: image.alt)
        }
        images = mapped.isEmpty ? nil : mapped
      default:
        break
      }
    }

    return .post(
      MLSPostEmbed(
        uri: post.uri.uriString(),
        cid: post.cid.string,
        authorDid: post.author.did.didString(),
        authorHandle: post.author.handle.description,
        authorDisplayName: post.author.displayName,
        authorAvatar: post.author.finalAvatarURL(),
        text: postText,
        createdAt: post.indexedAt.date,
        likeCount: post.likeCount,
        replyCount: post.replyCount,
        repostCount: post.repostCount,
        images: images
      ))
  }
}
