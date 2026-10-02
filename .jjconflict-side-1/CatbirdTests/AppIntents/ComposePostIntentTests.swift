//
//  ComposePostIntentTests.swift
//  CatbirdTests
//
//  Verifies the ComposeDraftStasher ↔ IncomingSharedDraftHandler contract:
//  a draft stashed by the intent must decode as a PostComposerDraft from the
//  same app-group slot the import path drains.
//

import Foundation
import Testing

@testable import Catbird

@Suite("ComposeDraftStasher app-group handoff")
struct ComposePostIntentTests {

  private func makeDraft(text: String) -> PostComposerDraft {
    PostComposerDraft(
      postText: text,
      mediaItems: [],
      videoItem: nil,
      selectedGif: nil,
      selectedLanguages: [],
      selectedLabels: [],
      outlineTags: [],
      threadEntries: [],
      isThreadMode: false,
      currentThreadIndex: 0,
      parentPostURI: nil,
      quotedPostURI: nil
    )
  }

  @Test func stashedDraftRoundTripsThroughSharedSlot() throws {
    let suiteName = "test.compose.stash.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let draft = makeDraft(text: "Hello from Siri https://example.com")
    try ComposeDraftStasher.stash(draft, defaults: defaults)

    // Decode exactly the way IncomingSharedDraftHandler.importIfAvailable does:
    // raw Data under "incoming_shared_draft", JSONDecoder, PostComposerDraft first.
    let data = try #require(defaults.data(forKey: ComposeDraftStasher.draftKey))
    let decoded = try JSONDecoder().decode(PostComposerDraft.self, from: data)
    #expect(decoded == draft)
    #expect(decoded.postText == "Hello from Siri https://example.com")
  }

  @Test func stashOverwritesPreviousDraft() throws {
    let suiteName = "test.compose.stash.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    try ComposeDraftStasher.stash(makeDraft(text: "first"), defaults: defaults)
    try ComposeDraftStasher.stash(makeDraft(text: "second"), defaults: defaults)

    let data = try #require(defaults.data(forKey: ComposeDraftStasher.draftKey))
    let decoded = try JSONDecoder().decode(PostComposerDraft.self, from: data)
    #expect(decoded.postText == "second")
  }
}


