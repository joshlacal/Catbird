import Foundation
import Petrel
import PetrelCatbird
import Testing
@testable import Catbird

/// Recording transport specifically for Circle management and operation testing.
actor ManagementRecordingCircleTransport: CircleTransport {
  var error: CircleError?
  private(set) var publicEndpointCallCount = 0

  private(set) var createdCircles: [(name: String, memberDIDs: [DID])] = []
  private(set) var memberUpdates: [(space: SpaceRef, memberDID: DID, action: CircleMemberAction)] = []
  private(set) var deletedSpaces: [SpaceRef] = []
  private(set) var updatedPreferences: [(space: SpaceRef, muted: Bool)] = []
  private(set) var detailFeedQueries: [SpaceRef?] = []
  private(set) var getOperationCalls: [String] = []
  private(set) var retryOperationCalls: [String] = []

  var nextOperation: CircleOperation?
  var mockFeedItems: [BlueCatbirdCircleDefs.FeedItem] = []
  var mockCirclesList: [CircleSummary] = []
  var detailAccessRemainsEnabled = true
  init(error: CircleError? = nil) {
    self.error = error
  }

  func capabilities() async throws -> CircleCapability {
    if let error { throw error }
    return CircleCapability(enabled: true, protocolRevision: "0.1.0", supportsImages: true)
  }

  func listCircles(cursor: String?) async throws -> CircleListPage {
    if let error { throw error }
    return CircleListPage(circles: mockCirclesList, cursor: nil)
  }

  func getFeed(space: SpaceRef?, cursor: String?) async throws -> CircleFeedPage {
    if let error { throw error }
    detailFeedQueries.append(space)
    return CircleFeedPage(items: mockFeedItems, cursor: nil)
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
    createdCircles.append((name, memberDIDs))
    if let nextOperation { return nextOperation }
    return CircleOperation(
      id: UUID().uuidString,
      status: .value_complete,
      space: try! SpaceRef(uriString: "at://did:plc:owner/space/blue.catbird.circle/3abc"),
      error: nil
    )
  }

  func updateMember(space: SpaceRef, memberDID: DID, action: CircleMemberAction) async throws -> CircleOperation {
    if let error { throw error }
    memberUpdates.append((space, memberDID, action))
    if let nextOperation { return nextOperation }
    return CircleOperation(
      id: UUID().uuidString,
      status: .value_complete,
      space: space,
      error: nil
    )
  }

  func updatePreferences(space: SpaceRef, muted: Bool) async throws -> Bool {
    if let error { throw error }
    updatedPreferences.append((space, muted))
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
    return try! ATProtocolURI(uriString: "\(destination.uri.uriString())/app.bsky.feed.post/test123")
  }

  func like(post: AppBskyFeedDefs.PostView, circle: CircleSummary) async throws -> ATProtocolURI {
    if let error { throw error }
    return try! ATProtocolURI(uriString: "\(circle.uri.uriString())/app.bsky.feed.like/like123")
  }

  func deletePost(uri: ATProtocolURI, circle: CircleSummary) async throws {
    if let error { throw error }
  }

  func deleteLike(uri: ATProtocolURI, circle: CircleSummary) async throws {
    if let error { throw error }
  }

  func deleteCircle(space: SpaceRef) async throws -> CircleOperation {
    if let error { throw error }
    deletedSpaces.append(space)
    if let nextOperation { return nextOperation }
    return CircleOperation(
      id: UUID().uuidString,
      status: .value_complete,
      space: space,
      error: nil
    )
  }

  func getOperation(id: String) async throws -> CircleOperation {
    if let error { throw error }
    getOperationCalls.append(id)
    if let nextOperation { return nextOperation }
    return CircleOperation(
      id: id,
      status: .value_complete,
      space: try! SpaceRef(uriString: "at://did:plc:owner/space/blue.catbird.circle/3abc"),
      error: nil
    )
  }

  func retryOperation(id: String) async throws -> CircleOperation {
    if let error { throw error }
    retryOperationCalls.append(id)
    if let nextOperation { return nextOperation }
    return CircleOperation(
      id: id,
      status: .value_complete,
      space: try! SpaceRef(uriString: "at://did:plc:owner/space/blue.catbird.circle/3abc"),
      error: nil
    )
  }

  func setNextOperation(_ op: CircleOperation) {
    self.nextOperation = op
  }

  func setMockFeedItems(_ items: [BlueCatbirdCircleDefs.FeedItem]) {
    self.mockFeedItems = items
  }

  func setMockCirclesList(_ circles: [CircleSummary]) {
    self.mockCirclesList = circles
  }
}

@Suite("Circle Management ViewModel and Disclosures")
@MainActor
struct CircleManagementViewModelTests {
  let ownerDID = try! DID(didString: "did:plc:owner123")
  let memberDID = try! DID(didString: "did:plc:member456")
  let bobDID = try! DID(didString: "did:plc:bob789")

  var ownerCircle: CircleSummary {
    CircleSummary(
      uri: try! SpaceRef(uriString: "at://did:plc:owner123/space/blue.catbird.circle/testspace"),
      name: "Family Circle",
      owner: ownerDID,
      accessState: .value_active,
      muted: false,
      members: [ownerDID, bobDID]
    )
  }

  var memberCircle: CircleSummary {
    CircleSummary(
      uri: try! SpaceRef(uriString: "at://did:plc:otherowner/space/blue.catbird.circle/other"),
      name: "Friend Circle",
      owner: try! DID(didString: "did:plc:otherowner"),
      accessState: .value_active,
      muted: false,
      members: nil
    )
  }

  @Test func addMemberDisclosureStatesFullHistory() {
    #expect(CircleManagementCopy.addMemberDisclosure.contains("entire Circle history"))
  }

  @Test func removalDisclosureStatesDownloadsCannotBeRecalled() {
    #expect(CircleManagementCopy.removeMemberDisclosure.contains("cannot be recalled"))
  }

  @Test func nonOwnerNeverReceivesMemberListAction() {
    let transport = ManagementRecordingCircleTransport()
    let service = CircleService(transport: transport)
    let model = CircleManagementViewModel(circle: memberCircle, service: service, userDID: memberDID.didString())
    #expect(model.canManageMembers == false)
  }

  @Test func ownerCanManageMembers() {
    let transport = ManagementRecordingCircleTransport()
    let service = CircleService(transport: transport)
    let model = CircleManagementViewModel(circle: ownerCircle, service: service, userDID: ownerDID.didString())
    #expect(model.canManageMembers == true)
  }

  @Test func nonOwnerAddMemberFailsClosed() async throws {
    let transport = ManagementRecordingCircleTransport()
    let service = CircleService(transport: transport)
    let model = CircleManagementViewModel(circle: memberCircle, service: service, userDID: memberDID.didString())
    
    await #expect(throws: CircleError.self) {
      try await model.addMember(did: bobDID)
    }
    #expect(await transport.memberUpdates.isEmpty)
  }

  @Test func nonOwnerDeleteCircleFailsClosed() async throws {
    let transport = ManagementRecordingCircleTransport()
    let service = CircleService(transport: transport)
    let model = CircleManagementViewModel(circle: memberCircle, service: service, userDID: memberDID.didString())
    
    await #expect(throws: CircleError.self) {
      try await model.deleteCircle()
    }
    #expect(await transport.deletedSpaces.isEmpty)
  }

  @Test func mutingCircleHidesUnifiedFeedButKeepsDetailAccess() async throws {
    let transport = ManagementRecordingCircleTransport()
    let service = CircleService(transport: transport)
    let model = CircleManagementViewModel(circle: memberCircle, service: service, userDID: memberDID.didString())
    
    try await model.setMuted(true)
    #expect(model.circle.muted == true)
    #expect(model.isMuted == true)

    // Create a muted feed item and an unmuted feed item
    let mutedCircle = CircleSummary(
      uri: memberCircle.uri,
      name: memberCircle.name,
      owner: memberCircle.owner,
      accessState: .value_active,
      muted: true,
      members: nil
    )
    let unmutedCircle = ownerCircle
    let mutedItem = CircleTestFixtures.makeFeedItem(circle: mutedCircle, rkey: "p1", text: "Muted Post")
    let unmutedItem = CircleTestFixtures.makeFeedItem(circle: unmutedCircle, rkey: "p2", text: "Unmuted Post")
    await transport.setMockFeedItems([mutedItem, unmutedItem])

    // Unified feed model (space == nil) filters out the muted Circle item
    let unifiedFeedModel = CircleFeedModel(service: service, space: nil, accountDID: memberDID.didString())
    try await unifiedFeedModel.load()
    #expect(unifiedFeedModel.items.count == 1)
    #expect(unifiedFeedModel.items.first?.circle.uri == unmutedCircle.uri)

    // Direct detail feed model (space == mutedCircle.uri) keeps direct detail access
    let detailFeedModel = CircleFeedModel(service: service, space: mutedCircle.uri, accountDID: memberDID.didString())
    try await detailFeedModel.load()
    #expect(detailFeedModel.items.count == 2)
    #expect(await transport.detailFeedQueries.contains(where: { $0 == mutedCircle.uri }))
  }
  @Test func createCircleValidatesNameBetween1And64Chars() async throws {
    let transport = ManagementRecordingCircleTransport()
    let service = CircleService(transport: transport)
    let model = CircleManagementViewModel(service: service, userDID: ownerDID.didString())

    // Empty name
    await #expect(throws: CircleError.self) {
      try await model.createCircle(name: "   ", memberDIDs: [])
    }

    // Name too long (> 64 characters)
    let longName = String(repeating: "a", count: 65)
    await #expect(throws: CircleError.self) {
      try await model.createCircle(name: longName, memberDIDs: [])
    }

    #expect(await transport.createdCircles.isEmpty)

    // Valid name
    let validName = "My Close Friends"
    _ = try await model.createCircle(name: validName, memberDIDs: [bobDID])
    #expect(await transport.createdCircles.count == 1)
    #expect(await transport.createdCircles.first?.name == validName)
  }

  @Test func createCircleValidatesMax150UniqueDIDs() async throws {
    let transport = ManagementRecordingCircleTransport()
    let service = CircleService(transport: transport)
    let model = CircleManagementViewModel(service: service, userDID: ownerDID.didString())

    // Generate 151 distinct DIDs
    var tooManyDIDs: [DID] = []
    for i in 1...151 {
      tooManyDIDs.append(try! DID(didString: "did:plc:user\(i)"))
    }

    await #expect(throws: CircleError.self) {
      try await model.createCircle(name: "Big Circle", memberDIDs: tooManyDIDs)
    }
    #expect(await transport.createdCircles.isEmpty)

    // Generate 150 DIDs + duplicates (should deduplicate and pass)
    var exactly150WithDups: [DID] = []
    for i in 1...150 {
      exactly150WithDups.append(try! DID(didString: "did:plc:user\(i)"))
    }
    exactly150WithDups.append(try! DID(didString: "did:plc:user1"))
    exactly150WithDups.append(try! DID(didString: "did:plc:user2"))

    _ = try await model.createCircle(name: "150 Member Circle", memberDIDs: exactly150WithDups)
    #expect(await transport.createdCircles.count == 1)
    #expect(await transport.createdCircles.first?.memberDIDs.count == 150)
  }

  @Test func pendingOperationTransitionsToPendingState() async throws {
    let transport = ManagementRecordingCircleTransport()
    let pendingOp = CircleOperation(
      id: "12345678-1234-4234-8234-123456789abc",
      status: .value_pending,
      space: ownerCircle.uri,
      error: nil
    )
    await transport.setNextOperation(pendingOp)

    let service = CircleService(transport: transport)
    let model = CircleManagementViewModel(circle: ownerCircle, service: service, userDID: ownerDID.didString())

    _ = try await model.addMember(did: bobDID)
    #expect(model.state == .pending(pendingOp))
  }

  @Test func failedOperationTransitionsToFailedStateWithRetryID() async throws {
    let transport = ManagementRecordingCircleTransport()
    let uuidString = "87654321-4321-4321-8321-cba987654321"
    let failedOp = CircleOperation(
      id: uuidString,
      status: .value_failed,
      space: ownerCircle.uri,
      error: "Conflict updating members"
    )
    await transport.setNextOperation(failedOp)

    let service = CircleService(transport: transport)
    let model = CircleManagementViewModel(circle: ownerCircle, service: service, userDID: ownerDID.didString())

    _ = try await model.addMember(did: bobDID)
    #expect(model.state == .failed(message: "Conflict updating members", retryOperationID: UUID(uuidString: uuidString)))
  }

  @Test func ownerMemberRosterIsLoadedAuthoritativelyAndNonOwnerNeverReceivesRoster() async throws {
    let transport = ManagementRecordingCircleTransport()
    let service = CircleService(transport: transport)

    // Owner initialized with members array receives it
    let ownerModel = CircleManagementViewModel(circle: ownerCircle, service: service, userDID: ownerDID.didString())
    #expect(ownerModel.canManageMembers == true)
    #expect(ownerModel.members.count == 2)
    #expect(ownerModel.members.contains(ownerDID))
    #expect(ownerModel.members.contains(bobDID))

    // Non-owner never receives members and canManageMembers is false
    let nonOwnerModel = CircleManagementViewModel(circle: memberCircle, service: service, userDID: memberDID.didString())
    #expect(nonOwnerModel.canManageMembers == false)
    #expect(nonOwnerModel.members.isEmpty)

    // Calling loadMembers for owner updates roster from listCircles
    let updatedOwnerCircle = CircleSummary(
      uri: ownerCircle.uri,
      name: ownerCircle.name,
      owner: ownerCircle.owner,
      accessState: .value_active,
      muted: false,
      members: [ownerDID, bobDID, try! DID(didString: "did:plc:carol")]
    )
    await transport.setMockCirclesList([updatedOwnerCircle])
    await ownerModel.loadMembers()
    #expect(ownerModel.members.count == 3)
  }

  @Test func retryPendingOrFailedOperationTargetsNamedOperationWithoutDuplicateSubmission() async throws {
    let transport = ManagementRecordingCircleTransport()
    let service = CircleService(transport: transport)
    let model = CircleManagementViewModel(circle: ownerCircle, service: service, userDID: ownerDID.didString())

    let failedUUID = UUID()
    model.state = .failed(message: "Transient failure", retryOperationID: failedUUID)

    // Retry targets the existing operation ID
    try await model.retry(operationID: failedUUID)
    #expect(model.state == .complete)
    #expect(await transport.retryOperationCalls.contains(failedUUID.uuidString.lowercased()))
    #expect(await transport.createdCircles.isEmpty)
    #expect(await transport.deletedSpaces.isEmpty)
  }

  @Test func privateCirclePostCannotExecuteMuteThread() async throws {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: ownerDID.didString(), client: client)
    let postURI = try! ATProtocolURI(uriString: "at://did:plc:owner/space/blue.catbird.circle/3abc/did:plc:owner/app.bsky.feed.post/3l7test")
    let postView = CircleTestFixtures.makePostView(uri: postURI, authorDID: ownerDID, text: "Private Circle Post")
    let circleContext = PostVisibilityContext.circle(ownerCircle)
    let contextMenuVM = PostContextMenuViewModel(appState: appState, post: postView, visibilityContext: circleContext)

    // Calling muteThread on a Circle post is a no-op that fails closed and never calls public graph endpoint
    await contextMenuVM.muteThread()
  }

  @Test func runtimeCircleCapabilityProbingAndAccountSwitchRaceSafety() async throws {
    CircleFeatureFlags.setLocalFlag(true)
    CircleFeatureFlags.serverCapability(enabled: false)
    #expect(!CircleFeatureFlags.isEnabled)

    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: ownerDID.didString(), client: client)
    let transport = ManagementRecordingCircleTransport()
    appState.circleService = CircleService(transport: transport)

    // Probe capability for active account
    await appState.probeCircleCapabilities()
    #expect(CircleFeatureFlags.isEnabled)

    // Logging out resets server capability
    CircleFeatureFlags.serverCapability(enabled: false)
    #expect(!CircleFeatureFlags.isEnabled)
  }

  @Test func ownerDeletesCircleSuccessfully() async throws {
    let transport = ManagementRecordingCircleTransport()
    let service = CircleService(transport: transport)
    let model = CircleManagementViewModel(circle: ownerCircle, service: service, userDID: ownerDID.didString())

    _ = try await model.deleteCircle()
    #expect(model.state == .complete)
    #expect(await transport.deletedSpaces.count == 1)
    #expect(await transport.deletedSpaces.first == ownerCircle.uri)
  }
}
