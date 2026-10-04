import Foundation
import Petrel

public struct VideoFeedItem: Identifiable, Hashable, Sendable {
  public let id: String
  public let post: AppBskyFeedDefs.PostView
  public let videoView: AppBskyEmbedVideo.View
  public let playlistURL: URL

  /// A reveal authorizes this moderation snapshot, not every future version of
  /// the post. SwiftUI uses the same identity to recreate its warning state.
  struct RevealIdentity: Hashable {
    let postID: String
    let labels: [ComAtprotoLabelDefs.Label]
    let selfLabelValues: [String]
  }

  var selfLabelValues: [String] {
    guard case .knownType(let record) = post.record,
          let postRecord = record as? AppBskyFeedPost,
          case .comAtprotoLabelDefsSelfLabels(let labels) = postRecord.labels else { return [] }
    return labels.values.map { $0.val.lowercased() }
  }

  var revealIdentity: RevealIdentity {
    RevealIdentity(postID: id, labels: post.labels ?? [], selfLabelValues: selfLabelValues)
  }

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

  /// Keep the selected URI first, accepting its refreshed metadata when present.
  /// Retain the snapshot only while it is absent from the response.
  static func initialItems(
    startingAt post: AppBskyFeedDefs.PostView?,
    feedPosts: [AppBskyFeedDefs.FeedViewPost]
  ) -> [VideoFeedItem] {
    merging(post.flatMap { VideoFeedItem(post: $0) }.map { [$0] } ?? [], with: feedPosts)
  }

  /// Refresh overlapping posts in place, including moderation and removed media.
  static func merging(
    _ existing: [VideoFeedItem], with feedPosts: [AppBskyFeedDefs.FeedViewPost]
  ) -> [VideoFeedItem] {
    var result = existing
    var seen: Set<String> = []
    for entry in feedPosts {
      let id = entry.post.uri.uriString()
      guard !seen.contains(id) else { continue }
      let replacement = VideoFeedItem(post: entry.post)
      let existingIndex = result.firstIndex(where: { $0.id == id })
      guard existingIndex != nil || replacement != nil else { continue }
      seen.insert(id)
      if let index = existingIndex {
        if let replacement { result[index] = replacement } else { result.remove(at: index) }
      } else if let replacement {
        result.append(replacement)
      }
    }
    return result
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(post)
  }

  public static func == (lhs: VideoFeedItem, rhs: VideoFeedItem) -> Bool {
    // Page identity remains the URI; value equality must notice metadata updates.
    lhs.post == rhs.post
  }
}
