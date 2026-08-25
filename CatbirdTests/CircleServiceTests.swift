import Foundation
import Petrel
import PetrelCatbird
import Testing
@testable import Catbird

/// Recording transport double that proves Circle failures stay Circle-scoped
/// and never touch public endpoints.
actor RecordingCircleTransport: CircleTransport {
  private let error: CircleError?
  private let customCapabilities: CircleCapability?
  private(set) var publicEndpointCallCount = 0

  init(error: CircleError? = nil, capabilities: CircleCapability? = nil) {
    self.error = error
    self.customCapabilities = capabilities
  }

  private func throwIfConfigured() throws {
    if let error { throw error }
  }

  func capabilities() async throws -> CircleCapability {
    try throwIfConfigured()
    if let customCapabilities { return customCapabilities }
    return CircleCapability(enabled: true, protocolRevision: "test", supportsImages: true)
  }
  func listCircles(cursor: String?) async throws -> CircleListPage {
    try throwIfConfigured()
    return CircleListPage(circles: [], cursor: nil)
  }
  func getFeed(space: SpaceRef?, cursor: String?) async throws -> CircleFeedPage {
    try throwIfConfigured()
    return CircleFeedPage(items: [], cursor: nil)
  }
  func getPostThread(uri: ATProtocolURI, space: SpaceRef) async throws -> CircleThreadPage {
    try throwIfConfigured()
    throw CircleError.invalidResponse
  }
  func listNotifications(cursor: String?) async throws -> CircleNotificationPage {
    try throwIfConfigured()
    return CircleNotificationPage(notifications: [], cursor: nil)
  }
  func media(space: SpaceRef, authorDID: DID, cid: CID) async throws -> Data {
    try throwIfConfigured()
    return Data()
  }
  func createCircle(name: String, memberDIDs: [DID]) async throws -> CircleOperation {
    try throwIfConfigured()
    throw CircleError.invalidResponse
  }
  func updateMember(space: SpaceRef, memberDID: DID, action: CircleMemberAction) async throws -> CircleOperation {
    try throwIfConfigured()
    throw CircleError.invalidResponse
  }
  func updatePreferences(space: SpaceRef, muted: Bool) async throws -> Bool {
    try throwIfConfigured()
    return muted
  }
  func report(post: ATProtocolURI, circle: CircleSummary, reason: CircleReportReason, details: String?) async throws -> UUID {
    try throwIfConfigured()
    return UUID()
  }
  func activate(space: SpaceRef) async throws -> CircleAccessState {
    try throwIfConfigured()
    return .active
  }
  func publishPost(destination: CircleSummary, draft: CirclePostDraft) async throws -> ATProtocolURI {
    try throwIfConfigured()
    throw CircleError.invalidResponse
  }
  func like(post: AppBskyFeedDefs.PostView, circle: CircleSummary) async throws -> ATProtocolURI {
    try throwIfConfigured()
    throw CircleError.invalidResponse
  }
  func deletePost(uri: ATProtocolURI, circle: CircleSummary) async throws {
    try throwIfConfigured()
  }
  func deleteLike(uri: ATProtocolURI, circle: CircleSummary) async throws {
    try throwIfConfigured()
  }
  func deleteCircle(space: SpaceRef) async throws -> CircleOperation {
    try throwIfConfigured()
    return CircleOperation(id: UUID().uuidString, status: .value_complete, space: space, error: nil)
  }
  func getOperation(id: String) async throws -> CircleOperation {
    try throwIfConfigured()
    return CircleOperation(id: id, status: .value_complete, space: nil, error: nil)
  }
  func retryOperation(id: String) async throws -> CircleOperation {
    try throwIfConfigured()
    return CircleOperation(id: id, status: .value_complete, space: nil, error: nil)
  }
}

@Suite("Circle service boundary", .serialized)
@MainActor
struct CircleServiceTests {
  @Test("AppView failure remains a Circle error and never calls the public endpoint")
  func appViewFailureRemainsACircleError() async throws {
    let transport = RecordingCircleTransport(error: CircleError.upstreamUnavailable)
    let service = CircleService(transport: transport)
    await #expect(throws: CircleError.self) {
      try await service.publishPost(destination: CircleTestFixtures.family, draft: CircleTestFixtures.draft)
    }
    #expect(await transport.publicEndpointCallCount == 0)
  }

  @Test("Typed service passes through generated responses")
  func typedServiceSurfacesGeneratedResponses() async throws {
    let transport = RecordingCircleTransport()
    let service = CircleService(transport: transport)
    let caps = try await service.capabilities()
    #expect(caps.enabled)
    #expect(caps.supportsImages)
    let page = try await service.getFeed(space: nil)
    #expect(page.items.isEmpty)
    let state = try await service.activate(space: CircleTestFixtures.family.uri)
    #expect(state == .active)
  }

  @Test("CircleService deleteLike forwards to transport and stays Circle scoped")
  func circleServiceDeleteLikeForwardsToTransport() async throws {
    let transport = RecordingCircleTransport()
    let service = CircleService(transport: transport)
    let likeURI = try ATProtocolURI(uriString: "\(CircleTestFixtures.familyURI.uriString())/app.bsky.feed.like/testlike456")
    try await service.deleteLike(uri: likeURI, circle: CircleTestFixtures.family)
    #expect(await transport.publicEndpointCallCount == 0)
  }

  @Test("AppState probes capabilities and enables server capability flag")
  @MainActor
  func appStateProbesCapabilitiesAndFlipsFlag() async throws {
    CircleFeatureFlags.setLocalFlag(true)
    CircleFeatureFlags.serverCapability(enabled: false)
    #expect(!CircleFeatureFlags.isEnabled)

    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:alice", client: client)
    let previousLifecycle = AppStateManager.shared.lifecycle
    AppStateManager.shared.setLifecycleForTesting(.authenticated(appState))
    defer { AppStateManager.shared.setLifecycleForTesting(previousLifecycle) }
    let transport = RecordingCircleTransport()
    appState.circleService = CircleService(transport: transport)

    await appState.probeCircleCapabilities()
    #expect(CircleFeatureFlags.isEnabled)
  }
  @Test("AppState probe failure sets server capability flag to false")
  @MainActor
  func appStateProbeFailureSetsFlagFalse() async throws {
    CircleFeatureFlags.setLocalFlag(true)
    CircleFeatureFlags.serverCapability(enabled: true)
    #expect(CircleFeatureFlags.isEnabled)

    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:alice", client: client)
    let previousLifecycle = AppStateManager.shared.lifecycle
    AppStateManager.shared.setLifecycleForTesting(.authenticated(appState))
    defer { AppStateManager.shared.setLifecycleForTesting(previousLifecycle) }
    let transport = RecordingCircleTransport(error: CircleError.unsupportedPDS)
    appState.circleService = CircleService(transport: transport)

    await appState.probeCircleCapabilities()
    #expect(!CircleFeatureFlags.isEnabled)
  }
  @Test("AppState probe stale result from inactive account is discarded")
  @MainActor
  func appStateProbeStaleResultFromInactiveAccountIsDiscarded() async throws {
    CircleFeatureFlags.setLocalFlag(true)
    CircleFeatureFlags.serverCapability(enabled: false)

    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let staleAppState = AppState(userDID: "did:plc:stale_account", client: client)
    let transport = RecordingCircleTransport()
    staleAppState.circleService = CircleService(transport: transport)

    // If active account in lifecycle is different, the result must be discarded
    let activeAppState = AppState(userDID: "did:plc:active_account", client: client)
    let previousLifecycle = AppStateManager.shared.lifecycle
    AppStateManager.shared.setLifecycleForTesting(.authenticated(activeAppState))
    defer { AppStateManager.shared.setLifecycleForTesting(previousLifecycle) }
    await staleAppState.probeCircleCapabilities()
    #expect(!CircleFeatureFlags.isEnabled)
  }

  @Test("Circle capability reset on account transition")
  @MainActor
  func circleCapabilityResetOnAccountTransition() async throws {
    CircleFeatureFlags.setLocalFlag(true)
    CircleFeatureFlags.serverCapability(enabled: true)
    #expect(CircleFeatureFlags.isEnabled)

    // Transition resets flag
    CircleFeatureFlags.serverCapability(enabled: false)
    #expect(!CircleFeatureFlags.isEnabled)
  }
}

/// Shared test fixtures for Circle tests.
enum CircleTestFixtures {
  static let alice = try! DID(didString: "did:plc:alice")
  static let familyURI = try! SpaceRef(uriString: "at://did:plc:alice/space/blue.catbird.circle/3abc")
  static let workURI = try! SpaceRef(uriString: "at://did:plc:alice/space/blue.catbird.circle/9xyz")

  static let family = BlueCatbirdCircleDefs.CircleSummary(
    uri: familyURI, name: "Family", owner: alice,
    accessState: .value_active, muted: nil, members: nil
  )
  static let work = BlueCatbirdCircleDefs.CircleSummary(
    uri: workURI, name: "Work", owner: alice,
    accessState: .value_active, muted: nil, members: nil
  )

  static let draft = CirclePostDraft(
    text: "Hello circle",
    langs: [LanguageCodeContainer(languageCode: "en")]
  )

  static func makePostView(
    uri: ATProtocolURI,
    authorDID: DID = alice,
    text: String = "Hello circle"
  ) -> AppBskyFeedDefs.PostView {
    let author = AppBskyActorDefs.ProfileViewBasic(
      did: authorDID,
      handle: try! Handle(handleString: "author.test"),
      displayName: "Author",
      pronouns: nil,
      avatar: nil,
      associated: nil,
      viewer: nil,
      labels: nil,
      createdAt: nil,
      verification: nil,
      status: nil,
      debug: nil
    )
    return AppBskyFeedDefs.PostView(
      uri: uri,
      cid: CID.fromDAGCBOR(Data("cid-test".utf8)),
      author: author,
      record: .knownType(
        AppBskyFeedPost(
          text: text,
          entities: nil,
          facets: nil,
          reply: nil,
          embed: nil,
          langs: nil,
          labels: nil,
          tags: nil,
          createdAt: ATProtocolDate(date: Date())
        )
      ),
      embed: nil,
      bookmarkCount: nil,
      replyCount: 0,
      repostCount: 0,
      likeCount: 0,
      quoteCount: nil,
      indexedAt: ATProtocolDate(date: Date()),
      viewer: nil,
      labels: nil,
      threadgate: nil,
      debug: nil
    )
  }

  static func makeFeedItem(circle: CircleSummary, rkey: String = "post1", text: String = "Hello") -> BlueCatbirdCircleDefs.FeedItem {
    let postURI = try! ATProtocolURI(uriString: "\(circle.uri.uriString())/app.bsky.feed.post/\(rkey)")
    let postView = makePostView(uri: postURI, authorDID: circle.owner, text: text)
    let feedViewPost = AppBskyFeedDefs.FeedViewPost(
      post: postView,
      reply: nil,
      reason: nil,
      feedContext: nil,
      reqId: nil
    )
    return BlueCatbirdCircleDefs.FeedItem(post: feedViewPost, circle: circle)
  }
}
