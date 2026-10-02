import Foundation
import Petrel
import PetrelCatbird
import Testing
@testable import Catbird

/// Recording transport double that proves Circle failures stay Circle-scoped
/// and never touch public endpoints.
actor RecordingCircleTransport: CircleTransport {
  private let error: (any Error)?
  private let customCapabilities: CircleCapability?
  private(set) var publicEndpointCallCount = 0
  private var pauseCapabilities = false
  private var capabilityContinuation: CheckedContinuation<Void, Never>?
  private var startedContinuation: CheckedContinuation<Void, Never>?
  private var capabilityStarted = false

  func suspendCapabilities() { pauseCapabilities = true }

  func waitForCapabilities() async {
    if capabilityStarted { return }
    await withCheckedContinuation { startedContinuation = $0 }
  }

  func resumeCapabilities() {
    capabilityContinuation?.resume()
    capabilityContinuation = nil
  }

  init(error: (any Error)? = nil, capabilities: CircleCapability? = nil) {
    self.error = error
    self.customCapabilities = capabilities
  }

  private func throwIfConfigured() throws {
    if let error { throw error }
  }

  func capabilities() async throws -> CircleCapability {
    capabilityStarted = true
    startedContinuation?.resume()
    startedContinuation = nil
    if pauseCapabilities {
      await withCheckedContinuation { capabilityContinuation = $0 }
    }
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

  func updatePreferences(space: SpaceRef, muted: Bool) async throws -> Bool {
    try throwIfConfigured()
    return muted
  }

  func report(post: ATProtocolURI, circle: CircleSummary, reason: CircleReportReason, details: String?) async throws -> UUID {
    try throwIfConfigured()
    return UUID()
  }

  func activateCircle(space: SpaceRef) async throws -> CircleSummary {
    try throwIfConfigured()
    return CircleTestFixtures.family
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

  func createSpace(skey: String, circleId: String, name: String, memberDIDs: [DID]) async throws -> CircleSummary {
    try throwIfConfigured()
    return CircleTestFixtures.family
  }

  func deleteSpace(space: SpaceRef) async throws {
    try throwIfConfigured()
  }

  func addMember(space: SpaceRef, did: DID) async throws {
    try throwIfConfigured()
  }

  func removeMember(space: SpaceRef, did: DID) async throws {
    try throwIfConfigured()
  }

  func listMembers(space: SpaceRef) async throws -> [DID] {
    try throwIfConfigured()
    return []
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
    let summary = try await service.activateCircle(space: CircleTestFixtures.family.uri)
    #expect(summary.uri == CircleTestFixtures.family.uri)
  }

  @Test("CircleService deleteLike forwards to transport and stays Circle scoped")
  func circleServiceDeleteLikeForwardsToTransport() async throws {
    let transport = RecordingCircleTransport()
    let service = CircleService(transport: transport)
    let likeURI = try ATProtocolURI(uriString: "\(CircleTestFixtures.familyURI.uriString())/app.bsky.feed.like/testlike456")
    try await service.deleteLike(uri: likeURI, circle: CircleTestFixtures.family)
    #expect(await transport.publicEndpointCallCount == 0)
  }

  @Test("Capability results belong to the active account", arguments: [true, false])
  func activeAccountCapability(enabled: Bool) async {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:alice", client: client)
    #expect(appState.circleCapability == .unknown)
    #expect(!appState.circlesEnabled)
    let previousLifecycle = AppStateManager.shared.lifecycle
    AppStateManager.shared.setLifecycleForTesting(.authenticated(appState))
    defer { AppStateManager.shared.setLifecycleForTesting(previousLifecycle) }
    appState.circleService = CircleService(transport: RecordingCircleTransport(
      capabilities: CircleCapability(enabled: enabled, protocolRevision: "test", supportsImages: true)
    ))
    await appState.probeCircleCapabilities()
    #expect(appState.circleCapability == (enabled ? .supported : .unsupported))
    #expect(appState.circlesEnabled == enabled)
  }

  @Test("Unsupported is distinct from network and authorization failures")
  func probeClassifiesErrorsWithoutRetainingSupportedState() async {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:alice", client: client)
    let previousLifecycle = AppStateManager.shared.lifecycle
    AppStateManager.shared.setLifecycleForTesting(.authenticated(appState))
    defer { AppStateManager.shared.setLifecycleForTesting(previousLifecycle) }
    let cases: [(any Error, CircleCapabilityState)] = [
      (CircleError.unsupportedPDS, .unsupported),
      (CircleError.authRequired, .unknown),
      (CircleError.notAuthorized, .unknown),
      (CircleError.upstreamUnavailable, .unknown),
      (CircleError.invalidResponse, .unknown),
      (URLError(.timedOut), .unknown),
      (URLError(.notConnectedToInternet), .unknown),
      (ATProtoXRPCError(error: "ExpiredToken", message: "Expired", statusCode: 401), .unknown)
    ]
    for (error, expected) in cases {
      appState.circleCapability = .supported
      appState.circleService = CircleService(transport: RecordingCircleTransport(error: error))
      await appState.probeCircleCapabilities()
      #expect(appState.circleCapability == expected)
      #expect(!appState.circlesEnabled)
    }
  }

  @Test("An in-flight probe cannot update a replacement session, even for the same DID",
        arguments: ["did:plc:alice", "did:plc:bob"])
  func staleInFlightProbeIsDiscarded(replacementDID: String) async {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let stale = AppState(userDID: "did:plc:alice", client: client)
    let replacement = AppState(userDID: replacementDID, client: client)
    let previousLifecycle = AppStateManager.shared.lifecycle
    AppStateManager.shared.setLifecycleForTesting(.authenticated(stale))
    defer { AppStateManager.shared.setLifecycleForTesting(previousLifecycle) }
    let transport = RecordingCircleTransport()
    await transport.suspendCapabilities()
    stale.circleService = CircleService(transport: transport)
    let probe = Task { await stale.probeCircleCapabilities() }
    await transport.waitForCapabilities()
    AppStateManager.shared.setLifecycleForTesting(.authenticated(replacement))
    await transport.resumeCapabilities()
    await probe.value
    #expect(stale.circleCapability == .unknown)
    #expect(replacement.circleCapability == .unknown)
    #expect(!replacement.circlesEnabled)
  }

  @Test("Replacing a client invalidates support and rejects the old client's in-flight probe")
  func replacingClientInvalidatesCapabilityAndPendingProbe() async {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:alice", client: client)
    let previousLifecycle = AppStateManager.shared.lifecycle
    AppStateManager.shared.setLifecycleForTesting(.authenticated(appState))
    defer { AppStateManager.shared.setLifecycleForTesting(previousLifecycle) }

    appState.circleCapability = .supported
    let replacement = await ATProtoClient(baseURL: URL(string: "https://replacement.example")!)
    appState.updateClient(replacement)
    #expect(appState.circleCapability == .unknown)
    #expect(!appState.circlesEnabled)

    let transport = RecordingCircleTransport()
    await transport.suspendCapabilities()
    appState.circleService = CircleService(transport: transport)
    let probe = Task { await appState.probeCircleCapabilities() }
    await transport.waitForCapabilities()
    appState.updateClient(client)
    #expect(appState.circleCapability == .unknown)
    await transport.resumeCapabilities()
    await probe.value
    #expect(appState.circleCapability == .unknown)
    #expect(!appState.circlesEnabled)
  }

  @Test("Cancelled probe cannot enable Circles")
  func cancelledProbeIsDiscarded() async {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:alice", client: client)
    let previousLifecycle = AppStateManager.shared.lifecycle
    AppStateManager.shared.setLifecycleForTesting(.authenticated(appState))
    defer { AppStateManager.shared.setLifecycleForTesting(previousLifecycle) }
    let transport = RecordingCircleTransport()
    await transport.suspendCapabilities()
    appState.circleService = CircleService(transport: transport)
    let probe = Task { await appState.probeCircleCapabilities() }
    await transport.waitForCapabilities()
    probe.cancel()
    await transport.resumeCapabilities()
    await probe.value
    #expect(appState.circleCapability == .unknown)
    #expect(!appState.circlesEnabled)
  }

  @Test("Only documented Spaces unsupported status and code pairs are definitive")
  func unsupportedErrorClassification() {
    let cases: [(Int, String, Bool)] = [
      (501, "MethodNotImplemented", true),
      (404, "permissioned_endpoint_unavailable", true),
      (404, "MethodNotImplemented", false),
      (501, "permissioned_endpoint_unavailable", false),
      (404, "NotFound", false),
      (500, "InternalServerError", false),
      (401, "AuthRequired", false),
      (403, "Forbidden", false),
      (429, "RateLimitExceeded", false),
      (501, "NotImplemented", false)
    ]
    for (status, code, expected) in cases {
      let error = ATProtoXRPCError(error: code, message: "test", statusCode: status)
      #expect(GatewayCircleTransport.isUnsupportedSpacesError(error) == expected)
    }
    #expect(!GatewayCircleTransport.isUnsupportedSpacesError(URLError(.timedOut)))
    #expect(!GatewayCircleTransport.isUnsupportedSpacesError(CircleError.upstreamUnavailable))
  }

}

/// Shared test fixtures for Circle tests.
enum CircleTestFixtures {
  static let alice = try! DID(didString: "did:plc:alice")
  static let familyURI = try! SpaceRef(uriString: "at://did:plc:alice/space/blue.catbird.circle/3abc")
  static let familyCircleId = try! TID(tidString: "3l7familycirc")
  static let workURI = try! SpaceRef(uriString: "at://did:plc:alice/space/blue.catbird.circle/9xyz")
  static let workCircleId = try! TID(tidString: "3l7workcircle")

  static let family = BlueCatbirdCircleDefs.CircleSummary(
    uri: familyURI,
    circleId: familyCircleId,
    name: "Family",
    owner: alice,
    memberCount: 1,
    muted: nil
  )
  static let work = BlueCatbirdCircleDefs.CircleSummary(
    uri: workURI,
    circleId: workCircleId,
    name: "Work",
    owner: alice,
    memberCount: 2,
    muted: nil
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
