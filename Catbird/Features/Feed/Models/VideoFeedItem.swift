import Foundation
import Petrel

public struct VideoFeedItem: Identifiable, Hashable, Sendable {
  public let id: String
  public let post: AppBskyFeedDefs.PostView
  public let videoView: AppBskyEmbedVideo.View
  public let playlistURL: URL

  init?(post: AppBskyFeedDefs.PostView) {
    let video: AppBskyEmbedVideo.View
    switch post.embed {
    case .appBskyEmbedVideoView(let value):
      video = value
    case .appBskyEmbedRecordWithMediaView(let value):
      guard case .appBskyEmbedVideoView(let embeddedVideo) = value.media else { return nil }
      video = embeddedVideo
    default:
      return nil
    }
    guard let url = video.playlist.url else { return nil }
    self.id = post.uri.uriString()
    self.post = post
    self.videoView = video
    self.playlistURL = url
  }

  /// Keep the selected snapshot first, even when it is absent from a refreshed
  /// page; post URI, rather than stream URL or array offset, defines identity.
  static func initialItems(
    startingAt post: AppBskyFeedDefs.PostView?,
    feedPosts: [AppBskyFeedDefs.FeedViewPost]
  ) -> [VideoFeedItem] {
    var result = post.flatMap { VideoFeedItem(post: $0) }.map { [$0] } ?? []
    var seen = Set(result.map(\.id))
    result.append(contentsOf: feedPosts.compactMap { VideoFeedItem(post: $0.post) }.filter {
      seen.insert($0.id).inserted
    })
    return result
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  public static func == (lhs: VideoFeedItem, rhs: VideoFeedItem) -> Bool {
    lhs.id == rhs.id
  }
}
