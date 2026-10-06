import Testing
@testable import Catbird

struct ReadingLanguagePolicyTests {
  @Test("Regional and case variants use their supported base language")
  func variants() {
    #expect(ReadingLanguagePolicy.allows(declaredLanguages: ["en-GB"], preferredLanguages: ["EN_us"], detectedLanguage: nil))
    #expect(!ReadingLanguagePolicy.allows(declaredLanguages: ["fr-CA"], preferredLanguages: ["en-US"], detectedLanguage: nil))
  }

  @Test("Undecidable and unsupported metadata remain visible")
  func unknowns() {
    for declared in [[], ["und"], ["x-private"], ["fr", "x-private"]] {
      #expect(ReadingLanguagePolicy.allows(declaredLanguages: declared, preferredLanguages: ["en"], detectedLanguage: nil))
    }
    #expect(ReadingLanguagePolicy.allows(declaredLanguages: ["fr"], preferredLanguages: ["x-private"], detectedLanguage: nil))
    #expect(ReadingLanguagePolicy.allows(declaredLanguages: ["fr"], preferredLanguages: [], detectedLanguage: nil))
  }

  @Test("Supported detection is used only when declared languages are absent")
  func detection() {
    #expect(ReadingLanguagePolicy.allows(declaredLanguages: [], preferredLanguages: ["en-US"], detectedLanguage: "en"))
    #expect(!ReadingLanguagePolicy.allows(declaredLanguages: [], preferredLanguages: ["en"], detectedLanguage: "fr"))
    #expect(ReadingLanguagePolicy.allows(declaredLanguages: ["en"], preferredLanguages: ["en"], detectedLanguage: "fr"))
  }
}
