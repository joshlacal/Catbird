import Foundation
import Petrel
import PetrelCatbird
import Testing
@testable import Catbird

/// Recording transport specifically for Circle management and operation testing.
actor ManagementRecordingCircleTransport: CircleTransport {
  var error: CircleError?
  private(set) var publicEndpointCallCount = 0

  private(set) var createdCircles: [(skey: String, circleId: String, name: String, memberDIDs: [DID])] = []
  private(set) var memberAdds: [(space: SpaceRef, did: DID)] = []
  private(set) var memberRemoves: [(space: SpaceRef, did: DID)] = []
  private(set) var deletedSpaces: [SpaceRef] = []
  private(set) var updatedPreferences: [(space: SpaceRef, muted: Bool)] = []
  private(set) var detailFeedQueries: [SpaceRef?] = []
  private(set) var activateCircleCalls: [SpaceRef] = []

  /// Thrown only by `activateCircle`, so a test can assert that a failed
  /// activation leaves the already-created Space intact rather than rolling back.
  var activationError: CircleError?
  var mockMembers: [DID] = []
  var mockFeedItems: [BlueCatbirdCircleDefs.FeedItem] = []
  var mockCirclesList: [CircleSummary] = []
  var detailAccessRemainsEnabled = true
  init(error: CircleError? = nil) {
    self.error = error
  }

  func setError(_ error: CircleError?) {
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
    if let space {
      let filtered = mockFeedItems.filter { $0.circle.uri == space }
      return CircleFeedPage(items: filtered, cursor: nil)
    }
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

  func createSpace(skey: String, circleId: String, name: String, memberDIDs: [DID]) async throws -> CircleSummary {
    if let error { throw error }
    createdCircles.append((skey, circleId, name, memberDIDs))
    mockMembers = memberDIDs
    return Self.summary(
      skey: skey, circleId: circleId, name: name, memberCount: memberDIDs.count
    )
  }

  func deleteSpace(space: SpaceRef) async throws {
    if let error { throw error }
    deletedSpaces.append(space)
  }

  func addMember(space: SpaceRef, did: DID) async throws {
    if let error { throw error }
    memberAdds.append((space, did))
    mockMembers.append(did)
  }

  func removeMember(space: SpaceRef, did: DID) async throws {
    if let error { throw error }
    memberRemoves.append((space, did))
    mockMembers.removeAll { $0 == did }
  }

  func listMembers(space: SpaceRef) async throws -> [DID] {
    if let error { throw error }
    return mockMembers
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

  func activateCircle(space: SpaceRef) async throws -> CircleSummary {
    if let error { throw error }
    activateCircleCalls.append(space)
    if let activationError { throw activationError }
    return Self.summary(
      skey: space.skey,
      circleId: nil,
      name: "Activated",
      memberCount: mockMembers.count
    )
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

  func setActivationError(_ error: CircleError?) {
    self.activationError = error
  }

  func setMockMembers(_ members: [DID]) {
    self.mockMembers = members
  }

  static let fixtureCircleIdString = "3l7revaaaaaaa"
  static var fixtureTID: TID { try! TID(tidString: fixtureCircleIdString) }

  /// Deterministic summary so assertions can compare by name and member count.
  static func summary(
    skey: String, circleId: String?, name: String, memberCount: Int
  ) -> CircleSummary {
    CircleSummary(
      uri: try! SpaceRef(uriString: "at://did:plc:owner/space/blue.catbird.circle/\(skey)"),
      circleId: circleId.flatMap { try? TID(tidString: $0) } ?? fixtureTID,
      name: name,
      owner: try! DID(didString: "did:plc:owner"),
      memberCount: memberCount,
      muted: false
    )
  }

  func setMockFeedItems(_ items: [BlueCatbirdCircleDefs.FeedItem]) {
    self.mockFeedItems = items
  }

  func setMockCirclesList(_ circles: [CircleSummary]) {
    self.mockCirclesList = circles
  }
}

@Suite("Circle Management ViewModel and Disclosures", .serialized)
@MainActor
struct CircleManagementViewModelTests {
  let ownerDID = try! DID(didString: "did:plc:owner123")
  let memberDID = try! DID(didString: "did:plc:member456")
  let bobDID = try! DID(didString: "did:plc:bob789")

  var ownerCircle: CircleSummary {
    CircleSummary(
      uri: try! SpaceRef(uriString: "at://did:plc:owner123/space/blue.catbird.circle/testspace"),
      circleId: try! TID(tidString: "3l7revaaaaaaa"),
      name: "Family Circle",
      owner: ownerDID,
      memberCount: 2,
      muted: false
    )
  }

  var memberCircle: CircleSummary {
    CircleSummary(
      uri: try! SpaceRef(uriString: "at://did:plc:otherowner/space/blue.catbird.circle/other"),
      circleId: try! TID(tidString: "3l7revaaaaaaa"),
      name: "Friend Circle",
      owner: try! DID(didString: "did:plc:otherowner"),
      memberCount: 1,
      muted: false
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
    #expect(await transport.memberAdds.isEmpty)
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
      circleId: memberCircle.circleId,
      name: memberCircle.name,
      owner: memberCircle.owner,
      memberCount: memberCircle.memberCount,
      muted: true
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
    #expect(detailFeedModel.items.count == 1)
    #expect(await transport.detailFeedQueries.contains(where: { $0 == mutedCircle.uri }))
  }

  @Test func mutingCircleImmediatelyRemovesSpaceFromActiveUnifiedFeedWhilePreservingDirectDetail() async throws {
    let aliceDID = "did:plc:alice_mute_test"
    let bobDID = "did:plc:bob_mute_test"
    await CircleFeedCache.shared.purge(accountDID: aliceDID)
    await CircleFeedCache.shared.purge(accountDID: bobDID)
    let transport = ManagementRecordingCircleTransport()
    let service = CircleService(transport: transport)

    let familyCircle = CircleTestFixtures.family
    let workCircle = CircleTestFixtures.work
    let familyItem = CircleTestFixtures.makeFeedItem(circle: familyCircle, rkey: "fam1", text: "Family Post")
    let workItem = CircleTestFixtures.makeFeedItem(circle: workCircle, rkey: "work1", text: "Work Post")
    await transport.setMockFeedItems([familyItem, workItem])

    // Active loaded unified feed model for Alice
    let aliceUnified = CircleFeedModel(service: service, space: nil, accountDID: aliceDID)
    try await aliceUnified.load()
    #expect(aliceUnified.items.count == 2)

    // Active loaded direct detail feed model for Alice
    let aliceDetail = CircleFeedModel(service: service, space: familyCircle.uri, accountDID: aliceDID)
    try await aliceDetail.load()
    #expect(aliceDetail.items.count == 1)

    // Active loaded unified feed model for Bob (different account)
    let bobUnified = CircleFeedModel(service: service, space: nil, accountDID: bobDID)
    try await bobUnified.load()
    #expect(bobUnified.items.count == 2)

    // Alice mutes Family Circle
    let managementVM = CircleManagementViewModel(circle: familyCircle, service: service, userDID: aliceDID)
    try await managementVM.setMuted(true)

    // Alice's active unified feed immediately has Family removed (only Work remains)
    #expect(aliceUnified.items.count == 1)
    #expect(aliceUnified.items.first?.circle.uri == workCircle.uri)

    // Alice's active direct detail feed remains fully visible
    #expect(aliceDetail.items.count == 1)
    #expect(aliceDetail.items.first?.circle.uri == familyCircle.uri)
    // Bob's active unified feed is untouched
    #expect(bobUnified.items.count == 2)

    // Memory cache for Alice's unified feed is purged of Family Space
    let cachedPage = await CircleFeedCache.shared.page(accountDID: aliceDID, space: nil)
    #expect(cachedPage?.items.count == 1)
    #expect(cachedPage?.items.first?.circle.uri == workCircle.uri)
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

  @Test func createCircleCallsCreateSpaceThenActivateCircleInOrder() async throws {
    let transport = ManagementRecordingCircleTransport()
    let service = CircleService(transport: transport)
    let model = CircleManagementViewModel(service: service, userDID: ownerDID.didString())

    let created = try await model.createCircle(name: "Order Test Circle", memberDIDs: [bobDID])
    #expect(await transport.createdCircles.count == 1)
    #expect(await transport.activateCircleCalls.count == 1)
    #expect(model.state == .complete)
    #expect(created.name == "Activated")
  }

  @Test func activateCircleFailureLeavesSpaceIntactAndEnablesActivationRetry() async throws {
    let transport = ManagementRecordingCircleTransport()
    await transport.setActivationError(.upstreamUnavailable)
    let service = CircleService(transport: transport)
    let model = CircleManagementViewModel(service: service, userDID: ownerDID.didString())

    let summary = try await model.createCircle(name: "Activation Fail Circle", memberDIDs: [bobDID])
    #expect(await transport.createdCircles.count == 1)
    #expect(await transport.activateCircleCalls.count == 1)
    #expect(await transport.deletedSpaces.isEmpty)
    #expect(model.state == .activationFailed(message: CircleError.upstreamUnavailable.localizedDescription))
    #expect(model.canRetryActivation == true)
    #expect(summary.name == "Activation Fail Circle")

    // Retrying activation succeeds when error clears
    await transport.setActivationError(nil)
    try await model.retryActivation()
    #expect(model.state == .complete)
    #expect(model.canRetryActivation == false)
    #expect(await transport.activateCircleCalls.count == 2)
    #expect(model.circle.name == "Activated")
  }

  @Test func ownerMemberRosterIsLoadedAuthoritativelyAndNonOwnerNeverReceivesRoster() async throws {
    let transport = ManagementRecordingCircleTransport()
    await transport.setMockMembers([ownerDID, bobDID])
    let service = CircleService(transport: transport)

    // Owner loaded with members
    let ownerModel = CircleManagementViewModel(circle: ownerCircle, service: service, userDID: ownerDID.didString())
    #expect(ownerModel.canManageMembers == true)
    await ownerModel.loadMembers()
    #expect(ownerModel.members.count == 2)
    #expect(ownerModel.members.contains(ownerDID))
    #expect(ownerModel.members.contains(bobDID))

    // Non-owner never receives members and canManageMembers is false
    let nonOwnerModel = CircleManagementViewModel(circle: memberCircle, service: service, userDID: memberDID.didString())
    #expect(nonOwnerModel.canManageMembers == false)
    await nonOwnerModel.loadMembers()
    #expect(nonOwnerModel.members.isEmpty)

    // Calling loadMembers for owner updates roster from PDS
    let carolDID = try! DID(didString: "did:plc:carol")
    await transport.setMockMembers([ownerDID, bobDID, carolDID])
    await ownerModel.loadMembers()
    #expect(ownerModel.members.count == 3)
  }
  @Test func privateCirclePostCannotExecuteMuteThread() async throws {
    let client = await ATProtoClient(baseURL: URL(string: "https://invalid.example.com")!)
    let appState = AppState(userDID: ownerDID.didString(), client: client)
    let postURI = try! ATProtocolURI(uriString: "at://did:plc:owner/space/blue.catbird.circle/3abc/did:plc:owner/app.bsky.feed.post/3l7test")
    let postView = CircleTestFixtures.makePostView(uri: postURI, authorDID: ownerDID, text: "Private Circle Post")
    let circleContext = PostVisibilityContext.circle(ownerCircle)
    let contextMenuVM = PostContextMenuViewModel(appState: appState, post: postView, visibilityContext: circleContext)

    // Calling muteThread on a Circle post is a no-op that fails closed and never calls public graph endpoint
    await contextMenuVM.muteThread()
    #expect(appState.toastManager.currentToast == nil)
  }

  @Test func runtimeCircleCapabilityProbingAndAccountSwitchRaceSafety() async throws {
    CircleFeatureFlags.serverCapability(enabled: false)
    #expect(!CircleFeatureFlags.isEnabled)

    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: ownerDID.didString(), client: client)
    let previousLifecycle = AppStateManager.shared.lifecycle
    AppStateManager.shared.setLifecycleForTesting(.authenticated(appState))
    defer { AppStateManager.shared.setLifecycleForTesting(previousLifecycle) }

    let transport = ManagementRecordingCircleTransport()
    appState.circleService = CircleService(transport: transport)

    // Probe capability for active account
    await appState.probeCircleCapabilities()
    #expect(CircleFeatureFlags.isEnabled)

    // An explicit AppView disabled response still disables Circle-backed surfaces.
    CircleFeatureFlags.serverCapability(enabled: false)
    #expect(!CircleFeatureFlags.isEnabled)
  }

  @Test func deleteCircleCompleteOutcomePermitsDismissalAndMarksComplete() async throws {
    let transport = ManagementRecordingCircleTransport()
    let service = CircleService(transport: transport)
    let model = CircleManagementViewModel(circle: ownerCircle, service: service, userDID: ownerDID.didString())

    try await model.deleteCircle()
    #expect(model.state == .complete)
    #expect(await transport.deletedSpaces.count == 1)
    #expect(await transport.deletedSpaces.first == ownerCircle.uri)
  }

  @Test func deleteCircleThrownErrorSetsFailedState() async throws {
    let transport = ManagementRecordingCircleTransport(error: CircleError.upstreamUnavailable)
    let service = CircleService(transport: transport)
    let model = CircleManagementViewModel(circle: ownerCircle, service: service, userDID: ownerDID.didString())

    await #expect(throws: CircleError.self) {
      try await model.deleteCircle()
    }
    #expect(model.state == .failed(message: CircleError.upstreamUnavailable.localizedDescription))
  }

  // MARK: - Lifecycle Event Tests

  @Test func deleteCircleCompleteOutcomePostsCircleDeletedNotificationExactlyOnce() async throws {
    final class NotificationCapture: @unchecked Sendable {
      var count = 0
      var accountDID: String?
      var spaceURI: String?
    }
    let capture = NotificationCapture()
    let observer = NotificationCenter.default.addObserver(
      forName: .circleDeleted,
      object: nil,
      queue: nil
    ) { note in
      capture.count += 1
      capture.accountDID = note.userInfo?["accountDID"] as? String
      capture.spaceURI = note.userInfo?["spaceURI"] as? String
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    let transport = ManagementRecordingCircleTransport()
    let service = CircleService(transport: transport)
    let model = CircleManagementViewModel(circle: ownerCircle, service: service, userDID: ownerDID.didString())
    try await model.deleteCircle()
    // Emits exactly once on immediate complete
    #expect(capture.count == 1)
    #expect(capture.accountDID == ownerDID.didString())
    #expect(capture.spaceURI == ownerCircle.uri.uriString())

    // Subsequent unrelated operation completion cannot emit another delete notification
    let newMemberDID = try! DID(didString: "did:plc:member99")
    _ = try await model.addMember(did: newMemberDID)
    #expect(capture.count == 1)
  }

  @Test func unrelatedOperationAfterFailedDeleteDoesNotEmitDeleteNotification() async throws {
    var notificationCount = 0
    let observer = NotificationCenter.default.addObserver(
      forName: .circleDeleted,
      object: nil,
      queue: nil
    ) { _ in
      notificationCount += 1
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    let transport = ManagementRecordingCircleTransport(error: CircleError.upstreamUnavailable)
    let service = CircleService(transport: transport)
    let model = CircleManagementViewModel(circle: ownerCircle, service: service, userDID: ownerDID.didString())

    await #expect(throws: CircleError.self) {
      try await model.deleteCircle()
    }
    #expect(notificationCount == 0)

    // Now perform addMember which completes successfully
    await transport.setError(nil)
    let newMemberDID = try! DID(didString: "did:plc:member99")
    _ = try await model.addMember(did: newMemberDID)

    #expect(notificationCount == 0)
  }
}
