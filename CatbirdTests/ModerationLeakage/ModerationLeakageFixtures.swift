import Foundation
import Petrel

@testable import Catbird

// Builders for the widget, Spotlight and composer leakage suites: posts with
// media and avatars, labels from the Bluesky moderation service (trusted
// without a subscription), and a confirmed policy for the viewer.

enum LeakageFixtures {
  static let viewerDID = ModerationFixtures.selfDID
  static let bluesky = ModerationPrefs.blueskyModerationDID

  enum Media {
    case none
    case images
    case video
  }

  /// A confirmed policy for the viewer with no labeler subscriptions.
  static func policy(adult: Bool = true, prefs: [ContentLabelPreference] = []) -> ModerationPolicy {
    ModerationPolicy(
      accountDID: viewerDID, serverAdultContentEnabled: adult, contentLabelPrefs: prefs,
      labelerDIDs: [], labelerDefinitions: [:], isConfirmed: true)
  }

  static func avatarURL(_ name: String) -> String { "https://cdn.test/avatar/\(name).jpg" }
  static func imageURL(_ name: String) -> String { "https://cdn.test/image/\(name).jpg" }
  static func videoThumbnailURL(_ name: String) -> String { "https://cdn.test/video/\(name).jpg" }

  // MARK: Labels

  static func postLabel(_ value: String, on name: String, src: String = bluesky) throws -> ComAtprotoLabelDefs.Label {
    try ModerationFixtures.postLabel(value, name: name, src: src)
  }

  static func accountLabel(_ value: String, on name: String) throws -> ComAtprotoLabelDefs.Label {
    try ModerationFixtures.accountLabel(value, name: name, src: bluesky)
  }

  static func profileLabel(_ value: String, on name: String) throws -> ComAtprotoLabelDefs.Label {
    try ModerationFixtures.profileLabel(value, name: name, src: bluesky)
  }

  // MARK: Subjects

  static func author(_ name: String, labels: [ComAtprotoLabelDefs.Label]? = nil) throws -> AppBskyActorDefs.ProfileViewBasic {
    AppBskyActorDefs.ProfileViewBasic(
      did: try DID(didString: "did:web:\(name).test"), handle: try Handle(handleString: "\(name).test"),
      displayName: name.capitalized, avatar: URI(uriString: avatarURL(name)), labels: labels)
  }

  static func profile(_ name: String, labels: [ComAtprotoLabelDefs.Label]? = nil) throws -> AppBskyActorDefs.ProfileViewDetailed {
    AppBskyActorDefs.ProfileViewDetailed(
      did: try DID(didString: "did:web:\(name).test"), handle: try Handle(handleString: "\(name).test"),
      displayName: name.capitalized, avatar: URI(uriString: avatarURL(name)), labels: labels)
  }

  /// A post by `name` with `media`. Its URI matches the subject of `postLabel(_:on:)`.
  static func post(
    by name: String,
    authorLabels: [ComAtprotoLabelDefs.Label]? = nil,
    labels: [ComAtprotoLabelDefs.Label]? = nil,
    media: Media = .images,
    viewer: AppBskyFeedDefs.ViewerState? = nil
  ) throws -> AppBskyFeedDefs.PostView {
    let record = AppBskyFeedPost(
      text: "Text by \(name)", entities: nil, facets: nil, reply: nil, embed: nil, langs: nil,
      labels: nil, tags: nil, createdAt: ATProtocolDate(date: Date()))
    return AppBskyFeedDefs.PostView(
      uri: try ATProtocolURI(uriString: "at://did:web:\(name).test/app.bsky.feed.post/fake"),
      cid: CID.fromDAGCBOR(Data("post-\(name)".utf8)), author: try author(name, labels: authorLabels),
      record: .knownType(record), embed: embed(media, name: name), indexedAt: ATProtocolDate(date: Date()),
      viewer: viewer, labels: labels)
  }

  static func feedPost(_ post: AppBskyFeedDefs.PostView) -> AppBskyFeedDefs.FeedViewPost {
    AppBskyFeedDefs.FeedViewPost(post: post)
  }

  private static func embed(_ media: Media, name: String) -> AppBskyFeedDefs.PostViewEmbedUnion? {
    switch media {
    case .none:
      return nil
    case .images:
      let image = AppBskyEmbedImages.ViewImage(
        thumb: URI(uriString: imageURL(name) + "?thumb"), fullsize: URI(uriString: imageURL(name)), alt: "")
      return .appBskyEmbedImagesView(AppBskyEmbedImages.View(images: [image]))
    case .video:
      return .appBskyEmbedVideoView(
        AppBskyEmbedVideo.View(
          cid: CID.fromDAGCBOR(Data("video-\(name)".utf8)), playlist: URI(uriString: "https://cdn.test/\(name).m3u8"),
          thumbnail: URI(uriString: videoThumbnailURL(name))))
    }
  }
}
