//
//  DraftSyncTranslationTests.swift
//  CatbirdTests
//
//  Unit tests for the pure local <-> remote draft translation functions
//  used by DraftSyncService (app.bsky.draft.* sync).
//

import Foundation
import Testing
import Petrel
@testable import Catbird

@Suite("Draft Sync Translation")
struct DraftSyncTranslationTests {

  // MARK: - Helpers

  private func makeEntry(
    text: String,
    mediaItems: [CodableMediaItem] = [],
    videoItem: CodableMediaItem? = nil,
    selectedEmbedURL: String? = nil,
    parentPostURI: String? = nil,
    quotedPostURI: String? = nil
  ) -> CodableThreadEntry {
    CodableThreadEntry(
      text: text,
      mediaItems: mediaItems,
      videoItem: videoItem,
      selectedGif: nil,
      detectedURLs: [],
      urlCards: [:],
      selectedEmbedURL: selectedEmbedURL,
      urlsKeptForEmbed: [],
      hashtags: [],
      parentPostURI: parentPostURI,
      quotedPostURI: quotedPostURI
    )
  }

  private func makeImage(path: String, alt: String = "") -> CodableMediaItem {
    CodableMediaItem(
      altText: alt,
      aspectRatio: nil,
      isLoading: false,
      isAudioVisualizerVideo: false,
      rawVideoURLString: nil,
      rawImageURLString: path
    )
  }

  private func makeVideo(path: String, alt: String = "") -> CodableMediaItem {
    CodableMediaItem(
      altText: alt,
      aspectRatio: nil,
      isLoading: false,
      isAudioVisualizerVideo: false,
      rawVideoURLString: path,
      rawImageURLString: nil
    )
  }

  private func makeDraft(
    postText: String = "",
    mediaItems: [CodableMediaItem] = [],
    videoItem: CodableMediaItem? = nil,
    selectedLanguages: [LanguageCodeContainer] = [],
    selectedLabels: Set<ComAtprotoLabelDefs.LabelValue> = [],
    threadEntries: [CodableThreadEntry] = [],
    isThreadMode: Bool = false,
    parentPostURI: String? = nil,
    quotedPostURI: String? = nil
  ) -> PostComposerDraft {
    PostComposerDraft(
      postText: postText,
      mediaItems: mediaItems,
      videoItem: videoItem,
      selectedGif: nil,
      selectedLanguages: selectedLanguages,
      selectedLabels: selectedLabels,
      outlineTags: [],
      threadEntries: threadEntries,
      isThreadMode: isThreadMode,
      currentThreadIndex: 0,
      parentPostURI: parentPostURI,
      quotedPostURI: quotedPostURI
    )
  }

  // MARK: - Push (local -> remote)

  @Test("Single post push carries text, device identity and langs")
  func singlePostPush() {
    let draft = makeDraft(
      postText: "Hello AppView",
      selectedLanguages: [LanguageCodeContainer(languageCode: "en")],
      threadEntries: [makeEntry(text: "Hello AppView")]
    )

    let remote = DraftSyncTranslator.remoteDraft(from: draft, deviceId: "device-1", deviceName: "Test iPhone")

    #expect(remote.posts.count == 1)
    #expect(remote.posts.first?.text == "Hello AppView")
    #expect(remote.deviceId == "device-1")
    #expect(remote.deviceName == "Test iPhone")
    #expect(remote.langs?.count == 1)
    #expect(remote.postgateEmbeddingRules == nil)
    #expect(remote.threadgateAllow == nil)
  }

  @Test("Thread push maps each entry to a post in order")
  func threadPush() {
    let draft = makeDraft(
      postText: "First",
      threadEntries: [makeEntry(text: "First"), makeEntry(text: "Second"), makeEntry(text: "Third")],
      isThreadMode: true
    )

    let remote = DraftSyncTranslator.remoteDraft(from: draft, deviceId: nil, deviceName: nil)

    #expect(remote.posts.map(\.text) == ["First", "Second", "Third"])
  }

  @Test("Non-thread push uses top-level text even when entries differ")
  func nonThreadPushUsesTopLevelText() {
    let draft = makeDraft(
      postText: "Top level",
      threadEntries: [makeEntry(text: "stale entry")],
      isThreadMode: false
    )

    let remote = DraftSyncTranslator.remoteDraft(from: draft, deviceId: nil, deviceName: nil)

    #expect(remote.posts.count == 1)
    #expect(remote.posts.first?.text == "Top level")
  }

  @Test("Labels push as sorted self labels")
  func labelsPush() {
    let draft = makeDraft(
      postText: "Labeled",
      selectedLabels: [
        ComAtprotoLabelDefs.LabelValue(rawValue: "sexual"),
        ComAtprotoLabelDefs.LabelValue(rawValue: "graphic-media")
      ],
      threadEntries: [makeEntry(text: "Labeled")]
    )

    let remote = DraftSyncTranslator.remoteDraft(from: draft, deviceId: nil, deviceName: nil)

    guard case .comAtprotoLabelDefsSelfLabels(let selfLabels)? = remote.posts.first?.labels else {
      Issue.record("Expected selfLabels union case")
      return
    }
    #expect(selfLabels.values.map(\.val) == ["graphic-media", "sexual"])
  }

  @Test("Media pushes as device-local refs, not blobs")
  func mediaPushesAsLocalRefs() {
    let imagePath = "file:///tmp/SharedDrafts/draft_image_abc.jpg"
    let videoPath = "file:///tmp/SharedDrafts/draft_video_xyz.mov"
    let draft = makeDraft(
      postText: "With media",
      mediaItems: [makeImage(path: imagePath, alt: "An image")],
      videoItem: makeVideo(path: videoPath),
      threadEntries: [makeEntry(text: "With media")]
    )

    let remote = DraftSyncTranslator.remoteDraft(from: draft, deviceId: "device-1", deviceName: nil)

    let post = remote.posts.first
    #expect(post?.embedImages?.count == 1)
    #expect(post?.embedImages?.first?.localRef.path == imagePath)
    #expect(post?.embedImages?.first?.alt == "An image")
    #expect(post?.embedVideos?.count == 1)
    #expect(post?.embedVideos?.first?.localRef.path == videoPath)
    // Empty alt text becomes nil rather than an empty string
    #expect(post?.embedVideos?.first?.alt == nil)
  }

  @Test("Empty optional collections push as nil")
  func emptyCollectionsPushAsNil() {
    let draft = makeDraft(postText: "Plain", threadEntries: [makeEntry(text: "Plain")])

    let remote = DraftSyncTranslator.remoteDraft(from: draft, deviceId: nil, deviceName: nil)

    let post = remote.posts.first
    #expect(post?.embedImages == nil)
    #expect(post?.embedVideos == nil)
    #expect(post?.embedExternals == nil)
    #expect(post?.labels == nil)
    #expect(remote.langs == nil)
  }

  // MARK: - Syncability

  @Test("Reply and quote drafts are not syncable")
  func replyAndQuoteDraftsNotSyncable() {
    let reply = makeDraft(postText: "re", threadEntries: [makeEntry(text: "re")], parentPostURI: "at://did:plc:abc/app.bsky.feed.post/123")
    let quote = makeDraft(postText: "q", threadEntries: [makeEntry(text: "q")], quotedPostURI: "at://did:plc:abc/app.bsky.feed.post/456")
    let entryReply = makeDraft(postText: "er", threadEntries: [makeEntry(text: "er", parentPostURI: "at://did:plc:abc/app.bsky.feed.post/789")])
    let plain = makeDraft(postText: "ok", threadEntries: [makeEntry(text: "ok")])

    #expect(!DraftSyncTranslator.isSyncable(reply))
    #expect(!DraftSyncTranslator.isSyncable(quote))
    #expect(!DraftSyncTranslator.isSyncable(entryReply))
    #expect(DraftSyncTranslator.isSyncable(plain))
  }

  // MARK: - Pull (remote -> local)

  @Test("Single remote post pulls as non-thread draft")
  func singleRemotePostPull() {
    let remote = AppBskyDraftDefs.Draft(
      deviceId: "other-device",
      deviceName: "Other",
      posts: [
        AppBskyDraftDefs.DraftPost(
          text: "Remote text",
          labels: nil,
          embedImages: nil,
          embedGallery: nil,
          embedVideos: nil,
          embedExternals: nil,
          embedRecords: nil
        )
      ],
      langs: [LanguageCodeContainer(languageCode: "de")],
      postgateEmbeddingRules: nil,
      threadgateAllow: nil
    )

    let local = DraftSyncTranslator.localDraft(from: remote, includeLocalMedia: false)

    #expect(local.postText == "Remote text")
    #expect(local.isThreadMode == false)
    #expect(local.threadEntries.count == 1)
    #expect(local.selectedLanguages.count == 1)
    #expect(local.parentPostURI == nil)
    #expect(local.quotedPostURI == nil)
  }

  @Test("Multi-post remote draft pulls as thread")
  func multiPostRemotePull() {
    let posts = ["One", "Two"].map { text in
      AppBskyDraftDefs.DraftPost(
        text: text,
        labels: nil,
        embedImages: nil,
        embedGallery: nil,
        embedVideos: nil,
        embedExternals: nil,
        embedRecords: nil
      )
    }
    let remote = AppBskyDraftDefs.Draft(
      deviceId: nil,
      deviceName: nil,
      posts: posts,
      langs: nil,
      postgateEmbeddingRules: nil,
      threadgateAllow: nil
    )

    let local = DraftSyncTranslator.localDraft(from: remote, includeLocalMedia: false)

    #expect(local.isThreadMode == true)
    #expect(local.threadEntries.map(\.text) == ["One", "Two"])
    #expect(local.postText == "One")
  }

  @Test("Media local refs only survive pull on the originating device")
  func mediaPullRespectsDeviceLocality() {
    let imagePath = "file:///tmp/SharedDrafts/draft_image_abc.jpg"
    let remote = AppBskyDraftDefs.Draft(
      deviceId: "device-1",
      deviceName: nil,
      posts: [
        AppBskyDraftDefs.DraftPost(
          text: "Pic",
          labels: nil,
          embedImages: [AppBskyDraftDefs.DraftEmbedImage(localRef: .init(path: imagePath), alt: "alt text")],
          embedGallery: nil,
          embedVideos: nil,
          embedExternals: nil,
          embedRecords: nil
        )
      ],
      langs: nil,
      postgateEmbeddingRules: nil,
      threadgateAllow: nil
    )

    let sameDevice = DraftSyncTranslator.localDraft(from: remote, includeLocalMedia: true)
    #expect(sameDevice.mediaItems.count == 1)
    #expect(sameDevice.mediaItems.first?.rawImageURLString == imagePath)
    #expect(sameDevice.mediaItems.first?.altText == "alt text")

    let otherDevice = DraftSyncTranslator.localDraft(from: remote, includeLocalMedia: false)
    #expect(otherDevice.mediaItems.isEmpty)
    #expect(otherDevice.postText == "Pic")
  }

  @Test("Remote labels pull into selectedLabels")
  func labelsPull() {
    let remote = AppBskyDraftDefs.Draft(
      deviceId: nil,
      deviceName: nil,
      posts: [
        AppBskyDraftDefs.DraftPost(
          text: "Labeled",
          labels: .comAtprotoLabelDefsSelfLabels(.init(values: [
            ComAtprotoLabelDefs.SelfLabel(val: "nudity"),
            ComAtprotoLabelDefs.SelfLabel(val: "sexual")
          ])),
          embedImages: nil,
          embedGallery: nil,
          embedVideos: nil,
          embedExternals: nil,
          embedRecords: nil
        )
      ],
      langs: nil,
      postgateEmbeddingRules: nil,
      threadgateAllow: nil
    )

    let local = DraftSyncTranslator.localDraft(from: remote, includeLocalMedia: false)

    #expect(local.selectedLabels == Set([
      ComAtprotoLabelDefs.LabelValue(rawValue: "nudity"),
      ComAtprotoLabelDefs.LabelValue(rawValue: "sexual")
    ]))
  }

  // MARK: - Round trip

  @Test("Push then pull preserves text, structure, langs and labels")
  func roundTripPreservesContent() {
    let original = makeDraft(
      postText: "Round trip",
      mediaItems: [makeImage(path: "file:///tmp/SharedDrafts/img.jpg", alt: "pic")],
      selectedLanguages: [LanguageCodeContainer(languageCode: "en")],
      selectedLabels: [ComAtprotoLabelDefs.LabelValue(rawValue: "nudity")],
      threadEntries: [
        makeEntry(text: "Round trip", mediaItems: [makeImage(path: "file:///tmp/SharedDrafts/img.jpg", alt: "pic")]),
        makeEntry(text: "Part two")
      ],
      isThreadMode: true
    )

    let remote = DraftSyncTranslator.remoteDraft(from: original, deviceId: "device-1", deviceName: "Test")
    let restored = DraftSyncTranslator.localDraft(from: remote, includeLocalMedia: true)

    #expect(restored.postText == original.postText)
    #expect(restored.isThreadMode == original.isThreadMode)
    #expect(restored.threadEntries.map(\.text) == original.threadEntries.map(\.text))
    #expect(restored.selectedLanguages == original.selectedLanguages)
    #expect(restored.selectedLabels == original.selectedLabels)
    #expect(restored.mediaItems.first?.rawImageURLString == "file:///tmp/SharedDrafts/img.jpg")
    #expect(restored.mediaItems.first?.altText == "pic")
  }
}
