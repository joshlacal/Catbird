import Foundation
import Petrel
import Testing

@testable import Catbird

// Fixtures for the rendering suites: a viewer, an author, posts with or
// without media or a quote, and policies built through the production
// `ModerationPolicy` initializer so builtin defaults and legacy keys apply.

enum RenderingFixtures {
  static let viewerDID = "did:web:self.test"
  static let authorDID = "did:web:bob.test"
  static let quotedAuthorDID = "did:web:carla.test"
  static let customLabelerDID = "did:web:labeler.test"
  static let blueskyModerationDID = ModerationPrefs.blueskyModerationDID

  static let postURI = "at://\(authorDID)/app.bsky.feed.post/one"
  static let quotedURI = "at://\(quotedAuthorDID)/app.bsky.feed.post/quoted"

  // MARK: Policies

  /// A confirmed policy for the viewer. `labels` sets global preferences;
  /// `labelerDIDs` subscribes labelers; `definitions` are their published definitions.
  static func policy(
    adult: Bool = true,
    labels: [String: String] = [:],
    labelerDIDs: [String] = [],
    definitions: [String: [ComAtprotoLabelDefs.LabelValueDefinition]] = [:]
  ) -> ModerationPolicy {
    ModerationPolicy(
      accountDID: viewerDID,
      serverAdultContentEnabled: adult,
      contentLabelPrefs: labels.map { ContentLabelPreference(labelerDid: nil, label: $0.key, visibility: $0.value) },
      labelerDIDs: labelerDIDs,
      labelerDefinitions: definitions,
      isConfirmed: true)
  }

  /// A policy subscribed to `labeler.test`, which publishes one `custom`
  /// definition. `labels` sets global preferences (for `custom` too) and
  /// `locales` the strings the labeler published for it.
  static func customLabelerPolicy(
    blurs: String,
    severity: String,
    adultOnly: Bool? = nil,
    adult: Bool = true,
    labels: [String: String] = [:],
    locales: [ComAtprotoLabelDefs.LabelValueDefinitionStrings] = []
  ) -> ModerationPolicy {
    policy(
      adult: adult,
      labels: labels,
      labelerDIDs: [customLabelerDID],
      definitions: [
        customLabelerDID: [
          ComAtprotoLabelDefs.LabelValueDefinition(
            identifier: "custom", severity: severity, blurs: blurs, defaultSetting: "warn", adultOnly: adultOnly,
            locales: locales)
        ]
      ])
  }

  // MARK: Labels

  static func label(_ value: String, uri: String = postURI, src: String = blueskyModerationDID) throws -> ComAtprotoLabelDefs.Label {
    ComAtprotoLabelDefs.Label(
      src: try DID(didString: src), uri: URI(uriString: uri), val: value, cts: ATProtocolDate(date: Date()))
  }

  static func accountLabel(_ value: String, did: String = authorDID, src: String = blueskyModerationDID) throws -> ComAtprotoLabelDefs.Label {
    try label(value, uri: did, src: src)
  }

  // MARK: Subjects

  static func profile(did: String = authorDID, labels: [ComAtprotoLabelDefs.Label]? = nil) throws -> AppBskyActorDefs.ProfileViewBasic {
    let name = String(did.split(separator: ":").last ?? "author").replacingOccurrences(of: ".test", with: "")
    return AppBskyActorDefs.ProfileViewBasic(
      did: try DID(didString: did), handle: try Handle(handleString: "\(name).test"),
      displayName: name.capitalized, labels: labels)
  }

  static let imageEmbed: AppBskyFeedDefs.PostViewEmbedUnion = .appBskyEmbedImagesView(
    AppBskyEmbedImages.View(images: [
      AppBskyEmbedImages.ViewImage(
        thumb: URI(uriString: "https://cdn.example.test/thumb.jpg"),
        fullsize: URI(uriString: "https://cdn.example.test/full.jpg"),
        alt: "An image")
    ]))

  static func record(text: String = "Post text", selfLabels: [String] = []) -> ATProtocolValueContainer {
    .knownType(
      AppBskyFeedPost(
        text: text, entities: nil, facets: nil, reply: nil, embed: nil, langs: nil,
        labels: selfLabels.isEmpty ? nil : .comAtprotoLabelDefsSelfLabels(.init(values: selfLabels.map { .init(val: $0) })),
        tags: nil, createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_700_000_000))))
  }

  /// A post by `bob`, optionally labeled, with media and/or a quote.
  static func post(
    uri: String = postURI,
    author: AppBskyActorDefs.ProfileViewBasic? = nil,
    labels: [ComAtprotoLabelDefs.Label]? = nil,
    selfLabels: [String] = [],
    embed: AppBskyFeedDefs.PostViewEmbedUnion? = nil,
    quote: AppBskyEmbedRecord.ViewRecord? = nil,
    quoteWithMedia: Bool = false
  ) throws -> AppBskyFeedDefs.PostView {
    var embed = embed
    if let quote {
      let view = AppBskyEmbedRecord.View(record: .appBskyEmbedRecordViewRecord(quote))
      if quoteWithMedia, case .appBskyEmbedImagesView(let images) = embed ?? imageEmbed {
        embed = .appBskyEmbedRecordWithMediaView(
          AppBskyEmbedRecordWithMedia.View(record: view, media: .appBskyEmbedImagesView(images)))
      } else {
        embed = .appBskyEmbedRecordView(view)
      }
    }
    return AppBskyFeedDefs.PostView(
      uri: try ATProtocolURI(uriString: uri),
      cid: CID.fromDAGCBOR(Data(uri.utf8)),
      author: try author ?? profile(),
      record: record(selfLabels: selfLabels),
      embed: embed,
      indexedAt: ATProtocolDate(date: Date()),
      labels: labels)
  }

  /// A quoted post by `carla`, optionally labeled, optionally carrying an image.
  static func quoted(
    labels: [ComAtprotoLabelDefs.Label]? = nil,
    authorLabels: [ComAtprotoLabelDefs.Label]? = nil,
    withImage: Bool = false
  ) throws -> AppBskyEmbedRecord.ViewRecord {
    let embeds: [AppBskyEmbedRecord.ViewRecordEmbedsUnion]? = withImage
      ? [.appBskyEmbedImagesView(AppBskyEmbedImages.View(images: []))] : nil
    return AppBskyEmbedRecord.ViewRecord(
      uri: try ATProtocolURI(uriString: quotedURI),
      cid: CID.fromDAGCBOR(Data(quotedURI.utf8)),
      author: try profile(did: quotedAuthorDID, labels: authorLabels),
      value: record(text: "Quoted text"),
      labels: labels,
      embeds: embeds,
      indexedAt: ATProtocolDate(date: Date()))
  }

  /// A reply by `bob` to `parent`, rooted at `root`.
  static func reply(
    _ post: AppBskyFeedDefs.PostView,
    parent: AppBskyFeedDefs.PostView,
    root: AppBskyFeedDefs.PostView? = nil
  ) -> AppBskyFeedDefs.FeedViewPost {
    AppBskyFeedDefs.FeedViewPost(
      post: post,
      reply: AppBskyFeedDefs.ReplyRef(
        root: .appBskyFeedDefsPostView(root ?? parent), parent: .appBskyFeedDefsPostView(parent)))
  }

  static func settings(policy: ModerationPolicy) -> FeedTunerSettings {
    var settings = FeedTunerSettings.default
    settings.moderationPolicy = policy
    return settings
  }
}
