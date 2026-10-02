import Testing
@testable import Catbird

@Suite("Composer counter display")
struct ComposerCounterDisplayTests {
  @Test func numeralHiddenWhenFarFromLimit() {
    #expect(!ComposerCounterDisplay.showsNumeral(currentCount: 0))
    #expect(!ComposerCounterDisplay.showsNumeral(currentCount: 100))
    #expect(!ComposerCounterDisplay.showsNumeral(currentCount: 249))
  }

  @Test func numeralShownAtFiftyRemainingAndBeyond() {
    #expect(ComposerCounterDisplay.showsNumeral(currentCount: 250))
    #expect(ComposerCounterDisplay.showsNumeral(currentCount: 299))
    #expect(ComposerCounterDisplay.showsNumeral(currentCount: 300))
    #expect(ComposerCounterDisplay.showsNumeral(currentCount: 320))
  }

  @Test func respectsCustomMaxCount() {
    #expect(ComposerCounterDisplay.showsNumeral(currentCount: 0, maxCount: 40))
    #expect(!ComposerCounterDisplay.showsNumeral(currentCount: 0, maxCount: 51))
  }
}
