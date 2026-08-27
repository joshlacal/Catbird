//
//  ThreadPostNumberTests.swift
//  CatbirdTests
//
//  Created by Josh LaCalamito on 2026-08-24.
//

@testable import Catbird
import Petrel
import Testing

@Suite("ThreadPostNumber.validationAndFormatting")
struct ThreadPostNumberTests {
  // MARK: - Validation Tests

  @Test("Valid post numbering inputs (1/4, 4/4, 1/1, 2/5)")
  func validPostNumbers() {
    #expect(ThreadPostNumberFormatter.isValid(index: 1, count: 4))
    #expect(ThreadPostNumberFormatter.isValid(index: 4, count: 4))
    #expect(ThreadPostNumberFormatter.isValid(index: 1, count: 1))
    #expect(ThreadPostNumberFormatter.isValid(index: 2, count: 5))
    #expect(ThreadPostNumberFormatter.isValid(index: 10, count: 100))
  }

  @Test("Missing (nil) post numbering inputs produce no badge")
  func missingInputsProduceNoBadge() {
    #expect(!ThreadPostNumberFormatter.isValid(index: nil, count: 4))
    #expect(!ThreadPostNumberFormatter.isValid(index: 1, count: nil))
    #expect(!ThreadPostNumberFormatter.isValid(index: nil, count: nil))
  }

  @Test("Zero index or zero count produce no badge")
  func zeroInputsProduceNoBadge() {
    #expect(!ThreadPostNumberFormatter.isValid(index: 0, count: 4))
    #expect(!ThreadPostNumberFormatter.isValid(index: 1, count: 0))
    #expect(!ThreadPostNumberFormatter.isValid(index: 0, count: 0))
  }

  @Test("Negative index or negative count produce no badge")
  func negativeInputsProduceNoBadge() {
    #expect(!ThreadPostNumberFormatter.isValid(index: -1, count: 4))
    #expect(!ThreadPostNumberFormatter.isValid(index: 1, count: -4))
    #expect(!ThreadPostNumberFormatter.isValid(index: -2, count: -2))
  }

  @Test("Index greater than count produces no badge")
  func indexGreaterThanCountProducesNoBadge() {
    #expect(!ThreadPostNumberFormatter.isValid(index: 5, count: 4))
    #expect(!ThreadPostNumberFormatter.isValid(index: 2, count: 1))
    #expect(!ThreadPostNumberFormatter.isValid(index: 10, count: 2))
  }

  // MARK: - Formatting & Accessibility Tests

  @Test("Display text formats as index/count")
  func displayTextFormatting() {
    #expect(ThreadPostNumberFormatter.displayText(index: 1, count: 4) == "1/4")
    #expect(ThreadPostNumberFormatter.displayText(index: 4, count: 4) == "4/4")
    #expect(ThreadPostNumberFormatter.displayText(index: 2, count: 10) == "2/10")
  }

  @Test("VoiceOver label formats as 'Post index of count'")
  func accessibilityLabelFormatting() {
    #expect(ThreadPostNumberFormatter.accessibilityLabel(index: 1, count: 4) == "Post 1 of 4")
    #expect(ThreadPostNumberFormatter.accessibilityLabel(index: 4, count: 4) == "Post 4 of 4")
    #expect(ThreadPostNumberFormatter.accessibilityLabel(index: 3, count: 8) == "Post 3 of 8")
  }

  // MARK: - View Initializer Tests

  @Test("ThreadPostNumberView failable init succeeds on valid inputs and fails on invalid inputs")
  func viewFailableInit() {
    // Valid inputs produce non-nil view
    #expect(ThreadPostNumberView(index: Optional(1), count: Optional(4)) != nil)
    #expect(ThreadPostNumberView(index: Optional(4), count: Optional(4)) != nil)

    // Invalid inputs produce nil view
    #expect(ThreadPostNumberView(index: Optional(5), count: Optional(4)) == nil)
    #expect(ThreadPostNumberView(index: Optional(0), count: Optional(4)) == nil)
    #expect(ThreadPostNumberView(index: Optional(1), count: Optional(0)) == nil)
    #expect(ThreadPostNumberView(index: Optional(-1), count: Optional(4)) == nil)
    #expect(ThreadPostNumberView(index: nil, count: Optional(4)) == nil)
    #expect(ThreadPostNumberView(index: Optional(1), count: nil) == nil)
    #expect(ThreadPostNumberView(index: nil, count: nil) == nil)
  }
}
