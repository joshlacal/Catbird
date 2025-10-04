import AppIntents
import SwiftUI

@available(iOS 17.0, *)
struct ComposePostIntent: AppIntent {
  static var title: LocalizedStringResource = "Compose Post"
  static var description = IntentDescription("Create a new Bluesky post with optional text and URL.")

  @Parameter(title: "Text")
  var text: String?

  @Parameter(title: "URL", default: nil)
  var url: URL?

  func perform() async throws -> some IntentResult & ProvidesDialog {
    await MainActor.run {
      let appState = AppState.shared
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
      appState.composerDraftManager.storeDraft(draft)
    }
    return .result(dialog: "Draft created. Open the app to continue composing.")
  }
}
