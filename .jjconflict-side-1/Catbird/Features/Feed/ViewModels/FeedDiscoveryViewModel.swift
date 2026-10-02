import Foundation
import Observation
import Petrel

@MainActor
@Observable
final class FeedDiscoveryViewModel {
  var query: String {
    didSet {
      guard normalizedQuery != oldValue.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
      start(delay: normalizedQuery.isEmpty ? .zero : .milliseconds(250))
    }
  }
  private(set) var items: [AppBskyFeedDefs.GeneratorView] = []
  private(set) var resultQuery = ""
  private(set) var cursor: String?
  private(set) var isInitialLoading = false
  private(set) var isRefreshing = false
  private(set) var isLoadingMore = false
  private(set) var initialError: String?
  private(set) var refreshError: String?
  private(set) var pagingError: String?
  private(set) var accountDID: String
  var normalizedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

  @ObservationIgnored private var provider: any FeedDiscoveryProviding
  @ObservationIgnored private var request: Task<Void, Never>?
  @ObservationIgnored private var clientIdentity: ObjectIdentifier?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var hasLoaded = false
  @ObservationIgnored private var consumedCursors: Set<String> = []

  init(provider: any FeedDiscoveryProviding, accountDID: String, initialQuery: String = "") {
    self.provider = provider
    self.accountDID = accountDID
    self.query = initialQuery
  }

  convenience init(client: ATProtoClient, accountDID: String, initialQuery: String = "") {
    self.init(provider: FeedDiscoveryProvider(client: client), accountDID: accountDID, initialQuery: initialQuery)
    self.clientIdentity = ObjectIdentifier(client)
  }

  func load() {
    guard !hasLoaded else { return }
    submit()
  }

  func submit() { start(delay: .zero) }
  func refresh() { submit() }
  func retry() {
    if pagingError != nil { loadMore() } else { submit() }
  }

  func cancel() {
    generation += 1
    request?.cancel()
    request = nil
    isInitialLoading = false
    isRefreshing = false
    isLoadingMore = false
  }

  func updateAccount(client: ATProtoClient, accountDID: String) {
    let identity = ObjectIdentifier(client)
    guard self.accountDID != accountDID || clientIdentity != identity else { return }
    updateAccount(provider: FeedDiscoveryProvider(client: client), accountDID: accountDID)
    clientIdentity = identity
  }

  func updateAccount(provider: any FeedDiscoveryProviding, accountDID: String) {
    let changedAccount = self.accountDID != accountDID
    cancel()
    self.provider = provider
    self.accountDID = accountDID
    clientIdentity = nil
    if changedAccount {
      items = []
      cursor = nil
      consumedCursors = []
      resultQuery = ""
      hasLoaded = false
    }
    submit()
  }

  func loadMore() {
    guard !isInitialLoading, !isRefreshing, !isLoadingMore,
          normalizedQuery == resultQuery, let cursor else { return }
    pagingError = nil
    isLoadingMore = true
    begin(query: resultQuery, cursor: cursor, delay: .zero)
  }

  private func start(delay: Duration) {
    cancel()
    hasLoaded = true
    initialError = nil
    refreshError = nil
    pagingError = nil
    isInitialLoading = items.isEmpty
    isRefreshing = !items.isEmpty
    begin(query: normalizedQuery, cursor: nil, delay: delay)
  }

  private func begin(query: String, cursor requestedCursor: String?, delay: Duration) {
    let capturedGeneration = generation
    let capturedAccount = accountDID
    let provider = provider
    request = Task { [weak self] in
      do {
        if delay != .zero { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        let page = try await provider.page(query: query.isEmpty ? nil : query, cursor: requestedCursor)
        guard let self, !Task.isCancelled,
              self.generation == capturedGeneration, self.accountDID == capturedAccount else { return }
        var seen = Set(requestedCursor == nil ? [] : self.items.map { $0.uri.uriString() })
        let unique = page.feeds.filter { seen.insert($0.uri.uriString()).inserted }
        if let requestedCursor {
          self.items.append(contentsOf: unique)
          self.consumedCursors.insert(requestedCursor)
        } else {
          self.items = unique
          self.resultQuery = query
          self.consumedCursors = []
        }
        self.cursor = page.cursor.flatMap { self.consumedCursors.contains($0) ? nil : $0 }
        self.finish()
      } catch {
        guard let self, self.generation == capturedGeneration,
              self.accountDID == capturedAccount else { return }
        if !(error is CancellationError), !Task.isCancelled {
          if requestedCursor != nil { self.pagingError = error.localizedDescription }
          else if self.items.isEmpty { self.initialError = error.localizedDescription }
          else { self.refreshError = error.localizedDescription }
        }
        self.finish()
      }
    }
  }

  private func finish() {
    isInitialLoading = false
    isRefreshing = false
    isLoadingMore = false
    request = nil
  }
}
