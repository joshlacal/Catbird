import Foundation
import Petrel
import PetrelCatbird
import Testing
@testable import Catbird

/// Recording transport to verify private Circle moderation and assert zero public fallback.
actor ModerationRecordingCircleTransport: CircleTransport {
  private(set) var publicEndpointCallCount = 0
  private(set) var reports: [(post: ATProtocolURI, circle: CircleSummary, reason: CircleReportReason, details: String?)] = []
  var reportError: CircleError?

  init(reportError: CircleError? = nil) {
    self.reportError = reportError
  }

  func capabilities() async throws -> CircleCapability {
    CircleCapability(enabled: true, protocolRevision: "0.1.0", supportsImages: true)
  }

  func listCircles(cursor: String?) async throws -> CircleListPage {
    CircleListPage(circles: [], cursor: nil)
  }

  func getFeed(space: SpaceRef?, cursor: String?) async throws -> CircleFeedPage {
    CircleFeedPage(items: [], cursor: nil)
  }

  func getPostThread(uri: ATProtocolURI, space: SpaceRef) async throws -> CircleThreadPage {
    let author = AppBskyActorDefs.ProfileViewBasic(
      did: try! DID(didString: "did:plc:alice"),
      handle: try! Handle(handleString: "alice.bsky.social"),
      displayName: nil,
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
    let post = AppBskyFeedPost(
      text: "Thread root post",
      entities: nil,
      facets: nil,
      reply: nil,
      embed: nil,
      langs: [],
      labels: nil,
      tags: nil,
      createdAt: ATProtocolDate(date: Date())
    )
    let postView = AppBskyFeedDefs.PostView(
      uri: uri,
      cid: CID.fromDAGCBOR(Data("test-thread-root".utf8)),
      author: author,
      record: ATProtocolValueContainer.knownType(post),
      embed: nil,
      bookmarkCount: nil,
      replyCount: 0,
      repostCount: 0,
      likeCount: 0,
      quoteCount: 0,
      indexedAt: ATProtocolDate(date: Date()),
      viewer: nil,
      labels: nil,
      threadgate: nil,
      debug: nil
    )
    let thread = AppBskyFeedDefs.ThreadViewPost(
      post: postView,
      parent: nil,
      replies: nil,
      threadContext: nil
    )
    return CircleThreadPage(thread: thread, circle: CircleTestFixtures.family)
  }

  func listNotifications(cursor: String?) async throws -> CircleNotificationPage {
    CircleNotificationPage(notifications: [], cursor: nil)
  }

  func media(space: SpaceRef, authorDID: DID, cid: CID) async throws -> Data {
    Data()
  }

  func updatePreferences(space: SpaceRef, muted: Bool) async throws -> Bool {
    muted
  }

  func report(
    post: ATProtocolURI,
    circle: CircleSummary,
    reason: CircleReportReason,
    details: String?
  ) async throws -> UUID {
    if let reportError { throw reportError }
    reports.append((post, circle, reason, details))
    return UUID()
  }

  func activateCircle(space: SpaceRef) async throws -> CircleSummary {
    CircleTestFixtures.family
  }

  func publishPost(destination: CircleSummary, draft: CirclePostDraft) async throws -> ATProtocolURI {
    try! ATProtocolURI(uriString: "\(destination.uri.uriString())/app.bsky.feed.post/test123")
  }

  func like(post: AppBskyFeedDefs.PostView, circle: CircleSummary) async throws -> ATProtocolURI {
    try! ATProtocolURI(uriString: "\(circle.uri.uriString())/app.bsky.feed.like/like123")
  }

  func deletePost(uri: ATProtocolURI, circle: CircleSummary) async throws {}

  func deleteLike(uri: ATProtocolURI, circle: CircleSummary) async throws {}

  func createSpace(skey: String, circleId: String, name: String, memberDIDs: [DID]) async throws -> CircleSummary {
    CircleTestFixtures.family
  }

  func deleteSpace(space: SpaceRef) async throws {}

  func addMember(space: SpaceRef, did: DID) async throws {}

  func removeMember(space: SpaceRef, did: DID) async throws {}

  func listMembers(space: SpaceRef) async throws -> [DID] {
    []
  }
}

@Suite("Circle Moderation and Private Reporting", .serialized)
struct CircleModerationTests {
  let privatePostURI = try! ATProtocolURI(uriString: "at://did:plc:alice/space/blue.catbird.circle/3abc/app.bsky.feed.post/post123")
  let family = CircleTestFixtures.family

  @Test func reportingCirclePostUsesPrivateCircleEndpoint() async throws {
    let transport = ModerationRecordingCircleTransport()
    let service = CircleService(transport: transport)

    let reportID = try await service.report(
      post: privatePostURI,
      circle: family,
      reason: .abuse,
      details: nil
    )

    #expect(!reportID.uuidString.isEmpty)
    #expect(await transport.publicEndpointCallCount == 0)
    let reports = await transport.reports
    #expect(reports.count == 1)
    #expect(reports.first?.post == privatePostURI)
    #expect(reports.first?.circle == family)
    #expect(reports.first?.reason == .abuse)
    #expect(reports.first?.details == nil)
  }

  @Test func reportingCirclePostSupportsAllReasonsAndDetails() async throws {
    let transport = ModerationRecordingCircleTransport()
    let service = CircleService(transport: transport)

    _ = try await service.report(
      post: privatePostURI,
      circle: family,
      reason: .spam,
      details: "Spam content detected"
    )

    _ = try await service.report(
      post: privatePostURI,
      circle: family,
      reason: .other,
      details: "Other policy violation"
    )

    let reports = await transport.reports
    #expect(reports.count == 2)
    #expect(reports[0].reason == .spam)
    #expect(reports[0].details == "Spam content detected")
    #expect(reports[1].reason == .other)
    #expect(reports[1].details == "Other policy violation")
    #expect(await transport.publicEndpointCallCount == 0)
  }

  @MainActor
  @Test func muteThreadIsNeverInvokedForCircleVisibilityContext() async throws {
    let client = await ATProtoClient(baseURL: URL(string: "https://invalid.example.com")!)
    let appState = AppState(userDID: "did:plc:alice", client: client)
    let postView = CircleTestFixtures.makePostView(uri: privatePostURI, authorDID: try! DID(didString: "did:plc:alice"), text: "Private Circle Post")
    let circleContext = PostVisibilityContext.circle(family)
    let contextMenuVM = PostContextMenuViewModel(appState: appState, post: postView, visibilityContext: circleContext)

    await contextMenuVM.muteThread()
    #expect(appState.toastManager.currentToast == nil)
  }
}
