import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("Composer language suggestion")
@MainActor
struct ComposerLanguageSuggestionTests {
  private func makeViewModel() async -> PostComposerViewModel {
    let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:1")!)
    let state = AppState(userDID: "did:plc:composerlanguagetest", client: client)
    return PostComposerViewModel(appState: state)
  }

  /// Waits for the 300 ms text pass that follows an edit.
  private func suggestion(
    after text: String, in model: PostComposerViewModel, until expected: String?
  ) async throws -> String? {
    model.postText = text
    try await Task.sleep(for: .milliseconds(350))
    for _ in 0..<20 where model.suggestedLanguage?.lang.languageCode?.identifier != expected {
      try await Task.sleep(for: .milliseconds(50))
    }
    return model.suggestedLanguage?.lang.languageCode?.identifier
  }

  @Test("Text of 10 or more characters gets a suggestion, and it clears when the text gets shorter")
  func suggestionFollowsTheMinimumLength() async throws {
    let model = await makeViewModel()

    #expect(try await suggestion(after: "Bonjour à tous, comment ça va ?", in: model, until: "fr") == "fr")
    // Below 10 characters the recognizer is unreliable, so a stale chip must not stay.
    #expect(try await suggestion(after: "ok merci", in: model, until: nil) == nil)
    #expect(try await suggestion(after: "Hello everyone, how are you today?", in: model, until: "en") == "en")
    #expect(try await suggestion(after: "   ", in: model, until: nil) == nil)
  }

  @Test("Short text never gets a suggestion")
  func shortTextGetsNoSuggestion() async throws {
    let model = await makeViewModel()
    #expect(PostComposerViewModel.minimumLanguageDetectionLength == 10)

    #expect(try await suggestion(after: "Bonjour", in: model, until: nil) == nil)
  }
}
