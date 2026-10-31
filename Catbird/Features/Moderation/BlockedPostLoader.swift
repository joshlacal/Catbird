import Foundation
import Petrel

/// Loads a single post from an account the viewer blocked, for a one-off reveal.
///
/// The viewer's AppView withholds posts across a block, so when it returns
/// nothing the record is read from the author's own PDS and shaped into a
/// `PostView`. Media embeds are rebuilt from their blobs through the Bluesky
/// CDN; quoted records are left out because hydrating them needs the AppView.
enum BlockedPostLoader {
  enum LoadError: Error {
    case invalidPostURI
    case recordUnavailable
    case authorUnavailable
  }

  static func load(
    uri: ATProtocolURI,
    authorDid: String,
    client: ATProtoClient,
    hydrator: BlockedAuthorHydrator?
  ) async throws -> AppBskyFeedDefs.PostView {
    let (_, hydrated) = try await client.app.bsky.feed.getPosts(
      input: AppBskyFeedGetPosts.Parameters(uris: [uri])
    )
    if let post = hydrated?.posts.first {
      return post
    }
    return try await loadFromAuthorPDS(uri: uri, authorDid: authorDid, client: client, hydrator: hydrator)
  }

  // MARK: - PDS Record

  private static func loadFromAuthorPDS(
    uri: ATProtocolURI,
    authorDid: String,
    client: ATProtoClient,
    hydrator: BlockedAuthorHydrator?
  ) async throws -> AppBskyFeedDefs.PostView {
    guard let collection = uri.collection, let rkey = uri.recordKey else {
      throw LoadError.invalidPostURI
    }

    let pdsURL = try await client.resolveDIDToPDSURL(did: authorDid)
    let pdsClient = await ATProtoClient(baseURL: pdsURL)

    let (code, output) = try await pdsClient.com.atproto.repo.getRecord(
      input: ComAtprotoRepoGetRecord.Parameters(
        repo: try ATIdentifier(string: authorDid),
        collection: try NSID(nsidString: collection),
        rkey: try RecordKey(keyString: rkey)
      )
    )
    guard code == 200, let output, let cid = output.cid,
          case let .knownType(value) = output.value,
          let record = value as? AppBskyFeedPost
    else {
      throw LoadError.recordUnavailable
    }

    let author = try await author(did: authorDid, pdsClient: pdsClient, hydrator: hydrator)

    return AppBskyFeedDefs.PostView(
      uri: uri,
      cid: cid,
      author: author,
      record: .knownType(record),
      embed: record.embed.flatMap { embedView(for: $0, did: authorDid) },
      bookmarkCount: nil,
      replyCount: nil,
      repostCount: nil,
      likeCount: nil,
      quoteCount: nil,
      indexedAt: record.createdAt,
      viewer: nil,
      labels: nil,
      threadgate: nil,
      debug: nil
    )
  }

  /// The hydrated profile when the AppView returns one, otherwise the handle
  /// the author's PDS reports for the repo.
  private static func author(
    did: String,
    pdsClient: ATProtoClient,
    hydrator: BlockedAuthorHydrator?
  ) async throws -> AppBskyActorDefs.ProfileViewBasic {
    if let profile = await hydrator?.profile(for: did) {
      return AppBskyActorDefs.ProfileViewBasic(
        did: profile.did,
        handle: profile.handle,
        displayName: profile.displayName,
        pronouns: profile.pronouns,
        avatar: profile.avatar,
        associated: profile.associated,
        viewer: profile.viewer,
        labels: profile.labels,
        createdAt: profile.createdAt,
        verification: profile.verification,
        status: profile.status,
        debug: nil
      )
    }

    let (code, repo) = try await pdsClient.com.atproto.repo.describeRepo(
      input: ComAtprotoRepoDescribeRepo.Parameters(repo: try ATIdentifier(string: did))
    )
    guard code == 200, let repo else {
      throw LoadError.authorUnavailable
    }
    return AppBskyActorDefs.ProfileViewBasic(
      did: repo.did,
      handle: repo.handle,
      displayName: nil,
      pronouns: nil,
      avatar: nil,
      associated: nil,
      viewer: nil,
      labels: nil,
      createdAt: nil,
      verification: nil,
      status: nil,
      debug: nil
    )
  }

  // MARK: - Embeds

  private static func embedView(
    for embed: AppBskyFeedPost.AppBskyFeedPostEmbedUnion,
    did: String
  ) -> AppBskyFeedDefs.PostViewEmbedUnion? {
    switch embed {
    case .appBskyEmbedImages(let images):
      return imagesView(images, did: did).map { .appBskyEmbedImagesView($0) }
    case .appBskyEmbedVideo(let video):
      return videoView(video, did: did).map { .appBskyEmbedVideoView($0) }
    case .appBskyEmbedGallery(let gallery):
      return galleryView(gallery, did: did).map { .appBskyEmbedGalleryView($0) }
    case .appBskyEmbedExternal(let external):
      return .appBskyEmbedExternalView(externalView(external, did: did))
    case .appBskyEmbedRecordWithMedia(let recordWithMedia):
      switch recordWithMedia.media {
      case .appBskyEmbedImages(let images):
        return imagesView(images, did: did).map { .appBskyEmbedImagesView($0) }
      case .appBskyEmbedVideo(let video):
        return videoView(video, did: did).map { .appBskyEmbedVideoView($0) }
      case .appBskyEmbedGallery(let gallery):
        return galleryView(gallery, did: did).map { .appBskyEmbedGalleryView($0) }
      case .appBskyEmbedExternal(let external):
        return .appBskyEmbedExternalView(externalView(external, did: did))
      case .unexpected:
        return nil
      }
    case .appBskyEmbedRecord, .unexpected:
      return nil
    }
  }

  private static func imagesView(_ images: AppBskyEmbedImages, did: String) -> AppBskyEmbedImages.View? {
    let views = images.images.compactMap { image -> AppBskyEmbedImages.ViewImage? in
      guard let thumb = cdnImageURI("feed_thumbnail", did: did, blob: image.image),
            let fullsize = cdnImageURI("feed_fullsize", did: did, blob: image.image)
      else { return nil }
      return AppBskyEmbedImages.ViewImage(
        thumb: thumb,
        fullsize: fullsize,
        alt: image.alt,
        aspectRatio: image.aspectRatio
      )
    }
    return views.isEmpty ? nil : AppBskyEmbedImages.View(images: views)
  }

  private static func galleryView(_ gallery: AppBskyEmbedGallery, did: String) -> AppBskyEmbedGallery.View? {
    let views = gallery.items.compactMap { item -> AppBskyEmbedGallery.ViewItemsUnion? in
      guard case .appBskyEmbedGalleryImage(let image) = item,
            let thumbnail = cdnImageURI("feed_thumbnail", did: did, blob: image.image),
            let fullsize = cdnImageURI("feed_fullsize", did: did, blob: image.image)
      else { return nil }
      return .appBskyEmbedGalleryViewImage(
        AppBskyEmbedGallery.ViewImage(
          thumbnail: thumbnail,
          fullsize: fullsize,
          alt: image.alt,
          aspectRatio: image.aspectRatio
        )
      )
    }
    return views.isEmpty ? nil : AppBskyEmbedGallery.View(items: views)
  }

  private static func videoView(_ video: AppBskyEmbedVideo, did: String) -> AppBskyEmbedVideo.View? {
    guard let cid = video.video.ref?.cid else { return nil }
    let encodedDid = did.replacingOccurrences(of: ":", with: "%3A")
    let base = "https://video.bsky.app/watch/\(encodedDid)/\(cid.string)"
    guard let playlist = URI("\(base)/playlist.m3u8") else { return nil }
    return AppBskyEmbedVideo.View(
      cid: cid,
      playlist: playlist,
      thumbnail: URI("\(base)/thumbnail.jpg"),
      alt: video.alt,
      aspectRatio: video.aspectRatio,
      presentation: video.presentation
    )
  }

  private static func externalView(_ external: AppBskyEmbedExternal, did: String) -> AppBskyEmbedExternal.View {
    AppBskyEmbedExternal.View(
      external: AppBskyEmbedExternal.ViewExternal(
        uri: external.external.uri,
        title: external.external.title,
        description: external.external.description,
        thumb: external.external.thumb.flatMap { cdnImageURI("feed_thumbnail", did: did, blob: $0) },
        createdAt: nil,
        updatedAt: nil,
        readingTime: nil,
        labels: nil,
        source: nil,
        associatedRefs: nil,
        associatedProfiles: nil
      )
    )
  }

  private static func cdnImageURI(_ preset: String, did: String, blob: Blob) -> URI? {
    guard let cid = blob.ref?.cid.string ?? blob.cid else { return nil }
    return URI("https://cdn.bsky.app/img/\(preset)/plain/\(did)/\(cid)@jpeg")
  }
}
