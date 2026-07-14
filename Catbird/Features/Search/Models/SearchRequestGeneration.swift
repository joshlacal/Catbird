/// Immutable query/filter state associated with one request generation.
struct SearchRequestSnapshot: Equatable, Sendable {
  let generation: UInt64
  let query: String
  let filters: SearchFilterState
}

/// Monotonic gate that prevents stale search responses from mutating current state.
struct SearchRequestGeneration: Sendable {
  private(set) var value: UInt64 = 0

  mutating func begin(query: String, filters: SearchFilterState) -> SearchRequestSnapshot {
    value &+= 1
    return SearchRequestSnapshot(generation: value, query: query, filters: filters)
  }

  mutating func invalidate() {
    value &+= 1
  }

  func accepts(_ request: SearchRequestSnapshot) -> Bool {
    request.generation == value
  }
}
