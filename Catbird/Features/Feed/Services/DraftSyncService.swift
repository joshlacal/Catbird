//
//  DraftSyncService.swift
//  Catbird
//
//  Syncs saved composer drafts with the Bluesky AppView (app.bsky.draft.*).
//  SwiftData retains offline drafts, raw remote envelopes, recovery copies,
//  and durable deletion intent. Media references are app-install-local.
//  Sync is opt-in and never blocks a local save.
//

import Foundation
import OSLog
import Petrel
#if os(iOS)
import UIKit
#endif

// MARK: - Translation (pure, unit-testable)

/// Pure translation functions between the local PostComposerDraft shape and
/// the AppView's app.bsky.draft.defs record shape.
enum DraftSyncTranslator {

  // app.bsky.draft.defs schema limits.
  static let maxPosts = 100
  static let maxLangs = 3
  static let maxTextLength = 10_000
  static let maxDeviceNameLength = 100

  /// Whether a local draft can be represented by the remote schema.
  /// Replies, GIF-provider state and outline tags have no lossless upstream
  /// representation. Quotes require their strong reference (URI and CID).
  /// Reject oversized content instead of silently truncating an upload.
  static func isSyncable(_ draft: PostComposerDraft) -> Bool {
    guard draft.parentPostURI == nil,
          draft.pendingAudioURLString == nil,
          draft.quotedPostURI == nil || (draft.quotedPostCID.flatMap { try? CID.parse($0) } != nil),
          draft.selectedGif == nil,
          draft.outlineTags.isEmpty,
          draft.selectedLanguages.count <= maxLangs,
          draft.threadEntries.count <= maxPosts,
          draft.mediaItems.count <= 20,
          draft.threadEntries.allSatisfy({ $0.mediaItems.count <= 20 }),
          (draft.draftThreadgateAllow?.count ?? 0) <= 5,
          (draft.draftPostgateEmbeddingRules?.count ?? 0) <= 5 else { return false }
    let texts = draft.isThreadMode ? draft.threadEntries.map(\.text) : [draft.postText]
    guard texts.allSatisfy({ $0.count <= 1_000 && $0.utf8.count <= maxTextLength }) else { return false }
    let media = draft.mediaItems + draft.threadEntries.flatMap(\.mediaItems)
    let videos = ([draft.videoItem] + draft.threadEntries.map(\.videoItem)).compactMap { $0 }
    guard media.allSatisfy({ ($0.rawImageURLString.map { !$0.isEmpty && $0.utf8.count <= 1_024 } ?? false) && $0.altText.count <= 2_000 }),
          videos.allSatisfy({ item in
            (item.rawVideoURLString.map { !$0.isEmpty && $0.utf8.count <= 1_024 } ?? false) && item.altText.count <= 2_000
              && (item.caption.map { $0.content.utf8.count <= maxTextLength } ?? true)
          }) else { return false }
    return !draft.threadEntries.contains {
      $0.parentPostURI != nil || ($0.quotedPostURI != nil && $0.quotedPostCID.flatMap { try? CID.parse($0) } == nil)
        || $0.selectedGif != nil || !$0.hashtags.isEmpty
    }
  }

  static func remoteDraftHasMedia(_ draft: AppBskyDraftDefs.Draft) -> Bool {
    draft.posts.contains { post in
      if let gallery = post.embedGallery, !gallery.items.items.isEmpty { return true }
      if let images = post.embedImages, !images.isEmpty { return true }
      if let videos = post.embedVideos, !videos.isEmpty { return true }
      return false
    }
  }

  static func threadgateAllowRules(from pref: AppBskyActorDefs.PostInteractionSettingsPref?) -> [AppBskyDraftDefs.DraftThreadgateAllowUnion]? {
    guard let rules = pref?.threadgateAllowRules else { return nil }
    var result: [AppBskyDraftDefs.DraftThreadgateAllowUnion] = []
    for rule in rules {
      switch rule {
      case .appBskyFeedThreadgateMentionRule(let r):
        result.append(.appBskyFeedThreadgateMentionRule(r))
      case .appBskyFeedThreadgateFollowerRule(let r):
        result.append(.appBskyFeedThreadgateFollowerRule(r))
      case .appBskyFeedThreadgateFollowingRule(let r):
        result.append(.appBskyFeedThreadgateFollowingRule(r))
      case .appBskyFeedThreadgateListRule(let r):
        result.append(.appBskyFeedThreadgateListRule(r))
      case .unexpected(let value):
        result.append(.unexpected(value))
      }
    }
    return result
  }

  static func postgateEmbeddingRules(from pref: AppBskyActorDefs.PostInteractionSettingsPref?) -> [AppBskyDraftDefs.DraftPostgateEmbeddingRulesUnion]? {
    guard let rules = pref?.postgateEmbeddingRules else { return nil }
    var result: [AppBskyDraftDefs.DraftPostgateEmbeddingRulesUnion] = []
    for rule in rules {
      switch rule {
      case .appBskyFeedPostgateDisableRule(let r):
        result.append(.appBskyFeedPostgateDisableRule(r))
      case .unexpected(let value):
        result.append(.unexpected(value))
      }
    }
    return result
  }

  /// Translate a local draft into the remote record shape for push.
  static func remoteDraft(
    from draft: PostComposerDraft,
    deviceId: String?,
    deviceName: String?,
    postgateEmbeddingRules: [AppBskyDraftDefs.DraftPostgateEmbeddingRulesUnion]? = nil,
    threadgateAllow: [AppBskyDraftDefs.DraftThreadgateAllowUnion]? = nil
  ) -> AppBskyDraftDefs.Draft {
    let labelsUnion: AppBskyDraftDefs.DraftPostLabelsUnion?
    if draft.selectedLabels.isEmpty {
      labelsUnion = nil
    } else {
      let values = draft.selectedLabels
        .map(\.rawValue)
        .sorted()
        .map { ComAtprotoLabelDefs.SelfLabel(val: $0) }
      labelsUnion = .comAtprotoLabelDefsSelfLabels(.init(values: values))
    }

    let posts: [AppBskyDraftDefs.DraftPost]
    if draft.isThreadMode && !draft.threadEntries.isEmpty {
      posts = draft.threadEntries.map { entry in
        remotePost(
          text: entry.text,
          mediaItems: entry.mediaItems,
          videoItem: entry.videoItem,
          externalURL: entry.selectedEmbedURL,
          labels: labelsUnion,
          quoteURI: entry.quotedPostURI,
          quoteCID: entry.quotedPostCID
        )
      }
    } else {
      posts = [
        remotePost(
          text: draft.postText,
          mediaItems: draft.mediaItems,
          videoItem: draft.videoItem,
          externalURL: draft.threadEntries.first?.selectedEmbedURL,
          labels: labelsUnion,
          quoteURI: draft.quotedPostURI,
          quoteCID: draft.quotedPostCID
        )
      ]
    }

    return AppBskyDraftDefs.Draft(
      deviceId: deviceId,
      deviceName: deviceName.map { String($0.prefix(Self.maxDeviceNameLength)) },
      posts: Array(posts.prefix(Self.maxPosts)),
      langs: draft.selectedLanguages.isEmpty ? nil : Array(draft.selectedLanguages.prefix(Self.maxLangs)),
      postgateEmbeddingRules: draft.hasDraftInteractionSettings == true ? draft.draftPostgateEmbeddingRules : postgateEmbeddingRules,
      threadgateAllow: draft.hasDraftInteractionSettings == true ? draft.draftThreadgateAllow : threadgateAllow
    )
  }

  /// Translate a remote draft record into the local draft shape for pull.
  /// `includeLocalMedia` should be true only when the remote draft's deviceId
  /// matches this device — local-ref paths are meaningless on other devices.
  static func localDraft(
    from remote: AppBskyDraftDefs.Draft,
    includeLocalMedia: Bool
  ) -> PostComposerDraft {
    let entries = remote.posts.map { localEntry(from: $0, includeLocalMedia: includeLocalMedia) }
    let firstEntry = entries.first

    var labels: Set<ComAtprotoLabelDefs.LabelValue> = []
    if let labelsUnion = remote.posts.first?.labels,
       case .comAtprotoLabelDefsSelfLabels(let selfLabels) = labelsUnion {
      labels = Set(selfLabels.values.map { ComAtprotoLabelDefs.LabelValue(rawValue: $0.val) })
    }

    return PostComposerDraft(
      postText: remote.posts.first?.text ?? "",
      mediaItems: firstEntry?.mediaItems ?? [],
      videoItem: firstEntry?.videoItem,
      selectedGif: nil,
      selectedLanguages: remote.langs ?? [],
      selectedLabels: labels,
      outlineTags: [],
      threadEntries: entries,
      isThreadMode: remote.posts.count > 1,
      currentThreadIndex: 0,
      parentPostURI: nil,
      quotedPostURI: firstEntry?.quotedPostURI,
      quotedPostCID: firstEntry?.quotedPostCID,
      draftPostgateEmbeddingRules: remote.postgateEmbeddingRules,
      draftThreadgateAllow: remote.threadgateAllow,
      hasDraftInteractionSettings: true
    )
  }

  // MARK: Private helpers

  private static func remotePost(
    text: String,
    mediaItems: [CodableMediaItem],
    videoItem: CodableMediaItem?,
    externalURL: String?,
    labels: AppBskyDraftDefs.DraftPostLabelsUnion?,
    quoteURI: String?,
    quoteCID: String?
  ) -> AppBskyDraftDefs.DraftPost {
    let images = mediaItems.compactMap { item -> AppBskyDraftDefs.DraftEmbedImage? in
      guard let path = item.rawImageURLString else { return nil }
      return AppBskyDraftDefs.DraftEmbedImage(
        localRef: .init(path: path),
        alt: item.altText.isEmpty ? nil : item.altText
      )
    }

    var videos: [AppBskyDraftDefs.DraftEmbedVideo] = []
    if let videoItem, let path = videoItem.rawVideoURLString {
      let captions: [AppBskyDraftDefs.DraftEmbedCaption]?
      if let caption = videoItem.caption {
        captions = [
          AppBskyDraftDefs.DraftEmbedCaption(
            lang: caption.lang,
            content: String(caption.content.prefix(Self.maxTextLength))
          )
        ]
      } else {
        captions = nil
      }
      videos.append(
        AppBskyDraftDefs.DraftEmbedVideo(
          localRef: .init(path: path),
          alt: videoItem.altText.isEmpty ? nil : videoItem.altText,
          captions: captions
        )
      )
    }

    let externals = externalURL.map { [AppBskyDraftDefs.DraftEmbedExternal(uri: URI(uriString: $0))] }

    let gallery: AppBskyDraftDefs.DraftEmbedGallery? = images.isEmpty
      ? nil
      : .init(items: .init(items: images.map { .draftEmbedImage($0) }))

    let records: [AppBskyDraftDefs.DraftEmbedRecord]?
    if let quoteURI, let quoteCID,
       let uri = try? ATProtocolURI(uriString: quoteURI), let cid = try? CID.parse(quoteCID) {
      records = [.init(record: .init(uri: uri, cid: cid))]
    } else {
      records = nil
    }
    return AppBskyDraftDefs.DraftPost(
      text: String(text.prefix(Self.maxTextLength)),
      labels: labels,
      embedImages: nil,
      embedGallery: gallery,
      embedVideos: videos.isEmpty ? nil : videos,
      embedExternals: externals,
      embedRecords: records
    )
  }

  private static func localEntry(
    from post: AppBskyDraftDefs.DraftPost,
    includeLocalMedia: Bool
  ) -> CodableThreadEntry {
    var mediaItems: [CodableMediaItem] = []
    var videoItem: CodableMediaItem?
    if includeLocalMedia {
      var images = (post.embedGallery?.items.items ?? []).compactMap {
        item -> AppBskyDraftDefs.DraftEmbedImage? in
        if case .draftEmbedImage(let image) = item { return image }
        return nil
      }
      if images.isEmpty {
        images = post.embedImages ?? []
      }
      mediaItems = images.map { image in
        CodableMediaItem(
          altText: image.alt ?? "",
          aspectRatio: nil,
          isLoading: false,
          isAudioVisualizerVideo: false,
          rawVideoURLString: nil,
          rawImageURLString: image.localRef.path
        )
      }
      if let video = post.embedVideos?.first {
        var caption: VideoCaption? = nil
        if let remoteCaption = video.captions?.first {
          let langCode = remoteCaption.lang.lang.languageCode?.identifier ?? remoteCaption.lang.lang.minimalIdentifier
          caption = VideoCaption(
            lang: remoteCaption.lang,
            filename: "captions-\(langCode).vtt",
            content: remoteCaption.content
          )
        }
        videoItem = CodableMediaItem(
          altText: video.alt ?? "",
          aspectRatio: nil,
          isLoading: false,
          isAudioVisualizerVideo: false,
          rawVideoURLString: video.localRef.path,
          rawImageURLString: nil,
          caption: caption
        )
      }
    }

    let externalURLs = (post.embedExternals ?? []).map { $0.uri.uriString() }

    return CodableThreadEntry(
      text: post.text,
      mediaItems: mediaItems,
      videoItem: videoItem,
      selectedGif: nil,
      detectedURLs: externalURLs,
      urlCards: [:],
      selectedEmbedURL: externalURLs.first,
      urlsKeptForEmbed: [],
      hashtags: [],
      parentPostURI: nil,
      quotedPostURI: post.embedRecords?.first?.record.uri.uriString(),
      quotedPostCID: post.embedRecords?.first?.record.cid.string,
      draftEntryID: UUID()
    )
  }
}

// MARK: - Memberwise init for translation

extension CodableThreadEntry {
  init(
    text: String,
    mediaItems: [CodableMediaItem],
    videoItem: CodableMediaItem?,
    selectedGif: TenorGif?,
    detectedURLs: [String],
    urlCards: [String: URLCardResponse],
    selectedEmbedURL: String?,
    urlsKeptForEmbed: Set<String>,
    hashtags: [String],
    parentPostURI: String?,
    quotedPostURI: String?,
    quotedPostCID: String? = nil,
    draftEntryID: UUID? = nil
  ) {
    self.text = text
    self.mediaItems = mediaItems
    self.videoItem = videoItem
    self.selectedGif = selectedGif
    self.detectedURLs = detectedURLs
    self.urlCards = urlCards
    self.selectedEmbedURL = selectedEmbedURL
    self.urlsKeptForEmbed = urlsKeptForEmbed
    self.hashtags = hashtags
    self.parentPostURI = parentPostURI
    self.quotedPostURI = quotedPostURI
    self.quotedPostCID = quotedPostCID
    self.draftEntryID = draftEntryID
  }
}

// MARK: - Durable reconciliation state

/// Stored as one optional attribute on the existing model. No local draft body
/// is rewritten merely to enable synchronization.
struct DraftSyncState: Codable {
  var baselineLocal: PostComposerDraft?
  var baselineRemote: Data?
  var pendingCreate: Data?
  var pendingCreateExcludedIDs: [String]?
  var deletedAt: Date?
  var recoveryReason: String?
  var issue: String?
}

struct DraftRemoteRecord: Sendable {
  let id: String
  let payload: Data
  let createdAt: Date
  let updatedAt: Date

  var draft: AppBskyDraftDefs.Draft {
    get throws { try JSONDecoder().decode(AppBskyDraftDefs.Draft.self, from: payload) }
  }
}

struct DraftRemotePage: Sendable {
  let records: [DraftRemoteRecord]
  let cursor: String?
}

/// An envelope around the lexicon object, not a replacement generated model.
/// Preserve unknown object properties and optional fields the typed decoder
/// cannot understand. Only fields changed in the local projection are patched.
enum DraftWireEnvelope {
  static func canonical(_ data: Data) throws -> Data {
    try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: [.sortedKeys])
  }

  static func encode(_ draft: AppBskyDraftDefs.Draft) throws -> Data {
    try canonical(JSONEncoder().encode(draft))
  }

  static func applyingChanges(original: Data, before: Data, after: Data, postOrder: [Int?]? = nil) throws -> Data {
    let originalValue = try JSONSerialization.jsonObject(with: original)
    let beforeValue = try JSONSerialization.jsonObject(with: before)
    let afterValue = try JSONSerialization.jsonObject(with: after)
    var patched = patch(original: originalValue, before: beforeValue, after: afterValue)
    if let order = postOrder,
       let source = (originalValue as? [String: Any])?["posts"] as? [Any],
       let old = (beforeValue as? [String: Any])?["posts"] as? [Any],
       let new = (afterValue as? [String: Any])?["posts"] as? [Any],
       order.count == new.count, var object = patched as? [String: Any] {
      object["posts"] = new.indices.map { index -> Any in
        guard let previous = order[index], source.indices.contains(previous), old.indices.contains(previous) else { return new[index] }
        return patch(original: source[previous], before: old[previous], after: new[index])
      }
      patched = object
    }
    return try JSONSerialization.data(withJSONObject: patched, options: [.sortedKeys])
  }

  private static func patch(original: Any, before: Any, after: Any) -> Any {
    if let before = before as? NSDictionary, let after = after as? NSDictionary,
       let original = original as? [String: Any] {
      var source = original
      let oldGallery = before["embedGallery"]
      let newGallery = after["embedGallery"]
      let galleryChanged = oldGallery.map { old in newGallery.map { !equal(old, $0) } ?? true } ?? (newGallery != nil)
      if galleryChanged, let legacy = original["embedImages"] as? [[String: Any]] {
        // The composer writes gallery form, but older clients used embedImages.
        // Normalize only when editing media; unchanged foreign fields remain raw.
        if source["embedGallery"] == nil, var gallery = oldGallery as? [String: Any] {
          gallery["items"] = legacy.map { image in
            var item = image
            item["$type"] = item["$type"] ?? "app.bsky.draft.defs#draftEmbedImage"
            return item
          }
          source["embedGallery"] = gallery
        }
        source.removeValue(forKey: "embedImages")
      }
      var output = source
      for key in Set(before.allKeys.compactMap { $0 as? String } + after.allKeys.compactMap { $0 as? String }) {
        let old = before[key]
        let new = after[key]
        if let old, let new {
          if !equal(old, new) { output[key] = patch(original: source[key] ?? old, before: old, after: new) }
        } else if let new {
          output[key] = new
        } else {
          output.removeValue(forKey: key)
        }
      }
      return output
    }
    if let old = before as? [Any], let new = after as? [Any], let source = original as? [Any] {
      let oldRefs = old.compactMap(mediaReference)
      let newRefs = new.compactMap(mediaReference)
      let sourceRefs = source.compactMap(mediaReference)
      if !oldRefs.isEmpty || !newRefs.isEmpty {
        // Media arrays may shrink, grow or reorder. Only an unambiguous same
        // localRef inherits the original item's unknown metadata. Duplicated
        // references or a replacement never inherit an arbitrary old image.
        guard oldRefs.count == old.count, newRefs.count == new.count,
              sourceRefs.count == source.count, sourceRefs == oldRefs,
              Set(oldRefs).count == oldRefs.count,
              Set(newRefs).count == newRefs.count else {
          return equal(before, after) ? original : after
        }
        return new.indices.map { index -> Any in
          guard let previous = oldRefs.firstIndex(of: newRefs[index]) else { return new[index] }
          return patch(original: source[previous], before: old[previous], after: new[index])
        }
      }
      if old.count == new.count, source.count == old.count {
        return new.indices.map { patch(original: source[$0], before: old[$0], after: new[$0]) }
      }
    }
    return equal(before, after) ? original : after
  }

  private static func mediaReference(_ value: Any) -> String? {
    ((value as? [String: Any])?["localRef"] as? [String: Any])?["path"] as? String
  }

  private static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
    (lhs as? NSObject)?.isEqual(rhs) == true
  }
}

enum DraftSyncFailure: LocalizedError {
  case accountChanged, incompleteListing, http(Int), malformedResponse
  var errorDescription: String? {
    switch self {
    case .accountChanged: return "Draft sync paused because the account changed."
    case .incompleteListing: return "Bluesky’s draft list could not be read completely. Your drafts are safe on this device."
    case .http: return "Bluesky could not sync drafts. Your drafts are safe on this device. Pull to retry."
    case .malformedResponse: return "Bluesky returned a draft response that could not be read. Your local drafts are unchanged."
    }
  }
}

@MainActor
protocol DraftSyncTransport {
  func list(cursor: String?) async throws -> DraftRemotePage
  func create(payload: Data) async throws -> String
  func update(id: String, payload: Data) async throws
  func delete(id: String) async throws
  func interactionDefaults() async throws -> AppBskyActorDefs.PostInteractionSettingsPref?
}

extension DraftSyncTransport {
  func interactionDefaults() async throws -> AppBskyActorDefs.PostInteractionSettingsPref? { nil }
}

/// Captures both DID and credential generation. Petrel's exact request scope
/// fails closed on account changes, including A → B → A, and disables unsafe
/// replay under a different identity. Each operation performs exactly one XRPC.
@MainActor
private final class AppViewDraftTransport: DraftSyncTransport {
  let client: ATProtoClient
  let identity: AuthContinuitySnapshot

  init(client: ATProtoClient, identity: AuthContinuitySnapshot) {
    self.client = client
    self.identity = identity
  }

  private func request(_ method: String, body: Data? = nil, cursor: String? = nil) async throws -> Data {
    let client = self.client
    let endpoint = method.contains(".") ? method : "app.bsky.draft." + method
    let result = try await client.performGeneratedRequestWithExactAuthContinuity(matching: identity) {
      let network = await client.networkService
      let query = method == "getDrafts"
        ? [URLQueryItem(name: "limit", value: "100")] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        : nil
      let request = try await network.createURLRequest(
        endpoint: endpoint, method: body == nil ? "GET" : "POST",
        headers: ["Accept": "application/json"], body: body, queryItems: query
      )
      let service = await network.getServiceDID(for: endpoint)
      let (data, response) = try await network.performRequestReturningHTTPErrorResponses(
        request, skipTokenRefresh: false, additionalHeaders: service.map { ["atproto-proxy": $0] }
      )
      guard (200...299).contains(response.statusCode) else { throw DraftSyncFailure.http(response.statusCode) }
      return data
    }
    guard case .performed(let data) = result else { throw DraftSyncFailure.accountChanged }
    return data
  }

  func list(cursor: String?) async throws -> DraftRemotePage {
    let data = try await request("getDrafts", cursor: cursor)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let drafts = object["drafts"] as? [[String: Any]] else { throw DraftSyncFailure.malformedResponse }
    let records = try drafts.map { object -> DraftRemoteRecord in
      // Validate required fields through the canonical generated schema while
      // retaining the original raw draft object alongside it.
      let data = try JSONSerialization.data(withJSONObject: object)
      let view = try JSONDecoder().decode(AppBskyDraftDefs.DraftView.self, from: data)
      guard let raw = object["draft"] as? [String: Any] else { throw DraftSyncFailure.malformedResponse }
      return DraftRemoteRecord(
        id: view.id.toString(), payload: try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
        createdAt: view.createdAt.date, updatedAt: view.updatedAt.date
      )
    }
    if let cursor = object["cursor"], !(cursor is String), !(cursor is NSNull) {
      throw DraftSyncFailure.malformedResponse
    }
    return DraftRemotePage(records: records, cursor: object["cursor"] as? String)
  }

  func interactionDefaults() async throws -> AppBskyActorDefs.PostInteractionSettingsPref? {
    let data = try await request("app.bsky.actor.getPreferences")
    let output = try JSONDecoder().decode(AppBskyActorGetPreferences.Output.self, from: data)
    for pref in output.preferences.items {
      if case .postInteractionSettingsPref(let value) = pref { return value }
    }
    return nil
  }

  func create(payload: Data) async throws -> String {
    let body = try JSONSerialization.data(withJSONObject: ["draft": JSONSerialization.jsonObject(with: payload)])
    let response = try await request("createDraft", body: body)
    return try JSONDecoder().decode(AppBskyDraftCreateDraft.Output.self, from: response).id.toString()
  }

  func update(id: String, payload: Data) async throws {
    _ = try TID(tidString: id)
    let body = try JSONSerialization.data(withJSONObject: ["draft": ["id": id, "draft": JSONSerialization.jsonObject(with: payload)]])
    _ = try await request("updateDraft", body: body)
  }

  func delete(id: String) async throws {
    _ = try TID(tidString: id)
    _ = try await request("deleteDraft", body: JSONSerialization.data(withJSONObject: ["id": id]))
  }
}

// MARK: - Sync Service

@MainActor
final class DraftSyncService {
  private let persistence: DraftPersistence
  private let clientProvider: @MainActor () -> ATProtoClient?
  private let accountProvider: @MainActor () -> String?
  private let enabledProvider: @MainActor () -> Bool
  private let transportProvider: (@MainActor (String) async throws -> any DraftSyncTransport)?
  private var pushTasks: [UUID: Task<Void, Never>] = [:]
  private var syncingAccounts: Set<String> = []
  private var needsAnotherPass: Set<String> = []
  private var cancellationGeneration = UUID()
  private var activeGenerations: [String: UUID] = [:]
  private(set) var lastIssue: String?

  init(
    persistence: DraftPersistence,
    clientProvider: @escaping @MainActor () -> ATProtoClient?,
    accountProvider: @escaping @MainActor () -> String?,
    enabledProvider: @escaping @MainActor () -> Bool = { ExperimentalSettings.shared.draftSyncEnabled },
    transportProvider: (@MainActor (String) async throws -> any DraftSyncTransport)? = nil
  ) {
    self.persistence = persistence
    self.clientProvider = clientProvider
    self.accountProvider = accountProvider
    self.enabledProvider = enabledProvider
    self.transportProvider = transportProvider
  }

  var isEnabled: Bool { enabledProvider() }

  static var deviceId: String {
    let key = "blue.catbird.draftSync.deviceId"
    if let existing = UserDefaults.standard.string(forKey: key) { return existing }
    let value = UUID().uuidString
    UserDefaults.standard.set(value, forKey: key)
    return value
  }

  static var deviceName: String {
    #if os(iOS)
    UIDevice.current.name
    #elseif os(macOS)
    Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    #else
    ProcessInfo.processInfo.hostName
    #endif
  }

  func cancelPendingWork() {
    cancellationGeneration = UUID()
    for task in pushTasks.values { task.cancel() }
    pushTasks.removeAll()
    lastIssue = nil
  }

  func schedulePush(draftId: UUID, accountDID: String) {
    guard isEnabled else { return }
    pushTasks[draftId]?.cancel()
    pushTasks[draftId] = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
      guard let self, self.accountProvider() == accountDID else { return }
      self.pushTasks[draftId] = nil
      await self.syncDrafts(accountDID: accountDID)
    }
  }

  func scheduleWorkingDraftPush(draftId: UUID, draft: PostComposerDraft, accountDID: String) {
    // Saving the restored draft is local-first even when sync is disabled.
    pushTasks[draftId]?.cancel()
    pushTasks[draftId] = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
      guard let self, self.accountProvider() == accountDID else { return }
      self.pushTasks[draftId] = nil
      do {
        try await self.persistence.updateDraft(id: draftId, draft: draft, accountDID: accountDID)
        await self.syncDrafts(accountDID: accountDID)
      } catch { self.lastIssue = error.localizedDescription }
    }
  }

  func pushDraft(id: UUID, accountDID: String) async {
    await syncDrafts(accountDID: accountDID)
  }

  private func checkAccount(_ account: String) throws {
    try Task.checkCancellation()
    guard isEnabled, accountProvider() == account,
          activeGenerations[account] == cancellationGeneration else { throw DraftSyncFailure.accountChanged }
  }

  private func transport(for account: String) async throws -> any DraftSyncTransport {
    if let transportProvider { return try await transportProvider(account) }
    guard let client = clientProvider() else { throw DraftSyncFailure.accountChanged }
    let identity = await client.authContinuitySnapshot()
    guard identity.did == account else { throw DraftSyncFailure.accountChanged }
    try checkAccount(account)
    return AppViewDraftTransport(client: client, identity: identity)
  }

  /// No mutations follow a partial/failed listing. Cursor cycles and duplicate
  /// IDs with differing content are incomplete snapshots, never deletion proof.
  static func readAll(_ transport: any DraftSyncTransport) async throws -> [String: DraftRemoteRecord] {
    var records: [String: DraftRemoteRecord] = [:]
    var cursor: String?
    var seenCursors: Set<String> = []
    while true {
      try Task.checkCancellation()
      let page = try await transport.list(cursor: cursor)
      for record in page.records {
        if let old = records[record.id], old.payload != record.payload { throw DraftSyncFailure.incompleteListing }
        records[record.id] = record
      }
      if page.cursor == nil { return records }
      guard let next = page.cursor, seenCursors.insert(next).inserted else { throw DraftSyncFailure.incompleteListing }
      cursor = next
      // Bound a malicious or nonterminating service; do not reconcile the prefix.
      guard seenCursors.count < 1_000 else { throw DraftSyncFailure.incompleteListing }
    }
  }

  func syncDrafts(accountDID: String) async {
    guard isEnabled, accountProvider() == accountDID else { return }
    guard syncingAccounts.insert(accountDID).inserted else {
      needsAnotherPass.insert(accountDID)
      return
    }
    activeGenerations[accountDID] = cancellationGeneration
    defer {
      syncingAccounts.remove(accountDID)
      activeGenerations.removeValue(forKey: accountDID)
      if needsAnotherPass.remove(accountDID) != nil, isEnabled, accountProvider() == accountDID {
        Task { [weak self] in await self?.syncDrafts(accountDID: accountDID) }
      }
    }
    do {
      repeat {
        needsAnotherPass.remove(accountDID)
        let transport = try await transport(for: accountDID)
        var remotes = try await Self.readAll(transport)
        let knownRemoteIDs = Set(remotes.keys)
        try checkAccount(accountDID)
        let unconfirmedIDs = try resolvePendingCreates(remotes, accountDID: accountDID)
        let ownedIDs = Set(try persistence.allDrafts(for: accountDID).compactMap(\.remoteId))
        // Materialize downloaded drafts before any upload/delete can fail, so
        // an offline local write never prevents access to existing remote work.
        for remote in remotes.values where !ownedIDs.contains(remote.id) && !unconfirmedIDs.contains(remote.id) {
          try importRemote(remote, account: accountDID)
        }
        // Re-fetch after the network suspension so edits and tombstones made
        // while listing are included in this reconciliation.
        for local in try persistence.allDrafts(for: accountDID) {
          try checkAccount(accountDID)
          var state = try persistence.syncState(for: local)
          if state.pendingCreate != nil { continue }
          if state.deletedAt != nil {
            if let remoteId = local.remoteId, remotes.removeValue(forKey: remoteId) != nil {
              try await transport.delete(id: remoteId)
              try checkAccount(accountDID)
            }
            continue
          }
          if let remoteId = local.remoteId {
            if let remote = remotes.removeValue(forKey: remoteId) {
              try await reconcile(local, state: state, remote: remote, transport: transport, account: accountDID)
            } else {
              // Listing is not a transactional snapshot (including timestamp
              // cursor ties). Keep this row recoverable and never recreate it.
              state.recoveryReason = "No longer available on Bluesky. This device’s copy was kept."
              try persistence.saveSyncState(state, for: local)
            }
          } else if state.recoveryReason == nil {
            try await create(local, state: state, transport: transport, account: accountDID, knownRemoteIDs: knownRemoteIDs)
          }
        }
        lastIssue = nil
      } while needsAnotherPass.contains(accountDID)
    } catch is CancellationError {
      // Local content and durable operations remain available for the next run.
    } catch {
      if accountProvider() == accountDID { lastIssue = error.localizedDescription }
    }
  }

  private func resolvePendingCreates(_ remotes: [String: DraftRemoteRecord], accountDID: String) throws -> Set<String> {
    var unconfirmed: Set<String> = []
    for local in try persistence.allDrafts(for: accountDID) {
      var state = try persistence.syncState(for: local)
          if let pending = state.pendingCreate, local.remoteId == nil {
            let allLocals = try persistence.allDrafts(for: accountDID)
            let claimed = Set(allLocals.compactMap(\.remoteId))
            let excluded = state.pendingCreateExcludedIDs.map(Set.init)
            let ambiguousSibling = try allLocals.contains { other in
              guard other.id != local.id, other.remoteId == nil else { return false }
              return try persistence.syncState(for: other).pendingCreate == pending
            }
            let matches = remotes.values.filter {
              $0.payload == pending && !claimed.contains($0.id) && excluded?.contains($0.id) == false
            }
            if matches.count == 1, !ambiguousSibling, let match = matches.first {
              local.remoteId = match.id
              state.pendingCreate = nil
              state.pendingCreateExcludedIDs = nil
              state.baselineRemote = pending
              try persistence.saveSyncState(state, for: local)
            } else {
              state.issue = "A previous save could not be confirmed. Refresh before saving another copy."
              try persistence.saveSyncState(state, for: local)
              unconfirmed.formUnion(matches.map(\.id))
            }
          }
    }
    return unconfirmed
  }

  private func projected(_ draft: PostComposerDraft) throws -> Data {
    try DraftWireEnvelope.encode(DraftSyncTranslator.remoteDraft(
      from: draft, deviceId: Self.deviceId, deviceName: Self.deviceName
    ))
  }

  private func create(_ local: DraftPost, state initial: DraftSyncState, transport: any DraftSyncTransport, account: String, knownRemoteIDs: Set<String>) async throws {
    var draft = try local.decodeDraft()
    var state = initial
    guard DraftSyncTranslator.isSyncable(draft) else {
      state.issue = "Kept on this device: this draft uses content Bluesky’s draft format cannot represent."
      try persistence.saveSyncState(state, for: local)
      return
    }
    if draft.hasDraftInteractionSettings != true {
      let preferences = try await transport.interactionDefaults()
      try checkAccount(account)
      guard try local.decodeDraft() == draft, try persistence.syncState(for: local).deletedAt == nil else {
        needsAnotherPass.insert(account)
        return
      }
      draft.draftThreadgateAllow = DraftSyncTranslator.threadgateAllowRules(from: preferences)
      draft.draftPostgateEmbeddingRules = DraftSyncTranslator.postgateEmbeddingRules(from: preferences)
      draft.hasDraftInteractionSettings = true
      try local.apply(draft)
    }
    let payload = try projected(draft)
    state.pendingCreate = payload
    state.pendingCreateExcludedIDs = Array(knownRemoteIDs)
    state.baselineLocal = draft
    try persistence.saveSyncState(state, for: local)
    do {
      let id = try await transport.create(payload: payload)
      try checkAccount(account)
      // A concurrent edit/deletion may have changed metadata during the request.
      state = try persistence.syncState(for: local)
      local.remoteId = id
      state.pendingCreate = nil
      state.pendingCreateExcludedIDs = nil
      state.baselineLocal = draft
      state.baselineRemote = payload
      state.issue = nil
      local.lastSyncedAt = Date()
      try persistence.saveSyncState(state, for: local)
      if state.deletedAt != nil { needsAnotherPass.insert(account) }
    } catch {
      // A response lost after server commit is ambiguous. Retain the sent bytes
      // so the next complete pull can recover the identity without duplicating.
      if case DraftSyncFailure.http(let status) = error, (400..<500).contains(status) {
        state = try persistence.syncState(for: local)
        state.pendingCreate = nil
        state.pendingCreateExcludedIDs = nil
        try persistence.saveSyncState(state, for: local)
      }
      throw error
    }
  }

  private func reconcile(_ local: DraftPost, state initial: DraftSyncState, remote: DraftRemoteRecord, transport: any DraftSyncTransport, account: String) async throws {
    let draft = try local.decodeDraft()
    var state = initial
    let localChanged = state.baselineLocal.map { $0 != draft } ?? true
    let remoteChanged = state.baselineRemote != remote.payload
    if remoteChanged {
      if localChanged {
        try persistence.preserveRecoveryCopy(of: local, reason: "Another app changed this draft. Your previous version was kept here.")
      }
      try applyRemote(remote, to: local)
      return
    }
    guard localChanged else {
      if state.recoveryReason != nil {
        state.recoveryReason = nil
        try persistence.saveSyncState(state, for: local)
      }
      return
    }
    guard DraftSyncTranslator.isSyncable(draft), let baseline = state.baselineLocal else {
      state.issue = "Changes are saved on this device. This draft contains content that cannot be synced safely."
      try persistence.saveSyncState(state, for: local)
      return
    }
    // A changed post count can reorder fields the local composer cannot
    // represent. Keep the edit locally instead of dropping those fields.
    let before = try projected(baseline)
    let after = try projected(draft)
    let originalObject = try JSONSerialization.jsonObject(with: remote.payload) as? [String: Any]
    let beforeObject = try JSONSerialization.jsonObject(with: before) as? [String: Any]
    let originalPosts = originalObject?["posts"] as? NSArray
    let beforePosts = beforeObject?["posts"] as? NSArray
    let remoteDraft = try remote.draft
    let changesUnavailableMedia = Self.wouldReplaceUnavailableMedia(remote: remoteDraft, baseline: baseline, edited: draft)
    let oldIDs = baseline.threadEntries.compactMap(\.draftEntryID)
    let newIDs = draft.threadEntries.compactMap(\.draftEntryID)
    let hasStableOrder = baseline.isThreadMode && draft.isThreadMode
      && oldIDs.count == baseline.threadEntries.count && newIDs.count == draft.threadEntries.count
      && Set(oldIDs).count == oldIDs.count && Set(newIDs).count == newIDs.count
    let postOrder: [Int?]? = hasStableOrder ? newIDs.map { oldIDs.firstIndex(of: $0) } : nil
    let oldPosts = try JSONDecoder().decode(AppBskyDraftDefs.Draft.self, from: before).posts
    let newPosts = try JSONDecoder().decode(AppBskyDraftDefs.Draft.self, from: after).posts
    let ambiguousReorder = !hasStableOrder && oldPosts.count > 1 && newPosts.enumerated().contains { index, post in
      oldPosts.firstIndex(of: post).map { $0 != index } ?? false
    }
    if changesUnavailableMedia || (originalPosts != beforePosts && !hasStableOrder
      && (draft.threadEntries.count != baseline.threadEntries.count || ambiguousReorder)) {
      state.issue = "These changes need a new draft because some original content belongs to another app. Your edit is saved on this device."
      try persistence.saveSyncState(state, for: local)
      return
    }
    let payload = try DraftWireEnvelope.applyingChanges(original: remote.payload, before: before, after: after, postOrder: postOrder)
    // The protocol has no compare-and-swap token. Re-read immediately before
    // replacement and retain conflicts, while acknowledging that a server-side
    // edit between this check and update cannot be atomically excluded.
    let current = try await Self.readAll(transport)[remote.id]
    try checkAccount(account)
    guard try local.decodeDraft() == draft, try persistence.syncState(for: local).deletedAt == nil else {
      needsAnotherPass.insert(account)
      return
    }
    state = try persistence.syncState(for: local)
    guard let current else {
      state.recoveryReason = "No longer available on Bluesky. This device’s copy was kept."
      try persistence.saveSyncState(state, for: local)
      return
    }
    guard current.payload == remote.payload else {
      try persistence.preserveRecoveryCopy(of: local, reason: "Another app changed this draft. Your previous version was kept here.")
      try applyRemote(current, to: local)
      return
    }
    try await transport.update(id: remote.id, payload: payload)
    try checkAccount(account)
    state = try persistence.syncState(for: local)
    state.baselineLocal = draft
    state.baselineRemote = payload
    state.issue = nil
    state.recoveryReason = nil
    local.lastSyncedAt = Date()
    try persistence.saveSyncState(state, for: local)
    if state.deletedAt != nil { needsAnotherPass.insert(account) }
  }

  static func wouldReplaceUnavailableMedia(
    remote: AppBskyDraftDefs.Draft,
    baseline: PostComposerDraft,
    edited: PostComposerDraft
  ) -> Bool {
    !canRestoreMedia(remote) && DraftSyncTranslator.remoteDraftHasMedia(remote)
      && (edited.mediaItems != baseline.mediaItems || edited.videoItem != baseline.videoItem
        || edited.threadEntries.map(\.mediaItems) != baseline.threadEntries.map(\.mediaItems)
        || edited.threadEntries.map(\.videoItem) != baseline.threadEntries.map(\.videoItem))
  }

  /// Never interpret another app's local references as readable file URLs.
  /// Even our own install ID requires managed media paths that still exist.
  static func canRestoreMedia(_ draft: AppBskyDraftDefs.Draft) -> Bool {
    guard draft.deviceId == Self.deviceId else { return false }
    let sharedDirectory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.blue.catbird.shared")?
      .appendingPathComponent("SharedDrafts", isDirectory: true)
    let roots = [sharedDirectory, FileManager.default.temporaryDirectory].compactMap { $0?.resolvingSymlinksInPath().standardizedFileURL.path }
    let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "mov", "mp4", "m4v"]
    var paths: [String] = []
    for post in draft.posts {
      paths += (post.embedImages ?? []).map { $0.localRef.path }
      paths += (post.embedVideos ?? []).map { $0.localRef.path }
      for item in post.embedGallery?.items.items ?? [] {
        guard case .draftEmbedImage(let image) = item else { return false }
        paths.append(image.localRef.path)
      }
    }
    return paths.allSatisfy { path in
      guard let url = URL(string: path), url.isFileURL,
            extensions.contains(url.pathExtension.lowercased()) else { return false }
      let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
      return roots.contains { resolved.hasPrefix($0 + "/") }
        && FileManager.default.fileExists(atPath: resolved)
    }
  }

  private func applyRemote(_ remote: DraftRemoteRecord, to local: DraftPost) throws {
    let remoteDraft = try remote.draft
    let mediaIncluded = Self.canRestoreMedia(remoteDraft)
    let draft = DraftSyncTranslator.localDraft(from: remoteDraft, includeLocalMedia: mediaIncluded)
    try local.apply(draft)
    local.modifiedDate = remote.updatedAt
    local.lastSyncedAt = Date()
    local.remoteMediaDeviceName = !mediaIncluded && DraftSyncTranslator.remoteDraftHasMedia(remoteDraft)
      ? (remoteDraft.deviceName ?? "another app or device") : nil
    var state = try persistence.syncState(for: local)
    state.baselineLocal = draft
    state.baselineRemote = remote.payload
    state.recoveryReason = nil
    state.issue = nil
    try persistence.saveSyncState(state, for: local)
  }

  private func importRemote(_ remote: DraftRemoteRecord, account: String) throws {
    let remoteDraft = try remote.draft
    let draft = DraftSyncTranslator.localDraft(from: remoteDraft, includeLocalMedia: Self.canRestoreMedia(remoteDraft))
    let id = try persistence.insertRemoteDraft(
      draft, accountDID: account, remoteId: remote.id,
      createdDate: remote.createdAt, modifiedDate: remote.updatedAt, syncedAt: Date()
    )
    guard let local = try persistence.fetchDraftModel(id: id) else { throw DraftError.draftNotFound }
    try applyRemote(remote, to: local)
  }
}
