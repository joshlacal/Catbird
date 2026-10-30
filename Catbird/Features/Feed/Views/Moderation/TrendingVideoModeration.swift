import Foundation
import Petrel

/// What the trending video previews (Search's Discover section and the
/// home-feed trending interstitial) need from the engine. Mirrors the official
/// app, where `ExploreTrendingVideos` lists only posts the feed query kept and
/// `VideoPostCard` hides the thumbnail behind the merged `contentList` and
/// `contentMedia` UI; the pager a card opens adds `contentView`, so a preview
/// covers for that too and never shows what the pager would cover.
enum TrendingVideoModeration {
  /// The previews the carousel may list: a slice whose post, reply parent or
  /// root the policy filters from lists is dropped, as feeds drop it.
  static func listed(
    _ videos: [AppBskyFeedDefs.FeedViewPost], policy: ModerationPolicy
  ) -> [AppBskyFeedDefs.FeedViewPost] {
    videos.filter { ContentFilterService.listFilterSubject(of: $0, policy: policy) == nil }
  }

  /// The cover over one preview's thumbnail: the list, media and view blurs
  /// merged. While it blurs, the thumbnail is neither requested nor drawn.
  static func thumbnailUI(for post: AppBskyFeedDefs.PostView, policy: ModerationPolicy) -> ModerationUI {
    let presentation = PostModerationPresentation.make(post: post, policy: policy, surface: .contentList)
    return presentation.body
      .merged(with: presentation.media)
      .merged(with: presentation.decision.ui(.contentView))
  }

  /// The thumbnail to request for a preview, or `nil` when the post has none
  /// or the policy covers it.
  static func thumbnailURL(for post: AppBskyFeedDefs.PostView, policy: ModerationPolicy) -> URL? {
    guard !thumbnailUI(for: post, policy: policy).blur else { return nil }
    return videoThumbnailURL(in: post)
  }

  /// The video embed of a post, direct or alongside a quote.
  static func videoView(in post: AppBskyFeedDefs.PostView) -> AppBskyEmbedVideo.View? {
    switch post.embed {
    case .appBskyEmbedVideoView(let video):
      return video
    case .appBskyEmbedRecordWithMediaView(let recordWithMedia):
      if case .appBskyEmbedVideoView(let video) = recordWithMedia.media { return video }
      return nil
    default:
      return nil
    }
  }

  static func videoThumbnailURL(in post: AppBskyFeedDefs.PostView) -> URL? {
    videoView(in: post)?.thumbnail.flatMap { URL(string: $0.uriString()) }
  }

  static func videoAltText(in post: AppBskyFeedDefs.PostView) -> String? {
    videoView(in: post)?.alt
  }
}
