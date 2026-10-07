/// Full-screen feed presentation, independent of a request task's lifetime.
enum FeedContentState: Equatable {
  case content
  case loading
  case error
  case empty

  init(hasPosts: Bool, hasLoadedInitialResponse: Bool, isLoading: Bool, hasError: Bool) {
    if hasPosts {
      self = .content
    } else if isLoading {
      self = .loading
    } else if hasError {
      self = .error
    } else if hasLoadedInitialResponse {
      self = .empty
    } else {
      self = .loading
    }
  }
}
