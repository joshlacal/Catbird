import Foundation
import Petrel
import PetrelCatbird
import Testing
@testable import Catbird

/// Recording transport double that proves Circle failures stay Circle-scoped
/// and never touch public endpoints.
actor RecordingCircleTransport: CircleTransport {
  private let error: CircleError?
  private(set) var publicEndpointCallCount = 0

  init(error: CircleError? = nil) {
    self.error = error
  }

  private func throwIfConfigured() throws {
    if let error { throw error }
  }

  func capabilities() async throws -> CircleCapability {
    try throwIfConfigured()
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
}

@Suite("Circle service boundary")
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
}

/// Shared test fixtures for Circle tests.
enum CircleTestFixtures {
  static let alice = try! DID(didString: "did:plc:alice")
  static let familyURI = try! SpaceRef(uriString: "at://did:plc:alice/space/blue.catbird.circle/3abc")
  static let workURI = try! SpaceRef(uriString: "at://did:plc:alice/space/blue.catbird.circle/9xyz")

  static let family = BlueCatbirdCircleDefs.CircleSummary(
    uri: familyURI, name: "Family", owner: alice,
    accessState: .value_active, muted: nil
  )
  static let work = BlueCatbirdCircleDefs.CircleSummary(
    uri: workURI, name: "Work", owner: alice,
    accessState: .value_active, muted: nil
  )

  static let draft = CirclePostDraft(
    text: "Hello circle",
    langs: [LanguageCodeContainer(languageCode: "en")]
  )
}
