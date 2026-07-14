import Foundation
import Testing
@testable import Catbird

@Suite("Recovered settings runtime wiring")
struct SettingsRuntimeWiringTests {
  @Test("Required alt text exposes an actionable composer reason")
  func missingAltTextReason() {
    let state = PostComposerSubmitValidationState(canSubmit: false, reason: .missingAltText)
    #expect(state.message == "Add alt text to every image before posting.")
    #expect(state.shouldShowInlineMessage)
  }

  @Test("Required alt text checks every attached image and video")
  func missingAltTextMediaPredicate() {
    #expect(
      !PostComposerAltTextRequirement.hasMissingAltText(
        imageAltTexts: ["A cat", "A dog"],
        videoAltText: "A short video"
      )
    )
    #expect(
      PostComposerAltTextRequirement.hasMissingAltText(
        imageAltTexts: ["A cat", "   "],
        videoAltText: nil
      )
    )
    #expect(
      PostComposerAltTextRequirement.hasMissingAltText(
        imageAltTexts: [],
        videoAltText: "\n"
      )
    )
  }

  @Test("Thread sort values map to supported API values")
  func threadSortMapping() {
    #expect(ThreadSortAPIMapper.apiValue(for: "hot") == "top")
    #expect(ThreadSortAPIMapper.apiValue(for: "top") == "top")
    #expect(ThreadSortAPIMapper.apiValue(for: "newest") == "newest")
    #expect(ThreadSortAPIMapper.apiValue(for: "oldest") == "oldest")
    #expect(ThreadSortAPIMapper.apiValue(for: "invalid") == "oldest")
  }

  @Test("Reading-time estimates start at one hundred words")
  func readingTimeThreshold() {
    #expect(PostReadingTime.minutes(forWordCount: 99) == nil)
    #expect(PostReadingTime.minutes(forWordCount: 100) == 1)
    #expect(PostReadingTime.minutes(forWordCount: 201) == 2)
  }

  @Test("Post links support every stored style and reject invalid styles safely")
  func linkPresentation() {
    #expect(PostLinkPresentationStyle.resolve(highlightLinks: false, linkStyle: "both") == .disabled)
    #expect(PostLinkPresentationStyle.resolve(highlightLinks: true, linkStyle: "color") == .color)
    #expect(PostLinkPresentationStyle.resolve(highlightLinks: true, linkStyle: "underline") == .underline)
    #expect(PostLinkPresentationStyle.resolve(highlightLinks: true, linkStyle: "both") == .both)
    #expect(PostLinkPresentationStyle.resolve(highlightLinks: true, linkStyle: "invalid") == .color)
  }

  @Test("Display-only settings expose deterministic predicates")
  func displayPredicates() {
    #expect(PostLanguageIndicators.shouldShow(isEnabled: true, languageCount: 1))
    #expect(!PostLanguageIndicators.shouldShow(isEnabled: false, languageCount: 1))
    #expect(!PostLanguageIndicators.shouldShow(isEnabled: true, languageCount: 0))
    #expect(AltTextBadgeMetrics.side(isLarge: false) == 24)
    #expect(AltTextBadgeMetrics.side(isLarge: true) == 32)
    #expect(DestructiveActionConfirmation.shouldConfirm(isEnabled: true))
    #expect(!DestructiveActionConfirmation.shouldConfirm(isEnabled: false))
  }

  @Test("Haptic preference has one enabled-state mapping")
  func hapticPolicy() {
    #expect(HapticsPolicy.isEnabled(disableHaptics: false))
    #expect(!HapticsPolicy.isEnabled(disableHaptics: true))
  }

  @Test("Logged-out visibility preserves unrelated self-labels")
  func loggedOutVisibilityLabels() {
    let source = ["porn", "!no-unauthenticated", "graphic-media"]
    #expect(
      LoggedOutVisibilitySelfLabels.reconciled(source, isVisible: true)
        == ["porn", "graphic-media"]
    )
    #expect(
      LoggedOutVisibilitySelfLabels.reconciled(source, isVisible: false)
        == ["porn", "graphic-media", "!no-unauthenticated"]
    )
  }
}
