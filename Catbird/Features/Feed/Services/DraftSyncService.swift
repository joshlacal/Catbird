//
//  DraftSyncService.swift
//  Catbird
//
//  Syncs saved composer drafts with the Bluesky AppView (app.bsky.draft.*).
//  SwiftData stays the source of truth and offline cache; the AppView copy
//  carries text/structure only — media is referenced via device-local paths
//  (DraftEmbedLocalRef) and never leaves the device.
//
//  All network sync is gated behind ExperimentalSettings.draftSyncEnabled
//  (default OFF) and all failures are logged silently — local saves are
//  never blocked by sync errors.
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
  /// Replies and quotes have no representation in app.bsky.draft.defs#draft
  /// (no reply ref; embedRecords requires a CID the draft doesn't carry),
  /// so they remain local-only.
  static func isSyncable(_ draft: PostComposerDraft) -> Bool {
    guard draft.parentPostURI == nil, draft.quotedPostURI == nil else { return false }
    return !draft.threadEntries.contains { $0.parentPostURI != nil || $0.quotedPostURI != nil }
  }

  static func remoteDraftHasMedia(_ draft: AppBskyDraftDefs.Draft) -> Bool {
    draft.posts.contains { post in
      if let gallery = post.embedGallery, !gallery.items.items.isEmpty { return true }
      if let images = post.embedImages, !images.isEmpty { return true }
      if let videos = post.embedVideos, !videos.isEmpty { return true }
      return false
    }
  }

  /// Translate a local draft into the remote record shape for push.
  static func remoteDraft(
    from draft: PostComposerDraft,
    deviceId: String?,
    deviceName: String?
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
          labels: labelsUnion
        )
      }
    } else {
      posts = [
        remotePost(
          text: draft.postText,
          mediaItems: draft.mediaItems,
          videoItem: draft.videoItem,
          externalURL: draft.threadEntries.first?.selectedEmbedURL,
          labels: labelsUnion
        )
      ]
    }

    return AppBskyDraftDefs.Draft(
      deviceId: deviceId,
      deviceName: deviceName.map { String($0.prefix(Self.maxDeviceNameLength)) },
      posts: Array(posts.prefix(Self.maxPosts)),
      langs: draft.selectedLanguages.isEmpty ? nil : Array(draft.selectedLanguages.prefix(Self.maxLangs)),
      postgateEmbeddingRules: nil,
      threadgateAllow: nil
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
      quotedPostURI: nil
    )
  }

  // MARK: Private helpers

  private static func remotePost(
    text: String,
    mediaItems: [CodableMediaItem],
    videoItem: CodableMediaItem?,
    externalURL: String?,
    labels: AppBskyDraftDefs.DraftPostLabelsUnion?
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
      videos.append(
        AppBskyDraftDefs.DraftEmbedVideo(
          localRef: .init(path: path),
          alt: videoItem.altText.isEmpty ? nil : videoItem.altText,
          captions: nil
        )
      )
    }

    let externals = externalURL.map { [AppBskyDraftDefs.DraftEmbedExternal(uri: URI(uriString: $0))] }

    let gallery: AppBskyDraftDefs.DraftEmbedGallery? = images.isEmpty
      ? nil
      : .init(items: .init(items: images.map { .draftEmbedImage($0) }))

    return AppBskyDraftDefs.DraftPost(
      text: String(text.prefix(Self.maxTextLength)),
      labels: labels,
      embedImages: nil,
      embedGallery: gallery,
      embedVideos: videos.isEmpty ? nil : videos,
      embedExternals: externals,
      embedRecords: nil
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
        videoItem = CodableMediaItem(
          altText: video.alt ?? "",
          aspectRatio: nil,
          isLoading: false,
          isAudioVisualizerVideo: false,
          rawVideoURLString: video.localRef.path,
          rawImageURLString: nil
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
      quotedPostURI: nil
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
    quotedPostURI: String?
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
  }
}

// MARK: - Sync Service

/// Pushes local saved drafts to the AppView and pulls remote drafts down,
/// merging with last-write-wins semantics keyed on updatedAt/modifiedDate.
@MainActor
final class DraftSyncService {
  private let logger = Logger(subsystem: "blue.catbird", category: "DraftSyncService")
  private let persistence: DraftPersistence
  private let clientProvider: @MainActor () -> ATProtoClient?

  /// Debounce for push-after-save; mirrors the composer autosave debounce
  /// (ComposerDraftManager.persistDebounceInterval, 500ms).
  private let pushDebounce: Duration = .milliseconds(500)

  /// Allowance for client/server clock skew when deciding whether the remote
  /// copy changed since our last push.
  private static let clockSkewTolerance: TimeInterval = 30

  /// Page size for getDrafts pagination
  private static let pullPageLimit = 50

  /// Safety cap on total remote drafts pulled in one sync
  private static let pullMaxDrafts = 500

  private var pushTasks: [UUID: Task<Void, Never>] = [:]
  private var isSyncing = false

  init(
    persistence: DraftPersistence,
    clientProvider: @escaping @MainActor () -> ATProtoClient?
  ) {
    self.persistence = persistence
    self.clientProvider = clientProvider
  }

  /// Feature gate — all network sync is dark unless explicitly enabled.
  var isEnabled: Bool {
    ExperimentalSettings.shared.draftSyncEnabled
  }

  // MARK: - Device identity

  /// Stable per-install device ID used for DraftEmbedLocalRef scoping
  static var deviceId: String {
    let key = "blue.catbird.draftSync.deviceId"
    if let existing = UserDefaults.standard.string(forKey: key) {
      return existing
    }
    let newId = UUID().uuidString
    UserDefaults.standard.set(newId, forKey: key)
    return newId
  }

  static var deviceName: String {
    #if os(iOS)
    return UIDevice.current.name
    #elseif os(macOS)
    return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    #else
    return ProcessInfo.processInfo.hostName
    #endif
  }

  // MARK: - Push

  /// Debounced push of a saved draft after a local save/update.
  func schedulePush(draftId: UUID, accountDID: String) {
    guard isEnabled else { return }
    pushTasks[draftId]?.cancel()
    pushTasks[draftId] = Task { [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(for: self.pushDebounce)
      } catch {
        return
      }
      self.pushTasks[draftId] = nil
      await self.pushDraft(id: draftId, accountDID: accountDID)
    }
  }

  /// Debounced write-through of the in-memory working draft for a restored
  /// saved draft: updates the SwiftData row, then pushes it.
  func scheduleWorkingDraftPush(draftId: UUID, draft: PostComposerDraft, accountDID: String) {
    guard isEnabled else { return }
    pushTasks[draftId]?.cancel()
    pushTasks[draftId] = Task { [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(for: self.pushDebounce)
      } catch {
        return
      }
      self.pushTasks[draftId] = nil
      do {
        try await self.persistence.updateDraft(id: draftId, draft: draft, accountDID: accountDID)
      } catch {
        self.logger.debug("Working draft write-through skipped for \(draftId.uuidString): \(error.localizedDescription)")
        return
      }
      await self.pushDraft(id: draftId, accountDID: accountDID)
    }
  }

  /// Push a single saved draft to the AppView (createDraft on first sync,
  /// updateDraft afterwards). Errors are logged, never surfaced.
  func pushDraft(id: UUID, accountDID: String) async {
    guard isEnabled else { return }
    guard let client = clientProvider() else {
      logger.debug("Draft push skipped - no client available")
      return
    }

    do {
      guard let model = try persistence.fetchDraftModel(id: id), model.accountDID == accountDID else {
        logger.debug("Draft push skipped - draft \(id.uuidString) not found for account")
        return
      }
      let draft = try model.decodeDraft()
      guard DraftSyncTranslator.isSyncable(draft) else {
        logger.debug("Draft push skipped - \(id.uuidString) is not representable remotely (reply/quote)")
        return
      }

      let remote = DraftSyncTranslator.remoteDraft(
        from: draft,
        deviceId: Self.deviceId,
        deviceName: Self.deviceName
      )

      if let remoteId = model.remoteId {
        let tid = try TID(tidString: remoteId)
        let status = try await client.app.bsky.draft.updateDraft(
          input: .init(draft: .init(id: tid, draft: remote))
        )
        guard (200...299).contains(status) else {
          logger.warning("Draft update push failed - \(id.uuidString), status: \(status)")
          return
        }
        try persistence.markSynced(id: id, remoteId: remoteId, at: Date())
        logger.info("⬆️ Updated remote draft \(remoteId) for \(id.uuidString)")
      } else {
        let (status, data) = try await client.app.bsky.draft.createDraft(
          input: .init(draft: remote)
        )
        guard (200...299).contains(status), let newRemoteId = data?.id else {
          logger.warning("Draft create push failed - \(id.uuidString), status: \(status)")
          return
        }
        try persistence.markSynced(id: id, remoteId: newRemoteId, at: Date())
        logger.info("⬆️ Created remote draft \(newRemoteId) for \(id.uuidString)")
      }
    } catch {
      logger.error("Draft push failed for \(id.uuidString): \(error.localizedDescription)")
    }
  }

  // MARK: - Delete

  /// Propagate a local deletion to the AppView. Best effort — if it fails the
  /// remote copy will be re-materialized on the next pull.
  func deleteRemoteDraft(remoteId: String) async {
    guard isEnabled else { return }
    guard let client = clientProvider() else { return }
    do {
      let tid = try TID(tidString: remoteId)
      let status = try await client.app.bsky.draft.deleteDraft(input: .init(id: tid))
      if (200...299).contains(status) {
        logger.info("🗑️ Deleted remote draft \(remoteId)")
      } else {
        logger.warning("Remote draft delete failed - \(remoteId), status: \(status)")
      }
    } catch {
      logger.error("Remote draft delete failed for \(remoteId): \(error.localizedDescription)")
    }
  }

  // MARK: - Pull + merge

  /// Full two-way sync for an account: one-time migration of pre-existing
  /// local drafts, then pull remote drafts and merge last-write-wins.
  func syncDrafts(accountDID: String) async {
    guard isEnabled else { return }
    guard !isSyncing else {
      logger.debug("Draft sync already in progress - skipping")
      return
    }
    guard let client = clientProvider() else {
      logger.debug("Draft sync skipped - no client available")
      return
    }
    isSyncing = true
    defer { isSyncing = false }

    await migrateLocalDraftsIfNeeded(accountDID: accountDID)

    // The service may return a cursor on its final page. Stop on an empty or
    // non-advancing page rather than spinning to the safety cap.
    var remoteViews: [AppBskyDraftDefs.DraftView] = []
    var cursor: String?
    do {
      repeat {
        let (status, data) = try await client.app.bsky.draft.getDrafts(
          input: .init(limit: Self.pullPageLimit, cursor: cursor)
        )
        guard (200...299).contains(status), let data else {
          logger.warning("Draft pull failed - status: \(status)")
          return
        }
        remoteViews.append(contentsOf: data.drafts)
        let nextCursor = data.cursor
        guard !data.drafts.isEmpty, let nextCursor, nextCursor != cursor else { break }
        cursor = nextCursor
      } while remoteViews.count < Self.pullMaxDrafts
    } catch {
      logger.error("Draft pull failed: \(error.localizedDescription)")
      return
    }

    logger.info("⬇️ Pulled \(remoteViews.count) remote drafts for merge")

    do {
      let locals = try persistence.fetchDrafts(for: accountDID)
      var remoteById: [String: AppBskyDraftDefs.DraftView] = [:]
      for view in remoteViews {
        remoteById[view.id.toString()] = view
      }

      for local in locals {
        if let remoteId = local.remoteId {
          if let remote = remoteById.removeValue(forKey: remoteId) {
            try await merge(local: local, remote: remote, accountDID: accountDID)
          } else if local.lastSyncedAt != nil {
            // Synced before but gone remotely — deletion propagates down
            try persistence.deleteDraftLocally(id: local.id)
          }
        } else {
          // Local-only draft — push up
          await pushDraft(id: local.id, accountDID: accountDID)
        }
      }

      // Remote-only drafts — materialize locally
      for (remoteId, remote) in remoteById {
        let includeMedia = remote.draft.deviceId == Self.deviceId
        let translated = DraftSyncTranslator.localDraft(from: remote.draft, includeLocalMedia: includeMedia)
        try persistence.insertRemoteDraft(
          translated,
          accountDID: accountDID,
          remoteId: remoteId,
          createdDate: remote.createdAt.date,
          modifiedDate: remote.updatedAt.date,
          syncedAt: Date(),
          remoteMediaDeviceName: Self.unrestorableMediaDeviceName(
            for: remote.draft,
            mediaIncluded: includeMedia
          )
        )
      }

      logger.info("✅ Draft sync complete for account \(accountDID)")
    } catch {
      logger.error("Draft merge failed: \(error.localizedDescription)")
    }
  }

  /// Last-write-wins merge of one local/remote draft pair.
  private func merge(
    local: DraftPost,
    remote: AppBskyDraftDefs.DraftView,
    accountDID: String
  ) async throws {
    let remoteUpdated = remote.updatedAt.date
    let lastSynced = local.lastSyncedAt ?? .distantPast

    let localDirty = local.lastSyncedAt == nil || local.modifiedDate > lastSynced
    let remoteDirty = remoteUpdated.timeIntervalSince(lastSynced) > Self.clockSkewTolerance

    switch (localDirty, remoteDirty) {
    case (false, false):
      return
    case (true, false):
      await pushDraft(id: local.id, accountDID: accountDID)
    case (false, true):
      try applyRemote(remote, to: local)
    case (true, true):
      if remoteUpdated > local.modifiedDate {
        try applyRemote(remote, to: local)
      } else {
        await pushDraft(id: local.id, accountDID: accountDID)
      }
    }
  }

  private func applyRemote(_ remote: AppBskyDraftDefs.DraftView, to local: DraftPost) throws {
    let includeMedia = remote.draft.deviceId == Self.deviceId
    let translated = DraftSyncTranslator.localDraft(from: remote.draft, includeLocalMedia: includeMedia)
    try persistence.applyRemoteDraft(
      translated,
      toDraftWithId: local.id,
      modifiedDate: remote.updatedAt.date,
      syncedAt: Date(),
      remoteMediaDeviceName: Self.unrestorableMediaDeviceName(
        for: remote.draft,
        mediaIncluded: includeMedia
      )
    )
  }

  private static func unrestorableMediaDeviceName(
    for draft: AppBskyDraftDefs.Draft,
    mediaIncluded: Bool
  ) -> String? {
    guard !mediaIncluded, DraftSyncTranslator.remoteDraftHasMedia(draft) else { return nil }
    return draft.deviceName ?? "another device"
  }

  // MARK: - Migration

  /// One-time bulk push of pre-existing local drafts, per account, behind a
  /// UserDefaults flag (modeled on the legacy JSON→SwiftData migration flag).
  private func migrateLocalDraftsIfNeeded(accountDID: String) async {
    let migrationKey = "draftSync.migratedLocalDrafts.v1." + accountDID
    guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

    logger.info("🔄 Migrating existing local drafts to AppView for account \(accountDID)")
    do {
      let locals = try persistence.fetchDrafts(for: accountDID)
      for local in locals where local.remoteId == nil {
        await pushDraft(id: local.id, accountDID: accountDID)
      }
      UserDefaults.standard.set(true, forKey: migrationKey)
      logger.info("✅ Local draft migration complete for account \(accountDID)")
    } catch {
      logger.error("Local draft migration failed: \(error.localizedDescription)")
    }
  }
}
