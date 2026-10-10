import Foundation
import Petrel

public struct VideoFeedItem: Identifiable, Hashable, Sendable {
  public let id: String
  public let post: AppBskyFeedDefs.PostView
  public let videoView: AppBskyEmbedVideo.View
  public let playlistURL: URL

  /// A reveal authorizes this moderation snapshot, not every future version of
  /// the post. SwiftUI uses the same identity to recreate its warning state.
  public struct RevealIdentity: Hashable, Sendable {
    public let postID: String
    public let labels: [ComAtprotoLabelDefs.Label]
    public let selfLabelValues: [String]

    public init(
      postID: String,
      labels: [ComAtprotoLabelDefs.Label],
      selfLabelValues: [String]
    ) {
      self.postID = postID
      self.labels = labels
      self.selfLabelValues = selfLabelValues
    }
  }

  public let selfLabelValues: [String]
  public let revealIdentity: RevealIdentity

  /// The moderation this item needs: whether the feed skips it, and the merged
  /// `contentView` and `contentMedia` UI that covers the player
  /// (`screens/VideoFeed/index.tsx` upstream).
  func moderation(policy: ModerationPolicy) -> VideoFeedItemModeration {
    let presentation = PostModerationPresentation.make(post: post, policy: policy, surface: .contentView)
    return VideoFeedItemModeration(
      isFilteredFromList: presentation.isFilteredFromList,
      playback: presentation.body.merged(with: presentation.media),
      concealsCaption: presentation.concealsBody)
  }
}

struct VideoFeedItemModeration: Equatable, Sendable {
  /// `contentList` filter: the item is left out of the feed.
  let isFilteredFromList: Bool
  /// The cover's causes. While it blurs, the item must not autoplay, prewarm or play audio.
  let playback: ModerationUI
  /// A `contentView` blur covers the post body, so the caption stays hidden
  /// with the player until the viewer shows the item (upstream wraps the whole
  /// item in `Hider.Outer`). A media-only blur leaves the caption visible.
  let concealsCaption: Bool

  var concealsPlayback: Bool { playback.blur }
}

extension VideoFeedItem {

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

    let selfLabels: [String]
    if case .knownType(let record) = post.record,
       let postRecord = record as? AppBskyFeedPost,
       case .comAtprotoLabelDefsSelfLabels(let labels) = postRecord.labels {
      selfLabels = labels.values.map { $0.val.lowercased() }
    } else {
      selfLabels = []
    }
    self.selfLabelValues = selfLabels
    self.revealIdentity = RevealIdentity(
      postID: post.uri.uriString(),
      labels: post.labels ?? [],
      selfLabelValues: selfLabels
    )
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
    var indexMap = [String: Int]()
    indexMap.reserveCapacity(existing.count + feedPosts.count)
    for (index, item) in existing.enumerated() {
      indexMap[item.id] = index
    }
    var seen: Set<String> = []
    seen.reserveCapacity(feedPosts.count)
    var removedIndices: Set<Int>?

    for entry in feedPosts {
      let id = entry.post.uri.uriString()
      let replacement = VideoFeedItem(post: entry.post)
      let existingIndex = indexMap[id]
      guard existingIndex != nil || replacement != nil else { continue }
      guard seen.insert(id).inserted else { continue }
      if let index = existingIndex {
        if let replacement {
          result[index] = replacement
        } else {
          if removedIndices == nil { removedIndices = [] }
          removedIndices?.insert(index)
        }
      } else if let replacement {
        indexMap[id] = result.count
        result.append(replacement)
      }
    }

    if let removedIndices, !removedIndices.isEmpty {
      return result.enumerated().compactMap { removedIndices.contains($0.offset) ? nil : $0.element }
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
