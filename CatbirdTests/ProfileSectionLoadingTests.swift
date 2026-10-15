import Foundation
@testable import Petrel
import Testing

@testable import Catbird

/// A profile's More sections share the profile screen's view model, so one section's load must
/// not stop another's. A section page left loading by a section the reader already left (the
/// next page of Lists, or the starter-pack refresh after creating one) used to make the next
/// section's first load return without loading, and that section showed "No Feeds" until pull
/// to refresh.
///
/// Two copies of one section share it too. A copy whose first load finds that section's first
/// load in flight waits for it, and loads itself only if that load failed or was cancelled; it
/// used to return at once and, when that load then failed, stay empty until its next
/// appearance. A first load that finds a next page in flight stops it and loads the first page.
@Suite("Profile section loading", .serialized)
@MainActor
struct ProfileSectionLoadingTests {
  typealias Section = ProfileSectionStubServer.Section

  @Test(
    "A section's first load runs while another section's next page is still loading",
    arguments: zip([Section.lists, .feeds, .starterPacks], [Section.feeds, .starterPacks, .lists])
  )
  func firstLoadRunsWhileAnotherSectionPages(paging: Section, opening: Section) async throws {
    let server = ProfileSectionStubProtocol.makeServer()
    defer { ProfileSectionStubProtocol.release(server) }
    // A failed expectation must not leave the held page waiting for its timeout.
    defer { server.releaseHeldPages() }
    let viewModel = try await Self.makeLoadedViewModel(server: server)

    try await Self.refresh(paging, on: viewModel)
    #expect(Self.count(of: paging, in: viewModel) == 1)

    // The server holds every next page, so this one stays in flight until released.
    let nextPage = Task { await Self.loadNextPage(of: paging, on: viewModel) }
    try await Self.waitUntil { server.heldRequestCount == 1 }

    try await Self.refresh(opening, on: viewModel)

    #expect(server.requestCount(opening) == 1)
    #expect(Self.count(of: opening, in: viewModel) == 1)

    server.releaseHeldPages()
    await nextPage.value
    #expect(Self.count(of: paging, in: viewModel) == 2)
  }

  // MARK: - Two copies of one section

  @Test("A copy that finds its section loading waits for that load and shows its content", arguments: Section.allCases)
  func copyWaitsForTheLoadInFlight(section: Section) async throws {
    let server = ProfileSectionStubProtocol.makeServer()
    defer { ProfileSectionStubProtocol.release(server) }
    defer { server.releaseHeldPages() }
    let viewModel = try await Self.makeLoadedViewModel(server: server, viewer: ProfileSectionStubServer.ownerDID)
    server.holdNextFirstPage(of: section, answering: 200)

    let first = try await Self.startHeldFirstLoad(of: section, on: viewModel, server: server)
    let second = try await Self.startWaitingCopy(of: section, on: viewModel)

    server.releaseHeldPages()
    try await first.value
    // The section's content was there when the second copy's load returned, from one request.
    #expect(try await second.value == 1)
    #expect(server.requestCount(section) == 1)
  }

  @Test("Copies that waited for a load that failed load the section themselves", arguments: Section.allCases)
  func copiesLoadWhenTheLoadTheyWaitedForFails(section: Section) async throws {
    let server = ProfileSectionStubProtocol.makeServer()
    defer { ProfileSectionStubProtocol.release(server) }
    defer { server.releaseHeldPages() }
    let viewModel = try await Self.makeLoadedViewModel(server: server, viewer: ProfileSectionStubServer.ownerDID)
    server.holdNextFirstPage(of: section, answering: 400)

    let first = try await Self.startHeldFirstLoad(of: section, on: viewModel, server: server)
    let second = try await Self.startWaitingCopy(of: section, on: viewModel)
    let third = try await Self.startWaitingCopy(of: section, on: viewModel)

    server.releaseHeldPages()
    await #expect(throws: (any Error).self) { try await first.value }
    #expect(try await second.value == 1)
    #expect(try await third.value == 1)
    // The retry succeeds, so one more request in total: the copy that resumes second waits for
    // the load the other one started.
    #expect(server.requestCount(section) == 2)
  }

  @Test("Each waiting copy loads at most once when the failure persists", arguments: Section.allCases)
  func eachWaitingCopyLoadsAtMostOnce(section: Section) async throws {
    let server = ProfileSectionStubProtocol.makeServer()
    defer { ProfileSectionStubProtocol.release(server) }
    defer { server.releaseHeldPages() }
    let viewModel = try await Self.makeLoadedViewModel(server: server, viewer: ProfileSectionStubServer.ownerDID)
    server.holdNextFirstPage(of: section, answering: 400)
    server.failNextFirstPages(of: section, count: 2)

    let first = try await Self.startHeldFirstLoad(of: section, on: viewModel, server: server)
    let second = try await Self.startWaitingCopy(of: section, on: viewModel)
    let third = try await Self.startWaitingCopy(of: section, on: viewModel)

    server.releaseHeldPages()
    await #expect(throws: (any Error).self) { try await first.value }
    // Each copy ends with the error of its own attempt.
    await #expect(throws: (any Error).self) { try await second.value }
    await #expect(throws: (any Error).self) { try await third.value }
    // One more request per waiting copy, one after another, and no more.
    #expect(server.requestCount(section) == 3)
  }

  @Test("A copy that waited for a load that was cancelled loads the section itself", arguments: Section.allCases)
  func copyLoadsWhenTheLoadItWaitedForIsCancelled(section: Section) async throws {
    let server = ProfileSectionStubProtocol.makeServer()
    defer { ProfileSectionStubProtocol.release(server) }
    defer { server.releaseHeldPages() }
    let viewModel = try await Self.makeLoadedViewModel(server: server, viewer: ProfileSectionStubServer.ownerDID)
    server.holdNextFirstPage(of: section, answering: 200)

    let first = try await Self.startHeldFirstLoad(of: section, on: viewModel, server: server)
    let second = try await Self.startWaitingCopy(of: section, on: viewModel)

    // The first copy's view goes away, which cancels its request.
    first.cancel()
    try await Self.waitUntil("the cancelled request to stop") { server.cancelledHeldRequestCount == 1 }
    await #expect(throws: (any Error).self) { try await first.value }
    #expect(try await second.value == 1)
    #expect(server.requestCount(section) == 2)
  }

  @Test(
    "A copy cancelled while it waits throws CancellationError and does not load",
    arguments: Section.allCases, [200, 400]
  )
  func cancelledCopyDoesNotLoad(section: Section, awaitedStatus: Int) async throws {
    let server = ProfileSectionStubProtocol.makeServer()
    defer { ProfileSectionStubProtocol.release(server) }
    defer { server.releaseHeldPages() }
    let viewModel = try await Self.makeLoadedViewModel(server: server, viewer: ProfileSectionStubServer.ownerDID)
    server.holdNextFirstPage(of: section, answering: awaitedStatus)

    let first = try await Self.startHeldFirstLoad(of: section, on: viewModel, server: server)
    let second = try await Self.startWaitingCopy(of: section, on: viewModel)

    second.cancel()
    server.releaseHeldPages()
    if awaitedStatus == 200 {
      try await first.value
    } else {
      await #expect(throws: (any Error).self) { try await first.value }
    }
    // Whether the load it waited for succeeded or failed.
    await #expect(throws: CancellationError.self) { try await second.value }
    #expect(server.requestCount(section) == 1)
    #expect(Self.count(of: section, in: viewModel) == (awaitedStatus == 200 ? 1 : 0))
  }

  // MARK: - First and next pages of one section

  @Test("A next page returns at once while its section's first page is loading", arguments: Section.allCases)
  func nextPageReturnsWhileTheFirstPageLoads(section: Section) async throws {
    let server = ProfileSectionStubProtocol.makeServer()
    defer { ProfileSectionStubProtocol.release(server) }
    defer { server.releaseHeldPages() }
    let viewModel = try await Self.makeLoadedViewModel(server: server, viewer: ProfileSectionStubServer.ownerDID)
    // A first page gives the section a cursor, so a next page gets past its own guard.
    try await Self.refresh(section, on: viewModel)
    server.holdNextFirstPage(of: section, answering: 200)
    let first = try await Self.startHeldFirstLoad(of: section, on: viewModel, server: server)

    let nextPage = Self.start { await Self.loadNextPage(of: section, on: viewModel) }
    try await Self.waitUntil("the next page to return while the first page is held") { nextPage.hasEnded }
    #expect(server.requestCount(section) == 2)

    server.releaseHeldPages()
    try await first.value
    #expect(Self.count(of: section, in: viewModel) == 1)
    #expect(server.requestCount(section) == 2)
  }

  @Test("A first load stops its section's next page and loads the first page itself", arguments: Section.allCases)
  func firstLoadReplacesTheNextPageInFlight(section: Section) async throws {
    let server = ProfileSectionStubProtocol.makeServer()
    defer { ProfileSectionStubProtocol.release(server) }
    defer { server.releaseHeldPages() }
    let viewModel = try await Self.makeLoadedViewModel(server: server, viewer: ProfileSectionStubServer.ownerDID)
    try await Self.refresh(section, on: viewModel)
    // The server holds every next page, so this one stays in flight until released.
    let nextPage = Task { await Self.loadNextPage(of: section, on: viewModel) }
    try await Self.waitUntil { server.heldRequestCount == 1 }

    // Another copy opens, or the section is pulled to refresh. Its first load neither waits for
    // that page nor takes it as its own content.
    let copy = Self.start { try await Self.refresh(section, on: viewModel) }
    try await Self.waitUntil("the first load to return while the next page is held") { copy.hasEnded }
    #expect(copy.error == nil)
    #expect(server.cancelledHeldRequestCount == 1)
    #expect(server.requestCount(section) == 3)
    await nextPage.value
    #expect(Self.count(of: section, in: viewModel) == 1)
  }

  @Test("An account switch stops a section's load in flight and forgets its next page", arguments: Section.allCases)
  func accountSwitchStopsTheLoadInFlight(section: Section) async throws {
    let server = ProfileSectionStubProtocol.makeServer()
    defer { ProfileSectionStubProtocol.release(server) }
    defer { server.releaseHeldPages() }
    let viewModel = try await Self.makeLoadedViewModel(server: server, viewer: ProfileSectionStubServer.ownerDID)
    try await Self.refresh(section, on: viewModel)
    server.holdNextFirstPage(of: section, answering: 200)
    let first = try await Self.startHeldFirstLoad(of: section, on: viewModel, server: server)

    await viewModel.handleStateInvalidation(.accountSwitched)
    try await Self.waitUntil("the held request to stop") { server.cancelledHeldRequestCount == 1 }
    await #expect(throws: (any Error).self) { try await first.value }
    #expect(Self.count(of: section, in: viewModel) == 0)

    // Loaded again, the profile has no cursor from before the switch, so no next page loads.
    await viewModel.loadProfile()
    let nextPage = Self.start { await Self.loadNextPage(of: section, on: viewModel) }
    try await Self.waitUntil("the next page to return") { nextPage.hasEnded }
    #expect(server.requestCount(section) == 2)
  }

}

// MARK: - Helpers

@MainActor
extension ProfileSectionLoadingTests {
  /// A view model for the stub's profile, seen by `viewer`. The owner sees their own Likes,
  /// which load through getActorLikes.
  private static func makeLoadedViewModel(
    server: ProfileSectionStubServer, viewer: String = "did:plc:sectionviewer"
  ) async throws -> ProfileViewModel {
    let client = try await ModerationStateNetworkHook.withProtocol(ProfileSectionStubProtocol.self) {
      await ATProtoClient(baseURL: server.baseURL)
    }
    let viewModel = ProfileViewModel(
      client: client, userDID: ProfileSectionStubServer.ownerDID, currentUserDID: viewer
    )
    await viewModel.loadProfile()
    try #require(viewModel.profile != nil, "getProfile stub did not load: \(String(describing: viewModel.error))")
    return viewModel
  }

  /// Starts a copy's first load of `section` and returns once the server holds its request.
  private static func startHeldFirstLoad(
    of section: Section, on viewModel: ProfileViewModel, server: ProfileSectionStubServer
  ) async throws -> Task<Void, Error> {
    let heldBefore = server.heldRequestCount
    let load = Task { try await Self.refresh(section, on: viewModel) }
    try await waitUntil("the first copy's request to reach the stub server") {
      server.heldRequestCount == heldBefore + 1
    }
    return load
  }

  /// Starts another copy's first load of `section`, which returns the section's item count when
  /// it ends, and returns once that copy waits for the load in flight.
  private static func startWaitingCopy(
    of section: Section, on viewModel: ProfileViewModel
  ) async throws -> Task<Int, Error> {
    let waitersBefore = waiters(of: section, in: viewModel)
    let load = Task {
      try await Self.refresh(section, on: viewModel)
      return Self.count(of: section, in: viewModel)
    }
    try await waitUntil("the copy to wait for the load in flight") {
      waiters(of: section, in: viewModel) == waitersBefore + 1
    }
    return load
  }

  /// A load the test checks on without awaiting it, so a load that wrongly waits for a held page
  /// fails the test instead of hanging it until the page is released.
  @MainActor
  final class StartedLoad {
    fileprivate(set) var hasEnded = false
    fileprivate(set) var error: (any Error)?
  }

  private static func start(_ body: @escaping @MainActor () async throws -> Void) -> StartedLoad {
    let load = StartedLoad()
    Task {
      do { try await body() } catch { load.error = error }
      load.hasEnded = true
    }
    return load
  }

  private static func refresh(_ section: Section, on viewModel: ProfileViewModel) async throws {
    switch section {
    case .likes: try await viewModel.refreshLikes()
    case .lists: try await viewModel.refreshLists()
    case .starterPacks: try await viewModel.refreshStarterPacks()
    case .feeds: try await viewModel.refreshFeeds()
    }
  }

  private static func loadNextPage(of section: Section, on viewModel: ProfileViewModel) async {
    switch section {
    case .likes: await viewModel.loadMoreLikes()
    case .lists: await viewModel.loadMoreLists()
    case .starterPacks: await viewModel.loadStarterPacks()
    case .feeds: await viewModel.loadMoreFeeds()
    }
  }

  private static func count(of section: Section, in viewModel: ProfileViewModel) -> Int {
    switch section {
    case .likes: viewModel.likes.count
    case .lists: viewModel.lists.count
    case .starterPacks: viewModel.starterPacks.count
    case .feeds: viewModel.feeds.count
    }
  }

  private static func waiters(of section: Section, in viewModel: ProfileViewModel) -> Int {
    let moreSection: ProfileViewModel.MoreSection =
      switch section {
      case .likes: .likes
      case .lists: .lists
      case .starterPacks: .starterPacks
      case .feeds: .feeds
      }
    return viewModel.sectionLoadWaiters[moreSection, default: 0]
  }

  private struct TimedOut: Error {}

  private static func waitUntil(
    _ what: String = "the next page to reach the stub server", _ condition: () -> Bool
  ) async throws {
    for _ in 0..<500 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for \(what)")
    throw TimedOut()
  }
}
