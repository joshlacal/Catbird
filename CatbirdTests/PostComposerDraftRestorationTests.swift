import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("Composer draft restoration")
@MainActor
struct PostComposerDraftRestorationTests {
  private let quoteURI = "at://did:plc:quoteauthor/app.bsky.feed.post/quote"
  private let quoteCID = CID.fromDAGCBOR(Data("draft quote".utf8)).string

  private func makeDraft(quoted: Bool = false, threaded: Bool = false, parentURI: String? = nil) -> PostComposerDraft {
    PostComposerDraft(
      postText: "Saved post", mediaItems: [], videoItem: nil, selectedGif: nil,
      selectedLanguages: [], selectedLabels: [], outlineTags: [],
      threadEntries: threaded ? ["First", "Second"].map { text in
        var entry = ThreadEntry()
        entry.text = text
        return CodableThreadEntry(from: entry, parentPost: nil, quotedPost: nil)
      } : [],
      isThreadMode: threaded, currentThreadIndex: 0, parentPostURI: parentURI,
      quotedPostURI: quoted ? quoteURI : nil,
      quotedPostCID: quoted ? quoteCID : nil,
      hasDraftInteractionSettings: true
    )
  }

  private func makeViewModel() async -> PostComposerViewModel {
    let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:1")!)
    let state = AppState(userDID: "did:plc:draftrestorationtest", client: client)
    return PostComposerViewModel(appState: state)
  }

  @Test("Older draft JSON decodes without quote CID or interaction fields")
  func legacyDraftDecoding() throws {
    let data = try JSONEncoder().encode(makeDraft())
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    json.removeValue(forKey: "hasDraftInteractionSettings")
    let restored = try JSONDecoder().decode(PostComposerDraft.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(restored.quotedPostCID == nil)
    #expect(restored.hasDraftInteractionSettings == nil)
    #expect(restored.draftThreadgateAllow == nil)
    #expect(restored.draftPostgateEmbeddingRules == nil)
    #expect(restored.pendingAudioURLString == nil)
  }

  @Test("An unfinished recording round trips without clearing its file reference")
  func pendingAudioRestoration() async throws {
    let model = await makeViewModel()
    var draft = makeDraft(parentURI: quoteURI)
    let audioURL = URL(fileURLWithPath: "/Documents/composer-recording.m4a")
    draft.pendingAudioURLString = audioURL.absoluteString
    let decoded = try JSONDecoder().decode(PostComposerDraft.self, from: JSONEncoder().encode(draft))
    model.restoreDraftState(decoded)
    #expect(model.pendingAudioURL == audioURL)
    #expect(model.hasMeaningfulDraftContent)
    #expect(model.submitValidationState.reason == .pendingAudio)
    #expect(model.saveDraftState().pendingAudioURLString == audioURL.absoluteString)
    model.clearAll()
    #expect(model.pendingAudioURL == nil)
  }

  @Test("Pending quote survives immediate autosave and is only attached to the root")
  func pendingQuoteSnapshot() async throws {
    let model = await makeViewModel()
    model.restoreDraftState(makeDraft(quoted: true, threaded: true))
    let saved = model.saveDraftState()
    #expect(model.quotedPost == nil)
    #expect(saved.quotedPostURI == quoteURI)
    #expect(saved.quotedPostCID == quoteCID)
    #expect(saved.threadEntries[0].quotedPostURI == quoteURI)
    #expect(saved.threadEntries[0].quotedPostCID == quoteCID)
    #expect(saved.threadEntries[1].quotedPostURI == nil)
    #expect(model.postingQuoteReference()?.uri.uriString() == quoteURI)
    #expect(model.postingQuoteReference()?.cid.string == quoteCID)
    #expect(model.postingQuoteReference(for: model.threadEntries[0])?.cid.string == quoteCID)
    #expect(model.postingQuoteReference(for: model.threadEntries[1]) == nil)
    model.clearAll()
  }

  @Test("Removing an unhydrated quote clears its saved reference")
  func removePendingQuote() async throws {
    let model = await makeViewModel()
    model.restoreDraftState(makeDraft(quoted: true))
    model.quotedPost = nil
    let saved = model.saveDraftState()
    #expect(saved.quotedPostURI == nil)
    #expect(saved.quotedPostCID == nil)
    #expect(saved.threadEntries[0].quotedPostURI == nil)
    model.clearAll()
  }

  @Test("Switching thread entries keeps the pending root quote intact")
  func switchEntryWhileQuoteLoads() async throws {
    let model = await makeViewModel()
    model.restoreDraftState(makeDraft(quoted: true, threaded: true))
    model.currentThreadIndex = 1
    model.loadEntryState()
    let saved = model.saveDraftState()
    #expect(saved.threadEntries[0].quotedPostURI == quoteURI)
    #expect(saved.threadEntries[1].quotedPostURI == nil)
    model.clearAll()
  }

  @Test("Missing and empty threadgate rules restore different reply permissions")
  func replyPermissionDistinction() {
    var draft = makeDraft()
    #expect(PostComposerViewModel.interactionSettings(fromDraft: draft).threadgate.allowEverybody)
    draft.draftThreadgateAllow = []
    let settings = PostComposerViewModel.interactionSettings(fromDraft: draft)
    #expect(!settings.threadgate.allowEverybody)
    #expect(settings.threadgate.allowNobody)
  }

  @Test("A reply cannot silently become a plain post while its parent is unavailable")
  func pendingReplyBlocksPublication() async {
    let model = await makeViewModel()
    model.restoreDraftState(makeDraft(parentURI: quoteURI))
    #expect(model.parentPost == nil)
    let reason = model.submitValidationState.reason
    #expect(reason == .replyLoading || reason == .replyUnavailable)
    #expect(!model.canSubmitPost)
    #expect(throws: NSError.self) { try model.ensureDraftReferencesReadyForPosting() }
    #expect(model.saveDraftState().parentPostURI == quoteURI)
    #expect(model.saveDraftState().threadEntries.first?.parentPostURI == quoteURI)
    model.clearAll()
  }

  @Test("A legacy quote without a CID waits for hydration instead of publishing without the quote")
  func legacyQuoteBlocksPublication() async {
    var draft = makeDraft(quoted: true)
    draft.quotedPostCID = nil
    let model = await makeViewModel()
    model.restoreDraftState(draft)
    #expect(model.submitValidationState.reason == .quoteLoading)
    #expect(!model.canSubmitPost)
    model.clearAll()
  }

  @Test("Thread identity survives save, decoding and restoration for raw envelope matching")
  func threadIdentityRoundTrip() throws {
    let entry = ThreadEntry()
    let saved = CodableThreadEntry(from: entry, parentPost: nil, quotedPost: nil)
    let decoded = try JSONDecoder().decode(CodableThreadEntry.self, from: JSONEncoder().encode(saved))
    #expect(decoded.toThreadEntry().id == entry.id)
  }

  @Test("Restoring unrestricted settings overwrites a restrictive current composer")
  func explicitUnrestrictedSettings() async {
    let model = await makeViewModel()
    model.interactionSettings.allowQuotes = false
    model.interactionSettings.threadgate.selectOption(.nobody)
    model.restoreDraftState(makeDraft())
    #expect(model.interactionSettings.allowQuotes)
    #expect(model.interactionSettings.threadgate.allowEverybody)
    let saved = model.saveDraftState()
    #expect(saved.hasDraftInteractionSettings == true)
    #expect(saved.draftThreadgateAllow == nil)
    model.clearAll()
  }

  @Test("Editing quote permissions does not drop unknown reply rules")
  func preserveUnknownRules() async throws {
    var draft = makeDraft()
    draft.draftThreadgateAllow = try JSONDecoder().decode(
      [AppBskyDraftDefs.DraftThreadgateAllowUnion].self,
      from: Data(#"[{"$type":"test.example.futureReplyRule","value":"keep"}]"#.utf8)
    )
    draft.draftPostgateEmbeddingRules = []
    let model = await makeViewModel()
    model.restoreDraftState(draft)
    #expect(model.saveDraftState().draftPostgateEmbeddingRules == [])
    model.interactionSettings.allowQuotes = false
    let saved = model.saveDraftState()
    #expect(saved.draftThreadgateAllow == draft.draftThreadgateAllow)
    #expect(saved.draftPostgateEmbeddingRules?.count == 1)
    let publishedRules = try JSONEncoder().encode(model.postingThreadgateRules())
    let originalRules = try JSONEncoder().encode(draft.draftThreadgateAllow)
    #expect(try JSONSerialization.jsonObject(with: publishedRules) as? NSArray
            == JSONSerialization.jsonObject(with: originalRules) as? NSArray)
    #expect(model.postingPostgateRules()?.count == 1)
    model.clearAll()
  }

  @Test("Unknown quote rules survive publication when reply permissions change")
  func preserveUnknownQuoteRulesForPublication() async throws {
    var draft = makeDraft()
    draft.draftPostgateEmbeddingRules = try JSONDecoder().decode(
      [AppBskyDraftDefs.DraftPostgateEmbeddingRulesUnion].self,
      from: Data(#"[{"$type":"test.example.futureQuoteRule","value":"keep"}]"#.utf8)
    )
    let model = await makeViewModel()
    model.restoreDraftState(draft)
    model.interactionSettings.threadgate.selectOption(.nobody)
    let publishedRules = try JSONEncoder().encode(model.postingPostgateRules())
    let originalRules = try JSONEncoder().encode(draft.draftPostgateEmbeddingRules)
    #expect(try JSONSerialization.jsonObject(with: publishedRules) as? NSArray
            == JSONSerialization.jsonObject(with: originalRules) as? NSArray)
    #expect(model.postingThreadgateRules() == [])
    model.clearAll()
  }
}
