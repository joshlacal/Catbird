//
//  ComposePostIntent.swift
//  Catbird
//
//  "Draft Post" intent: stashes a composer draft in the shared app-group slot
//  drained by IncomingSharedDraftHandler (launch + scene-active), so the draft
//  survives even when the app process isn't running when the intent executes.
//  Publishing happens in CreatePostIntent; this one only prepares the composer.
//

import AppIntents
import Foundation

/// Writes a composer draft into the app-group handoff slot shared with the
/// share extension. Kept as a standalone helper so the encode/store contract
/// with `IncomingSharedDraftHandler.importIfAvailable()` is unit-testable.
enum ComposeDraftStasher {
  static let draftKey = "incoming_shared_draft"

  static func stash(_ draft: PostComposerDraft, defaults: UserDefaults) throws {
    let data = try JSONEncoder().encode(draft)
    defaults.set(data, forKey: draftKey)
  }
}

@available(iOS 18.0, *)
struct ComposePostIntent: AppIntent {
  static var title: LocalizedStringResource = "Draft Post"
  static var description = IntentDescription(
    "Save a Bluesky post draft with optional text and URL. The draft opens in the composer in Catbird."
  )

  @Parameter(title: "Text")
  var text: String?

  @Parameter(title: "URL", default: nil)
  var url: URL?

  func perform() async throws -> some IntentResult & ProvidesDialog {
    var combined = text ?? ""
    if let u = url { combined += (combined.isEmpty ? "" : " ") + u.absoluteString }

    let draft = PostComposerDraft(
      postText: combined,
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

    guard let defaults = UserDefaults(suiteName: IntentAccountResolver.appGroupSuiteName) else {
      throw IntentError.serviceUnavailable("Catbird's shared storage is unavailable.")
    }
    try ComposeDraftStasher.stash(draft, defaults: defaults)

    // If the app process is already alive, drain the slot now so the draft
    // reaches the composer without waiting for the next launch/foreground.
    await MainActor.run {
      if AppStateManager.shared.lifecycle.appState != nil {
        IncomingSharedDraftHandler.importIfAvailable()
      }
    }

    return .result(dialog: "Draft saved. Open Catbird to continue composing.")
  }
}

