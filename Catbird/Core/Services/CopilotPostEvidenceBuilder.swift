import Foundation
import Petrel

enum CopilotPostEvidenceBuilder {
  // The normal Bluesky post record fits inside this byte limit. Media metadata and
  // quote depth have separate bounds; no image, video, article, or parent is fetched.
  static let maximumTextBytes = 3_000
  static let maximumMetadataBytes = 1_000
  static let maximumMediaCount = 4
  static let maximumQuotedPosts = 2

  static func build(_ post: AppBskyFeedDefs.PostView) -> CopilotPostEvidence {
    var builder = Builder()
    var selected = builder.post(
      uri: post.uri.uriString(), cid: post.cid.description,
      author: post.author, value: post.record
    )
    builder.seen.insert(selected.uri)
    if let embed = post.embed {
      builder.append(embed, to: &selected)
    } else {
      builder.appendUnhydratedEmbed(post.record, to: &selected)
    }
    return CopilotPostEvidence(
      selectedPost: selected, quotedPosts: builder.quotedPosts,
      coverage: [
        "Snapshot of supplied post and available quoted records only; reply parent/root identifiers are not their contents.",
        "Media contains supplied alt text and link previews only. Images, video, audio, captions and linked pages were not inspected."
      ]
    )
  }

  private struct Builder {
    var quotedPosts: [CopilotPostEvidence.Post] = []
    var seen = Set<String>()

    func post(uri: String, cid: String?, author: AppBskyActorDefs.ProfileViewBasic,
              value: ATProtocolValueContainer) -> CopilotPostEvidence.Post {
      var result = CopilotPostEvidence.Post(uri: uri, cid: cid, authorDID: author.did.didString())
      result.authorHandle = bounded(author.handle.description, bytes: 256)
      result.authorName = author.displayName.map { bounded($0, bytes: 256) }
      if result.authorHandle != author.handle.description || result.authorName != author.displayName {
        result.coverage.append("Author label truncated; author DID is preserved.")
      }
      guard case .knownType(let value) = value, let body = value as? AppBskyFeedPost else {
        result.contentStatus = .unreadable
        result.coverage.append("Post record is unreadable; do not infer its contents.")
        return result
      }
      result.text = bounded(body.text, bytes: maximumTextBytes)
      result.textTruncated = result.text != body.text
      result.replyToURI = body.reply?.parent.uri.uriString()
      result.rootURI = body.reply?.root.uri.uriString()
      return result
    }

    mutating func append(_ embed: AppBskyFeedDefs.PostViewEmbedUnion, to post: inout CopilotPostEvidence.Post) {
      switch embed {
      case .appBskyEmbedImagesView(let value): appendImages(value, to: &post)
      case .appBskyEmbedVideoView(let value): appendVideo(value, to: &post)
      case .appBskyEmbedGalleryView(let value): appendGallery(value, to: &post)
      case .appBskyEmbedExternalView(let value): appendExternal(value.external, to: &post)
      case .appBskyEmbedRecordView(let value): appendQuote(value, to: &post)
      case .appBskyEmbedRecordWithMediaView(let value):
        appendMedia(value.media, to: &post)
        appendQuote(value.record, to: &post)
      case .unexpected: post.coverage.append("Unsupported embed is unavailable.")
      }
    }

    mutating func append(_ embed: AppBskyEmbedRecord.ViewRecordEmbedsUnion, to post: inout CopilotPostEvidence.Post) {
      switch embed {
      case .appBskyEmbedImagesView(let value): appendImages(value, to: &post)
      case .appBskyEmbedVideoView(let value): appendVideo(value, to: &post)
      case .appBskyEmbedGalleryView(let value): appendGallery(value, to: &post)
      case .appBskyEmbedExternalView(let value): appendExternal(value.external, to: &post)
      case .appBskyEmbedRecordView(let value): appendQuote(value, to: &post)
      case .appBskyEmbedRecordWithMediaView(let value):
        appendMedia(value.media, to: &post)
        appendQuote(value.record, to: &post)
      case .unexpected: post.coverage.append("Unsupported quoted embed is unavailable.")
      }
    }

    func appendMedia(_ embed: AppBskyEmbedRecordWithMedia.ViewMediaUnion, to post: inout CopilotPostEvidence.Post) {
      switch embed {
      case .appBskyEmbedImagesView(let value): appendImages(value, to: &post)
      case .appBskyEmbedVideoView(let value): appendVideo(value, to: &post)
      case .appBskyEmbedGalleryView(let value): appendGallery(value, to: &post)
      case .appBskyEmbedExternalView(let value): appendExternal(value.external, to: &post)
      case .unexpected: post.coverage.append("Unsupported attached media is unavailable.")
      }
    }

    mutating func appendQuote(_ view: AppBskyEmbedRecord.View, to parent: inout CopilotPostEvidence.Post) {
      let uri: String
      let status: CopilotPostEvidence.ContentStatus
      switch view.record {
      case .appBskyEmbedRecordViewRecord(let value): uri = value.uri.uriString(); status = .available
      case .appBskyEmbedRecordViewNotFound(let value): uri = value.uri.uriString(); status = .notFound
      case .appBskyEmbedRecordViewBlocked(let value): uri = value.uri.uriString(); status = .blocked
      case .appBskyEmbedRecordViewDetached(let value): uri = value.uri.uriString(); status = .detached
      default:
        parent.coverage.append("Embedded record is not an available post; its contents are omitted.")
        return
      }
      guard parent.quotedPostURI == nil else {
        parent.coverage.append("Additional quoted record omitted.")
        return
      }
      parent.quotedPostURI = uri
      guard quotedPosts.count < maximumQuotedPosts else {
        parent.coverage.append("Further quoted post omitted at the quote limit.")
        return
      }
      guard seen.insert(uri).inserted else {
        parent.coverage.append("Repeated quoted post is already represented; recursion stopped.")
        return
      }
      guard case .appBskyEmbedRecordViewRecord(let value) = view.record else {
        quotedPosts.append(.init(uri: uri, contentStatus: status, coverage: ["Quoted contents are unavailable."]))
        return
      }
      var quoted = post(uri: uri, cid: value.cid.description, author: value.author, value: value.value)
      // Reserve its slot before traversing children, so both depth and total count are bounded.
      let slot = quotedPosts.count
      quotedPosts.append(quoted)
      if let embeds = value.embeds, !embeds.isEmpty {
        for embed in embeds.prefix(2) { append(embed, to: &quoted) }
        if embeds.count > 2 { quoted.coverage.append("Additional quoted embeds omitted.") }
      } else {
        appendUnhydratedEmbed(value.value, to: &quoted)
      }
      quotedPosts[slot] = quoted
    }

    func appendImages(_ view: AppBskyEmbedImages.View, to post: inout CopilotPostEvidence.Post) {
      for image in view.images.prefix(maximumMediaCount) {
        append(.init(kind: .image, altText: image.alt), to: &post)
      }
      if view.images.count > maximumMediaCount { post.coverage.append("Additional images omitted.") }
    }

    func appendGallery(_ view: AppBskyEmbedGallery.View, to post: inout CopilotPostEvidence.Post) {
      for item in view.items.prefix(maximumMediaCount) {
        switch item {
        case .appBskyEmbedGalleryViewImage(let image): append(.init(kind: .image, altText: image.alt), to: &post)
        case .unexpected: post.coverage.append("Unsupported gallery item is unavailable.")
        }
      }
      if view.items.count > maximumMediaCount { post.coverage.append("Additional gallery items omitted.") }
    }

    func appendVideo(_ view: AppBskyEmbedVideo.View, to post: inout CopilotPostEvidence.Post) {
      append(.init(kind: .video, altText: view.alt), to: &post)
    }

    func appendExternal(_ view: AppBskyEmbedExternal.ViewExternal, to post: inout CopilotPostEvidence.Post) {
      append(.init(kind: .externalLink, uri: view.uri.uriString(), title: view.title, description: view.description), to: &post)
    }

    func append(_ original: CopilotPostEvidence.Media, to post: inout CopilotPostEvidence.Post) {
      guard post.media.count < maximumMediaCount else {
        if !post.coverage.contains("Additional media omitted.") { post.coverage.append("Additional media omitted.") }
        return
      }
      var media = original
      media.altText = media.altText.map { bounded($0, bytes: maximumMetadataBytes) }
      media.uri = media.uri.map { bounded($0, bytes: 2_048) }
      media.title = media.title.map { bounded($0, bytes: 300) }
      media.description = media.description.map { bounded($0, bytes: maximumMetadataBytes) }
      if media.altText != original.altText { media.truncatedFields.append("altText") }
      if media.uri != original.uri { media.truncatedFields.append("uri") }
      if media.title != original.title { media.truncatedFields.append("title") }
      if media.description != original.description { media.truncatedFields.append("description") }
      post.media.append(media)
    }

    func appendUnhydratedEmbed(_ value: ATProtocolValueContainer, to post: inout CopilotPostEvidence.Post) {
      guard case .knownType(let value) = value, let body = value as? AppBskyFeedPost,
            let embed = body.embed else { return }
      switch embed {
      case .appBskyEmbedImages(let value):
        for image in value.images.prefix(maximumMediaCount) { append(.init(kind: .image, altText: image.alt), to: &post) }
        if value.images.count > maximumMediaCount { post.coverage.append("Additional images omitted.") }
      case .appBskyEmbedVideo(let value): append(.init(kind: .video, altText: value.alt), to: &post)
      case .appBskyEmbedGallery(let value):
        for item in value.items.prefix(maximumMediaCount) {
          switch item {
          case .appBskyEmbedGalleryImage(let image): append(.init(kind: .image, altText: image.alt), to: &post)
          case .unexpected: post.coverage.append("Unsupported gallery item is unavailable.")
          }
        }
        if value.items.count > maximumMediaCount { post.coverage.append("Additional gallery items omitted.") }
      case .appBskyEmbedExternal(let value):
        append(.init(kind: .externalLink, uri: value.external.uri.uriString(), title: value.external.title, description: value.external.description), to: &post)
      case .appBskyEmbedRecord(let value):
        post.quotedPostURI = value.record.uri.uriString()
        post.coverage.append("Quoted post contents were not supplied.")
      case .appBskyEmbedRecordWithMedia(let value):
        post.quotedPostURI = value.record.record.uri.uriString()
        post.coverage.append("Quoted post contents were not supplied.")
        switch value.media {
        case .appBskyEmbedImages(let images):
          for image in images.images.prefix(maximumMediaCount) { append(.init(kind: .image, altText: image.alt), to: &post) }
          if images.images.count > maximumMediaCount { post.coverage.append("Additional images omitted.") }
        case .appBskyEmbedVideo(let video): append(.init(kind: .video, altText: video.alt), to: &post)
        case .appBskyEmbedExternal(let link):
          append(.init(kind: .externalLink, uri: link.external.uri.uriString(), title: link.external.title, description: link.external.description), to: &post)
        case .appBskyEmbedGallery(let gallery):
          for item in gallery.items.prefix(maximumMediaCount) {
            if case .appBskyEmbedGalleryImage(let image) = item { append(.init(kind: .image, altText: image.alt), to: &post) }
            else { post.coverage.append("Unsupported gallery item is unavailable.") }
          }
          if gallery.items.count > maximumMediaCount { post.coverage.append("Additional gallery items omitted.") }
        case .unexpected: post.coverage.append("Unsupported attached media is unavailable.")
        }
      case .unexpected: post.coverage.append("Unsupported embed is unavailable.")
      }
    }
  }

  private static func bounded(_ value: String, bytes: Int) -> String {
    guard value.utf8.count > bytes else { return value }
    var prefix = Data(value.utf8.prefix(bytes))
    // At most three trailing bytes need removal to retain a valid UTF-8 boundary.
    while let last = prefix.last {
      if let result = String(data: prefix, encoding: .utf8) { return result }
      prefix.removeLast()
      if last < 0x80 { break }
    }
    return String(decoding: prefix, as: UTF8.self)
  }
}
