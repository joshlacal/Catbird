import Testing
@testable import Catbird

@Suite("Feed content presentation")
struct FeedContentStateTests {
  @Test("An idle feed without a response presents loading instead of empty")
  func initialIdleIsLoading() {
    #expect(FeedContentState(hasPosts: false, hasLoadedInitialResponse: false,
      isLoading: false, hasError: false) == .loading)
  }

  @Test("Only a completed successful response establishes empty content")
  func successfulEmptyResponse() {
    #expect(FeedContentState(hasPosts: false, hasLoadedInitialResponse: true,
      isLoading: false, hasError: false) == .empty)
  }

  @Test("Reloading a previously empty feed presents loading")
  func reloadingEmptyResponse() {
    #expect(FeedContentState(hasPosts: false, hasLoadedInitialResponse: true,
      isLoading: true, hasError: false) == .loading)
  }

  @Test("A failed empty feed presents its error, including after previous success",
    arguments: [false, true])
  func failedResponse(hasLoaded: Bool) {
    #expect(FeedContentState(hasPosts: false, hasLoadedInitialResponse: hasLoaded,
      isLoading: false, hasError: true) == .error)
  }

  @Test("A retry replaces a previous error with loading")
  func retryWithPreviousError() {
    #expect(FeedContentState(hasPosts: false, hasLoadedInitialResponse: false,
      isLoading: true, hasError: true) == .loading)
  }

  @Test("Cached rows stay visible during loading and failures", arguments: [false, true], [false, true])
  func cachedRowsStayVisible(isLoading: Bool, hasError: Bool) {
    #expect(FeedContentState(hasPosts: true, hasLoadedInitialResponse: false,
      isLoading: isLoading, hasError: hasError) == .content)
  }
}
