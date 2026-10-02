import Testing
@testable import Catbird

struct RejoinStatusPresentationTests {
  @Test
  func pendingStatusPresentation() {
    let presentation = rejoinStatusPresentation(for: .inProgress)

    #expect(presentation?.title == "Updating secure session")
    #expect(presentation?.showsProgress == true)
    #expect(presentation?.showsRetry == false)
  }

  @Test
  func successStatusPresentation() {
    let presentation = rejoinStatusPresentation(for: .success)

    #expect(presentation?.title == "Secure session restored")
    #expect(presentation?.showsProgress == false)
    #expect(presentation?.showsRetry == false)
  }

  @Test
  func failedStatusPresentation() {
    let presentation = rejoinStatusPresentation(for: .failed("any"))

    #expect(presentation?.title == "Secure rejoin not completed")
    #expect(presentation?.showsProgress == false)
    #expect(presentation?.showsRetry == true)
  }

  @Test
  func noBannerForIdleAndActionRequiredStates() {
    #expect(rejoinStatusPresentation(for: .none) == nil)
    #expect(rejoinStatusPresentation(for: .needed) == nil)
  }
}
