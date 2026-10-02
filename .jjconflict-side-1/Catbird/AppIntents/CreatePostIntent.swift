//
//  CreatePostIntent.swift
//  Catbird
//
//  Publishes a Bluesky post directly from Shortcuts/Siri — unlike
//  ComposePostIntent ("Draft Post"), which only stages a draft for the
//  composer. Reuses the composer's own pipeline headlessly: PostParser for
//  facets (mentions/hashtags/links), MediaUploadManager for image blobs, and
//  PostManager for the applyWrites publish. Always asks for confirmation
//  before publishing.
//

import AppIntents
import Foundation
import Petrel

/// Pure embed-selection logic, factored out for unit testing: images+quote →
/// recordWithMedia; quote only → record; images only → images; neither → nil.
enum CreatePostEmbedBuilder {
  static func embed(
    images: [AppBskyEmbedImages.Image],
    quote: ComAtprotoRepoStrongRef?
  ) -> AppBskyFeedPost.AppBskyFeedPostEmbedUnion? {
    switch (images.isEmpty, quote) {
    case (true, nil):
      return nil
    case (true, .some(let quoteRef)):
      return .appBskyEmbedRecord(AppBskyEmbedRecord(record: quoteRef))
    case (false, nil):
      return .appBskyEmbedImages(AppBskyEmbedImages(images: images))
    case (false, .some(let quoteRef)):
      return .appBskyEmbedRecordWithMedia(
        AppBskyEmbedRecordWithMedia(
          record: AppBskyEmbedRecord(record: quoteRef),
          media: .appBskyEmbedImages(AppBskyEmbedImages(images: images))
        ))
    }
  }

  /// Distinct `@handle` candidates in the text, in appearance order,
  /// lowercased and without the leading `@`.
  static func mentionCandidates(in text: String) -> [String] {
    var handles: [String] = []
    var seen = Set<String>()
    for match in text.matches(of: /@([A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9])/) {
      let handle = String(match.1).lowercased()
      if seen.insert(handle).inserted {
        handles.append(handle)
      }
    }
    return handles
  }
}

@available(iOS 18.0, *)
struct CreatePostIntent: AppIntent {
  static let title: LocalizedStringResource = "Create Post"
  static let description = IntentDescription(
    "Publish a Bluesky post. Mentions, hashtags, and links in the text are detected automatically; optionally reply to or quote a post and attach up to 4 images."
  )

  @Parameter(title: "Account")
  var account: AccountEntity?

  @Parameter(title: "Text")
  var text: String

  @Parameter(title: "Reply To")
  var replyTo: PostEntity?

  @Parameter(title: "Quote")
  var quote: PostEntity?

  @Parameter(title: "Images", default: [], supportedContentTypes: [.image])
  var images: [IntentFile]

  @Parameter(title: "Alt Text")
  var altText: String?

  init() {}

  func perform() async throws -> some IntentResult & ReturnsValue<PostEntity?> & ProvidesDialog {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty || !images.isEmpty else {
      throw IntentError.invalidParameter("A post needs text or at least one image.")
    }
    guard images.count <= 4 else {
      throw IntentError.invalidParameter("Bluesky posts support at most 4 images.")
    }

    let did = account?.id ?? IntentAccountResolver.activeDID()
    let client = try await IntentClientProvider.shared.client(for: did)

    // Hydrate reply/quote targets: the reply path needs the full parent view
    // (PostManager derives the thread root from it) and the quote path needs
    // a fresh cid for the strongRef.
    var parentView: AppBskyFeedDefs.PostView?
    var quoteRef: ComAtprotoRepoStrongRef?
    var urisToHydrate: [String] = []
    if let replyTo { urisToHydrate.append(replyTo.id) }
    if let quote, !urisToHydrate.contains(quote.id) { urisToHydrate.append(quote.id) }
    if !urisToHydrate.isEmpty {
      let output = try unwrapIntentResponse(
        await client.app.bsky.feed.getPosts(
          input: AppBskyFeedGetPosts.Parameters(
            uris: try urisToHydrate.map { try ATProtocolURI(uriString: $0) })))
      var byURI: [String: AppBskyFeedDefs.PostView] = [:]
      for post in output.posts {
        byURI[post.uri.uriString()] = post
      }
      if let replyTo {
        guard let view = byURI[replyTo.id] else {
          throw IntentError.invalidParameter("Catbird couldn't load the post you're replying to.")
        }
        parentView = view
      }
      if let quote {
        guard let view = byURI[quote.id] else {
          throw IntentError.invalidParameter("Catbird couldn't load the post you're quoting.")
        }
        quoteRef = ComAtprotoRepoStrongRef(uri: view.uri, cid: view.cid)
      }
    }

    // Facets: resolve @mentions to profiles first (PostParser needs the DIDs),
    // then parse hashtags/mentions/links with UTF-8 byte offsets.
    let mentionProfiles = await Self.resolveMentionProfiles(
      handles: CreatePostEmbedBuilder.mentionCandidates(in: trimmedText),
      client: client
    )
    let parsed = PostParser.parsePostContent(trimmedText, resolvedProfiles: mentionProfiles)

    // Media: upload each image as a blob.
    var imageEmbeds: [AppBskyEmbedImages.Image] = []
    if !images.isEmpty {
      let uploader = MediaUploadManager(client: client)
      for (index, file) in images.enumerated() {
        let blob = try await uploader.uploadImageBlob(file.data)
        let alt = index == 0 ? (altText ?? "") : ""
        imageEmbeds.append(AppBskyEmbedImages.Image(image: blob, alt: alt, aspectRatio: nil))
      }
    }

    let embed = CreatePostEmbedBuilder.embed(images: imageEmbeds, quote: quoteRef)

    // Publishing is public and irreversible — always confirm.
    try await requestConfirmation()

    let languages = parsed.detectedLanguage.map { [LanguageCodeContainer(languageCode: $0)] } ?? []
    let postManager = PostManager(client: client)
    let postURI = try await postManager.createPost(
      parsed.text,
      languages: languages,
      hashtags: parsed.hashtags,
      facets: parsed.facets,
      parentPost: parentView,
      selfLabels: ComAtprotoLabelDefs.SelfLabels(values: []),
      embed: embed
    )

    // Best-effort hydration of the new post so Shortcuts can chain on it —
    // AppView indexing usually lands within a second, but the publish already
    // succeeded either way, so an unindexed post is nil + success dialog.
    var createdEntity: PostEntity?
    for attempt in 0..<3 {
      if attempt > 0 {
        try? await Task.sleep(for: .milliseconds(500 * attempt))
      }
      if let (code, data) = try? await client.app.bsky.feed.getPosts(
        input: AppBskyFeedGetPosts.Parameters(uris: [postURI])),
        (200..<300).contains(code),
        let view = data?.posts.first
      {
        createdEntity = PostEntity(from: view)
        break
      }
    }

    return .result(
      value: createdEntity,
      dialog: IntentDialog(
        stringLiteral: parentView == nil ? "Posted." : "Reply posted."))
  }

  /// Resolves mention handles to profiles for PostParser, keyed by lowercased
  /// handle. Best-effort: unresolvable handles simply stay plain text, the
  /// same degradation the composer applies.
  private static func resolveMentionProfiles(
    handles: [String],
    client: ATProtoClient
  ) async -> [String: AppBskyActorDefs.ProfileViewBasic] {
    guard !handles.isEmpty else { return [:] }
    let actors = handles.compactMap { try? ATIdentifier(string: $0) }
    guard !actors.isEmpty else { return [:] }

    var result: [String: AppBskyActorDefs.ProfileViewBasic] = [:]
    for start in stride(from: 0, to: actors.count, by: 25) {
      let chunk = Array(actors[start..<min(start + 25, actors.count)])
      guard
        let (code, data) = try? await client.app.bsky.actor.getProfiles(
          input: AppBskyActorGetProfiles.Parameters(actors: chunk)),
        (200..<300).contains(code),
        let profiles = data?.profiles
      else { continue }
      for profile in profiles {
        result[profile.handle.value.lowercased()] = AppBskyActorDefs.ProfileViewBasic(
          did: profile.did,
          handle: profile.handle,
          displayName: profile.displayName,
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
    }
    return result
  }
}

