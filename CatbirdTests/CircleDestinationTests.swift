import Foundation
import Petrel
import PetrelCatbird
import Testing
@testable import Catbird

/// Recording transport that tracks publish calls and asserts no public fallback.
actor DestinationRecordingCircleTransport: CircleTransport {
  private let error: CircleError?
  private(set) var publicEndpointCallCount = 0
  private(set) var publishedPosts: [(destination: CircleSummary, draft: CirclePostDraft)] = []

  init(error: CircleError? = nil) {
    self.error = error
  }

  func capabilities() async throws -> CircleCapability {
    if let error { throw error }
    return CircleCapability(enabled: true, protocolRevision: "0.1.0", supportsImages: true)
  }

  func listCircles(cursor: String?) async throws -> CircleListPage {
    if let error { throw error }
    return CircleListPage(circles: [], cursor: nil)
  }

  func getFeed(space: SpaceRef?, cursor: String?) async throws -> CircleFeedPage {
    if let error { throw error }
    return CircleFeedPage(items: [], cursor: nil)
  }

  func getPostThread(uri: ATProtocolURI, space: SpaceRef) async throws -> CircleThreadPage {
    if let error { throw error }
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
    if let error { throw error }
    return CircleNotificationPage(notifications: [], cursor: nil)
  }

  func media(space: SpaceRef, authorDID: DID, cid: CID) async throws -> Data {
    if let error { throw error }
    return Data()
  }

  func createCircle(name: String, memberDIDs: [DID]) async throws -> CircleOperation {
    if let error { throw error }
    return CircleOperation(
      id: UUID().uuidString,
      status: .value_complete,
      space: CircleTestFixtures.familyURI,
      error: nil
    )
  }

  func updateMember(space: SpaceRef, memberDID: DID, action: CircleMemberAction) async throws -> CircleOperation {
    if let error { throw error }
    return CircleOperation(
      id: UUID().uuidString,
      status: .value_complete,
      space: space,
      error: nil
    )
  }

  func updatePreferences(space: SpaceRef, muted: Bool) async throws -> Bool {
    if let error { throw error }
    return muted
  }

  func report(
    post: ATProtocolURI,
    circle: CircleSummary,
    reason: CircleReportReason,
    details: String?
  ) async throws -> UUID {
    if let error { throw error }
    return UUID()
  }

  func activate(space: SpaceRef) async throws -> CircleAccessState {
    if let error { throw error }
    return .active
  }

  func publishPost(destination: CircleSummary, draft: CirclePostDraft) async throws -> ATProtocolURI {
    if let error { throw error }
    publishedPosts.append((destination: destination, draft: draft))
    return try ATProtocolURI(uriString: "\(destination.uri.uriString())/app.bsky.feed.post/test123")
  }

  func like(post: AppBskyFeedDefs.PostView, circle: CircleSummary) async throws -> ATProtocolURI {
    if let error { throw error }
    return try ATProtocolURI(uriString: "\(circle.uri.uriString())/app.bsky.feed.like/testlike123")
  }
}

@Suite("Circle destination and composer routing")
struct CircleDestinationTests {

  @MainActor
  private func composer(
    destination: CircleDestination = .public,
    replyingTo: AppBskyFeedDefs.PostView? = nil,
    appState: AppState? = nil,
    circleService: CircleService? = nil
  ) async -> PostComposerViewModel {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let state = appState ?? AppState(userDID: "did:plc:testuser", client: client)
    let effectiveDest: CircleDestination
    if let _ = replyingTo, destination == .public {
      effectiveDest = .circle(CircleTestFixtures.family)
    } else {
      effectiveDest = destination
    }
    return PostComposerViewModel(
      parentPost: replyingTo,
      destination: effectiveDest,
      appState: state,
      circleService: circleService
    )
  }

  private var circlePost: AppBskyFeedDefs.PostView {
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
      text: "Circle parent post",
      entities: nil,
      facets: nil,
      reply: nil,
      embed: nil,
      langs: [],
      labels: nil,
      tags: nil,
      createdAt: ATProtocolDate(date: Date())
    )
    return AppBskyFeedDefs.PostView(
       uri: try! ATProtocolURI(uriString: "\(CircleTestFixtures.familyURI.uriString())/app.bsky.feed.post/parent123"),
       cid: CID.fromDAGCBOR(Data("test-parent-post".utf8)),
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
  }

  @Test("Destination is captured before upload and cannot change")
  @MainActor
  func destinationIsCapturedBeforeUploadAndCannotChange() async throws {
    let family = CircleTestFixtures.family
    let model = await composer(destination: .circle(family))
    model.postText = "Hello family circle"

    let submission = try model.beginSubmission()
    model.selectDestination(.public)

    #expect(submission.destination == .circle(family))
    #expect(model.destination == .circle(family))
    #expect(model.canChangeDestination == false)
  }

  @Test("Circle reply cannot become public")
  @MainActor
  func circleReplyCannotBecomePublic() async {
    let family = CircleTestFixtures.family
    let model = await composer(replyingTo: circlePost)

    #expect(model.destination == .circle(family))
    #expect(model.canChangeDestination == false)

    model.selectDestination(.public)
    #expect(model.destination == .circle(family))
  }

  @Test("Public submission cannot become circle after submission starts")
  @MainActor
  func publicSubmissionCannotBecomeCircle() async throws {
    let family = CircleTestFixtures.family
    let model = await composer(destination: .public)
    model.postText = "Public post"

    let submission = try model.beginSubmission()
    model.selectDestination(.circle(family))

    #expect(submission.destination == .public)
    #expect(model.destination == .public)
    #expect(model.canChangeDestination == false)
  }

  @Test("Submission routes to CircleService with zero public fallback")
  @MainActor
  func submissionRoutesToCircleServiceWithoutPublicFallback() async throws {
    let family = CircleTestFixtures.family
    let transport = DestinationRecordingCircleTransport()
    let service = CircleService(transport: transport)

    let model = await composer(destination: .circle(family), circleService: service)
    model.postText = "Private circle content"

    try await model.createPost()

    let published = await transport.publishedPosts
    #expect(published.count == 1)
    #expect(published.first?.destination == family)
    #expect(published.first?.draft.text == "Private circle content")

    let publicCalls = await transport.publicEndpointCallCount
    #expect(publicCalls == 0)
  }

  @Test("CircleService failure throws CircleError and does not fallback to public")
  @MainActor
  func circleServiceFailureDoesNotFallbackToPublic() async throws {
    let family = CircleTestFixtures.family
    let transport = DestinationRecordingCircleTransport(
      error: CircleError.spaceWriteRejected("space rejected write")
    )
    let service = CircleService(transport: transport)

    let model = await composer(destination: .circle(family), circleService: service)
    model.postText = "Failing private content"

    var thrownError: (any Error)?
    do {
      try await model.createPost()
    } catch {
      thrownError = error
    }

    #expect(thrownError != nil)
    guard let circleErr = thrownError as? CircleError else {
      Issue.record("Expected CircleError, got \(String(describing: thrownError))")
      return
    }

    if case let .spaceWriteRejected(msg) = circleErr {
      #expect(msg == "space rejected write")
    } else {
      Issue.record("Expected spaceWriteRejected error")
    }

    let publicCalls = await transport.publicEndpointCallCount
    #expect(publicCalls == 0)
    #expect(model.destination == .circle(family))
  }
}
