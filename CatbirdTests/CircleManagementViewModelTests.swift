import CatbirdMLSCore
import Foundation
import Petrel
import PetrelCatbird
import Testing
#if os(iOS)
import UIKit
#endif
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
    return CircleCapability(enabled: true, protocolRevision: CircleConfiguration.protocolRevision, supportsImages: true)
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
      cid: CIDString(CID.fromDAGCBOR(Data("test-thread-root".utf8))),
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

  func listMembers(space: SpaceRef) async throws -> [CircleMember] {
    if let error { throw error }
    return mockMembers.map { CircleMember(did: $0, read: true, write: true) }
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
    return try! ATProtocolURI(uriString: "\(destination.uri.uriString())/did:plc:alice/app.bsky.feed.post/test123")
  }

  func like(post: AppBskyFeedDefs.PostView, circle: CircleSummary) async throws -> ATProtocolURI {
    if let error { throw error }
    return try! ATProtocolURI(uriString: "\(circle.uri.uriString())/did:plc:alice/app.bsky.feed.like/like123")
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

  @Test func createCircleAfterActivationFailureRetriesExistingSpaceWithoutRecreating() async throws {
    let transport = ManagementRecordingCircleTransport()
    await transport.setActivationError(.authRequired)
    let service = CircleService(transport: transport)
    let model = CircleManagementViewModel(service: service, userDID: ownerDID.didString())

    // Initial creation: Space is created on PDS, but activateCircle fails with authRequired
    let summary = try await model.createCircle(name: "Retry Contract Circle", memberDIDs: [bobDID])
    #expect(await transport.createdCircles.count == 1)
    #expect(await transport.activateCircleCalls.count == 1)
    #expect(model.hasCreatedSpace == true)
    #expect(model.canRetryActivation == true)
    #expect(model.state == .activationFailed(message: CircleError.authRequired.localizedDescription))
    #expect(summary.name == "Retry Contract Circle")

    // Subsequent call to createCircle must NEVER recreate Space; it reuses existing Space and retries activation
    await transport.setActivationError(nil)
    let retried = try await model.createCircle(name: "Retry Contract Circle", memberDIDs: [bobDID])
    #expect(await transport.createdCircles.count == 1)
    #expect(await transport.activateCircleCalls.count == 2)
    #expect(model.state == .complete)
    #expect(retried.name == "Activated")
  }

  #if os(iOS)
  @Test func appViewConsentWaitsForPreviousBrowserDismissal() async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    )
    let window = UIWindow(windowScene: scene)
    let root = UIViewController()
    window.rootViewController = root
    window.isHidden = false
    defer {
      window.isHidden = true
      window.rootViewController = nil
    }

    let firstBrowser = UIViewController()
    firstBrowser.modalPresentationStyle = .fullScreen
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      root.present(firstBrowser, animated: false) { continuation.resume() }
    }
    root.dismiss(animated: true)
    try #require(firstBrowser.isBeingDismissed)

    await CircleAppViewAuthCoordinator.waitForPresentationTransition(in: root)
    try #require(root.presentedViewController == nil)
    let secondBrowser = UIViewController()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      root.present(secondBrowser, animated: false) { continuation.resume() }
    }
    #expect(secondBrowser.presentingViewController === root)
    #expect(secondBrowser.view.window === window)
  }
  #endif

  @Test func createCircleRejectsConcurrentDoubleSubmission() async throws {
    let transport = ManagementRecordingCircleTransport()
    let service = CircleService(transport: transport)
    let model = CircleManagementViewModel(service: service, userDID: ownerDID.didString())

    model.state = .submitting
    let summary = try await model.createCircle(name: "Double Submit Circle", memberDIDs: [bobDID])
    #expect(await transport.createdCircles.isEmpty)
    #expect(await transport.activateCircleCalls.isEmpty)
    #expect(summary.uri.uriString() == CircleManagementViewModel.placeholderURIString)
  }

  @Test func activateCircleAuthFailureInvalidatesCachedAppViewAuthorization() async throws {
    let transport = ManagementRecordingCircleTransport()
    await transport.setActivationError(.authRequired)
    let service = CircleService(transport: transport)
    let model = CircleManagementViewModel(service: service, userDID: ownerDID.didString())

    // Seed coordinator into an authorized state for ownerDID
    let callbackURL = URL(string: "blue.catbird://oauth/circle-appview?did=\(ownerDID.didString())")!
    CircleAppViewAuthCoordinator.shared.complete(callback: callbackURL, expectedDID: ownerDID.didString())
    #expect(CircleAppViewAuthCoordinator.shared.needsAuthorization(for: ownerDID.didString()) == false)

    // Creating Circle where activation encounters an auth error must invalidate cached belief
    _ = try await model.createCircle(name: "Stale Auth Test", memberDIDs: [bobDID])
    #expect(model.state == .activationFailed(message: CircleError.authRequired.localizedDescription))
    #expect(CircleAppViewAuthCoordinator.shared.needsAuthorization(for: ownerDID.didString()) == true)

    // Recover authorization and retry activation on existing Space
    CircleAppViewAuthCoordinator.shared.complete(callback: callbackURL, expectedDID: ownerDID.didString())
    #expect(CircleAppViewAuthCoordinator.shared.needsAuthorization(for: ownerDID.didString()) == false)
    await transport.setActivationError(nil)

    try await model.retryActivation()
    #expect(model.state == .complete)
    #expect(await transport.createdCircles.count == 1)
    #expect(await transport.activateCircleCalls.count == 2)
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
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: ownerDID.didString(), client: client)
    let previousLifecycle = AppStateManager.shared.lifecycle
    AppStateManager.shared.setLifecycleForTesting(.authenticated(appState))
    defer { AppStateManager.shared.setLifecycleForTesting(previousLifecycle) }

    let transport = ManagementRecordingCircleTransport()
    appState.circleService = CircleService(transport: transport)

    // Probe capability for active account
    await appState.probeCircleCapabilities()
    #expect(appState.circlesEnabled)

    // A newly active account starts unknown and cannot inherit this account's support.
    let replacement = AppState(userDID: memberDID.didString(), client: client)
    AppStateManager.shared.setLifecycleForTesting(.authenticated(replacement))
    #expect(replacement.circleCapability == .unknown)
    #expect(!replacement.circlesEnabled)
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

// MARK: - Encrypted Circle management (Task 16)

/// Recording transport for encrypted management flows: per-Space rosters, key
/// records and metadata, with one ordered event log across every Space.
actor EncryptedManagementTransport: CircleTransport {
  let publicEndpointCallCount: Int = 0
  private(set) var events: [String] = []
  private(set) var metadataPuts: [(space: SpaceRef, metadata: BlueCatbirdCircleMetadata)] = []
  private(set) var createdEncrypted: [(circleId: String, name: String, history: Bool, migratedFrom: SpaceRef?)] = []
  var rosters: [String: [DID]] = [:]
  var metadata: [String: BlueCatbirdCircleMetadata] = [:]
  var keyEntries: [String: [BlueCatbirdCircleGetKeys.KeyEntry]] = [:]
  var rawRecords: [String: [Int: String]] = [:]
  /// `addMember` throws for these DIDs (simulates a mid-upgrade ACL failure).
  var failingAdds: Set<String> = []
  /// `getCapabilities.supportsEncryptedPosts`.
  var supportsEncryptedPosts = true
  /// `getMetadata` throws (I4: the history toggle must fail closed).
  var metadataReadFails = false
  /// `capabilities()` throws (I9: no silent plaintext downgrade).
  var capabilitiesFail = false
  func setMetadataReadFails(_ value: Bool) { metadataReadFails = value }
  func setCapabilitiesFail(_ value: Bool) { capabilitiesFail = value }
  private(set) var plaintextCreates: [(name: String, memberDIDs: [DID])] = []

  static let newSpace = try! SpaceRef(uriString: "at://did:plc:owner123/space/blue.catbird.circle.encrypted/3newenc")

  func setRoster(_ space: SpaceRef, _ members: [DID]) { rosters[space.uriString()] = members }
  func roster(_ space: SpaceRef) -> [DID] { rosters[space.uriString()] ?? [] }
  func setMetadata(_ space: SpaceRef, _ value: BlueCatbirdCircleMetadata) { metadata[space.uriString()] = value }
  func storedMetadata(_ space: SpaceRef) -> BlueCatbirdCircleMetadata? { metadata[space.uriString()] }
  func setFailingAdds(_ value: Set<String>) { failingAdds = value }

  /// `reason` of every key record written, in order.
  private(set) var keyReasons: [String] = []

  // Encrypted surface
  func createEncryptedSpace(
    skey: String, circleId: String, name: String, historyForNewMembers: Bool, migratedFrom: SpaceRef?
  ) async throws -> CircleSummary {
    events.append("createEncryptedSpace")
    createdEncrypted.append((circleId, name, historyForNewMembers, migratedFrom))
    let tid = try TID(tidString: circleId)
    metadata[Self.newSpace.uriString()] = BlueCatbirdCircleMetadata(
      circleId: tid, name: name, createdAt: ATProtocolDate(date: Date()),
      migratedFrom: migratedFrom, historyForNewMembers: historyForNewMembers,
      encryption: BlueCatbirdCircleMetadata.Encryption(scheme: .value_circle_u2d_v1)
    )
    return CircleSummary(
      uri: Self.newSpace, circleId: tid, name: name,
      owner: try DID(didString: "did:plc:owner123"), memberCount: 0, muted: false
    )
  }

  func getMetadata(space: SpaceRef) async throws -> BlueCatbirdCircleMetadata? {
    if metadataReadFails { throw CircleError.upstreamUnavailable }
    return metadata[space.uriString()]
  }

  func putMetadata(space: SpaceRef, metadata value: BlueCatbirdCircleMetadata) async throws {
    events.append(value.migratedTo != nil ? "putMetadata:migratedTo" : "putMetadata")
    metadataPuts.append((space, value))
    metadata[space.uriString()] = value
  }

  func getKeys(space: SpaceRef, sinceVersion: Int?) async throws -> CircleKeysResponse {
    let all = keyEntries[space.uriString()] ?? []
    let entries = all.filter { $0.keyVersion > (sinceVersion ?? 0) }
    return .testing(entries, latest: all.map(\.keyVersion).max() ?? 0, raw: rawRecords[space.uriString()] ?? [:])
  }

  func putKeyRecord(space: SpaceRef, rkey: String, recordJSON: String) async throws -> ATProtocolURI {
    events.append("putKeyRecord:\(rkey)")
    let written = try JSONDecoder().decode(BlueCatbirdCircleKey.self, from: Data(recordJSON.utf8))
    keyReasons.append(written.reason)
    let uri = try ATProtocolURI(uriString: "at://did:plc:owner123/blue.catbird.circle.key/\(rkey)")
    let cid = CID.fromDAGCBOR(Data(recordJSON.utf8))
    let key = space.uriString()
    keyEntries[key, default: []].removeAll { $0.keyVersion == written.keyVersion }
    keyEntries[key, default: []].append(
      BlueCatbirdCircleGetKeys.KeyEntry(uri: uri, cid: CIDString(cid), keyVersion: written.keyVersion, record: written)
    )
    rawRecords[key, default: [:]][written.keyVersion] = recordJSON
    return uri
  }

  // Space administration
  func createSpace(skey: String, circleId: String, name: String, memberDIDs: [DID]) async throws -> CircleSummary {
    events.append("createSpace")
    plaintextCreates.append((name, memberDIDs))
    let space = try SpaceRef(uriString: "at://did:plc:owner123/space/blue.catbird.circle/\(skey)")
    rosters[space.uriString()] = memberDIDs
    return CircleSummary(
      uri: space, circleId: try TID(tidString: circleId), name: name,
      owner: try DID(didString: "did:plc:owner123"), memberCount: memberDIDs.count, muted: false
    )
  }
  func deleteSpace(space: SpaceRef) async throws {}
  func addMember(space: SpaceRef, did: DID) async throws {
    if failingAdds.contains(did.didString()) { throw CircleError.upstreamUnavailable }
    events.append("addMember:\(did.didString())")
    if !roster(space).contains(did) { rosters[space.uriString(), default: []].append(did) }
  }
  func removeMember(space: SpaceRef, did: DID) async throws {
    events.append("removeMember:\(did.didString())")
    rosters[space.uriString(), default: []].removeAll { $0 == did }
  }
  func listMembers(space: SpaceRef) async throws -> [CircleMember] {
    roster(space).map { CircleMember(did: $0, read: true, write: true) }
  }
  func activateCircle(space: SpaceRef) async throws -> CircleSummary {
    events.append("activateCircle")
    return CircleSummary(
      uri: space, circleId: try TID(tidString: "3l7revaaaaaaa"), name: "Family Circle",
      owner: try DID(didString: "did:plc:owner123"), memberCount: roster(space).count, muted: false
    )
  }

  func capabilities() async throws -> CircleCapability {
    if capabilitiesFail { throw CircleError.upstreamUnavailable }
    return CircleCapability(
      enabled: true, protocolRevision: CircleConfiguration.protocolRevision, supportsImages: true,
      supportsEncryptedPosts: supportsEncryptedPosts
    )
  }

  // Unused
  func listCircles(cursor: String?) async throws -> CircleListPage { CircleListPage(circles: [], cursor: nil) }
  func getFeed(space: SpaceRef?, cursor: String?) async throws -> CircleFeedPage { CircleFeedPage(items: [], cursor: nil) }
  func getPostThread(uri: ATProtocolURI, space: SpaceRef) async throws -> CircleThreadPage { throw CircleError.invalidResponse }
  func listNotifications(cursor: String?) async throws -> CircleNotificationPage { CircleNotificationPage(notifications: [], cursor: nil) }
  func media(space: SpaceRef, authorDID: DID, cid: CID) async throws -> Data { Data() }
  func updatePreferences(space: SpaceRef, muted: Bool) async throws -> Bool { muted }
  func report(post: ATProtocolURI, circle: CircleSummary, reason: CircleReportReason, details: String?) async throws -> UUID { UUID() }
  func publishPost(destination: CircleSummary, draft: CirclePostDraft) async throws -> ATProtocolURI { throw CircleError.invalidResponse }
  func like(post: AppBskyFeedDefs.PostView, circle: CircleSummary) async throws -> ATProtocolURI { throw CircleError.invalidResponse }
  func deletePost(uri: ATProtocolURI, circle: CircleSummary) async throws {}
  func deleteLike(uri: ATProtocolURI, circle: CircleSummary) async throws {}
}

/// Scripted crypto + in-memory Keychain + recording transport behind a real
/// `CircleKeyManager` and `CircleService`.
@MainActor
private struct EncryptedManagementHarness {
  static let owner = try! DID(didString: "did:plc:owner123")
  static let bob = try! DID(didString: "did:plc:bob789")
  static let carol = try! DID(didString: "did:plc:carol321")
  static let dave = try! DID(didString: "did:plc:dave654")
  static let encryptedCircle = CircleSummary(
    uri: try! SpaceRef(uriString: "at://did:plc:owner123/space/blue.catbird.circle.encrypted/3enc"),
    circleId: try! TID(tidString: "3l7revaaaaaaa"),
    name: "Family Circle",
    owner: owner,
    memberCount: 1,
    muted: false
  )
  static let plaintextCircle = CircleSummary(
    uri: try! SpaceRef(uriString: "at://did:plc:owner123/space/blue.catbird.circle/testspace"),
    circleId: try! TID(tidString: "3l7revaaaaaaa"),
    name: "Family Circle",
    owner: owner,
    memberCount: 3,
    muted: false
  )

  let crypto = ScriptedCircleCrypto()
  let transport = EncryptedManagementTransport()
  let store: CircleKeyStore
  let manager: CircleKeyManager
  let service: CircleService

  /// `enrollmentThrows`: the enrollment check itself fails (I9).
  init(enrolled: Bool = true, enrollmentThrows: Bool = false) {
    store = CircleKeyStore(accountDID: Self.owner.didString(), keychain: InMemoryCircleKeychain())
    manager = CircleKeyManager(crypto: crypto, store: store, transport: transport, ownerDID: Self.owner)
    service = CircleService(
      transport: transport, keyManager: manager, crypto: crypto, accountDID: Self.owner,
      mailboxEnrolled: {
        if enrollmentThrows { throw CircleError.clientNotInitialized }
        return enrolled
      }
    )
  }

  func model(_ circle: CircleSummary = Self.encryptedCircle) -> CircleManagementViewModel {
    CircleManagementViewModel(circle: circle, service: service, userDID: Self.owner.didString())
  }

  /// Seeds `v1` locally for `circle` (as if this device created it).
  func seedV1(_ circle: CircleSummary = Self.encryptedCircle) async throws {
    let space = circle.uri.uriString()
    try await store.store(
      spaceURI: space, keyVersion: 1, circleKey: Data(repeating: 1, count: 32), createdAt: Date(), reason: "created"
    )
    try await store.setLastRewrapAt(spaceURI: space, date: Date())
  }

  func metadata(history: Bool?, circle: CircleSummary = Self.encryptedCircle) -> BlueCatbirdCircleMetadata {
    BlueCatbirdCircleMetadata(
      circleId: circle.circleId, name: circle.name, createdAt: ATProtocolDate(date: Date()),
      historyForNewMembers: history,
      encryption: circle.isEncrypted ? BlueCatbirdCircleMetadata.Encryption(scheme: .value_circle_u2d_v1) : nil
    )
  }
}

@Suite("Encrypted Circle management", .serialized)
@MainActor
struct EncryptedCircleManagementTests {
  private typealias H = EncryptedManagementHarness

  @Test func toggleWritesMetadataRecord() async throws {
    let h = H()
    await h.transport.setMetadata(H.encryptedCircle.uri, h.metadata(history: true))
    let model = h.model()
    await model.loadEncryptionState()
    #expect(model.historyForNewMembers == true)

    await model.setHistoryForNewMembers(false)

    #expect(model.historyForNewMembers == false)
    let put = try #require(await h.transport.metadataPuts.last)
    #expect(put.space == H.encryptedCircle.uri)
    #expect(put.metadata.historyForNewMembers == false)
    #expect(put.metadata.name == "Family Circle")
    #expect(put.metadata.encryption != nil)
    #expect(CircleManagementCopy.historyToggleLabel == "New members can see earlier posts")
    #expect(CircleManagementCopy.historyOffAddConfirmation == "They will only see new posts.")
  }

  @Test("I4: a failed metadata read blocks the add; history never falls back to ON")
  func addFailsClosedWhenMetadataUnreadable() async throws {
    let h = H()
    try await h.seedV1()
    await h.transport.setRoster(H.encryptedCircle.uri, [H.carol])
    await h.transport.setMetadata(H.encryptedCircle.uri, h.metadata(history: false))
    let model = h.model()
    await model.loadEncryptionState()
    await h.transport.setMetadataReadFails(true)

    await #expect(throws: CircleError.self) { try await model.addMember(did: H.bob) }

    #expect(model.state == .failed(message: CircleManagementCopy.metadataReadFailed))
    #expect(CircleManagementCopy.metadataReadFailed == "Couldn't read this Circle's settings. Try again.")
    let events = await h.transport.events
    #expect(!events.contains { $0.hasPrefix("putKeyRecord") })
    #expect(!events.contains("addMember:\(H.bob.didString())"))
  }

  @Test("I4: the add uses the metadata read at add time, not a stale default")
  func addReadsHistorySettingAtAddTime() async throws {
    let h = H()
    try await h.seedV1()
    await h.transport.setRoster(H.encryptedCircle.uri, [H.carol])
    // The model never loaded state, so its default would say history ON.
    await h.transport.setMetadata(H.encryptedCircle.uri, h.metadata(history: false))
    let model = h.model()

    try await model.addMember(did: H.bob)

    #expect(await h.transport.keyReasons == ["memberAdded"])
    #expect(model.historyForNewMembers == false)
  }

  @Test("I9: enrolled but the capability check fails: no Circle is created, plaintext or otherwise")
  func createStopsWhenCapabilityCheckFails() async throws {
    let h = H()
    await h.transport.setCapabilitiesFail(true)
    let model = CircleManagementViewModel(service: h.service, userDID: H.owner.didString())

    await #expect(throws: CircleError.self) {
      _ = try await model.createCircle(name: "Family", memberDIDs: [H.bob])
    }

    #expect(model.encryptionAvailability == .checkFailed)
    #expect(model.state == .failed(message: CircleManagementCopy.encryptionCheckFailed))
    #expect(await h.transport.plaintextCreates.isEmpty)
    #expect(await h.transport.createdEncrypted.isEmpty)
  }

  @Test("I9: a throwing enrollment check blocks Create with a retryable error, like a failed capability check")
  func createStopsWhenEnrollmentCheckThrows() async throws {
    let h = H(enrollmentThrows: true)
    let model = CircleManagementViewModel(service: h.service, userDID: H.owner.didString())

    await #expect(throws: CircleError.self) {
      _ = try await model.createCircle(name: "Family", memberDIDs: [H.bob])
    }

    #expect(model.encryptionAvailability == .checkFailed)
    #expect(model.state == .failed(message: CircleManagementCopy.encryptionCheckFailed))
    #expect(await h.transport.plaintextCreates.isEmpty)
    #expect(await h.transport.createdEncrypted.isEmpty)
  }

  @Test func toggleOffMakesAddRotate() async throws {
    let h = H()
    try await h.seedV1()
    await h.transport.setRoster(H.encryptedCircle.uri, [H.carol])
    await h.transport.setMetadata(H.encryptedCircle.uri, h.metadata(history: false))
    let model = h.model()
    await model.loadEncryptionState()
    #expect(model.historyForNewMembers == false)

    try await model.addMember(did: H.bob)

    let events = await h.transport.events
    let put = try #require(events.firstIndex(of: "putKeyRecord:000002"))
    let add = try #require(events.firstIndex(of: "addMember:\(H.bob.didString())"))
    #expect(put < add)
    #expect(!events.contains("putKeyRecord:000001"))
    #expect(await h.transport.keyReasons == ["memberAdded"])
    #expect(try await h.store.latestVersion(spaceURI: H.encryptedCircle.uri.uriString()) == 2)
    #expect(try await h.store.joinedAtVersion(spaceURI: H.encryptedCircle.uri.uriString(), did: H.bob.didString()) == 2)
  }

  @Test func rotateNowWritesNextVersion() async throws {
    let h = H()
    try await h.seedV1()
    await h.transport.setRoster(H.encryptedCircle.uri, [H.bob])
    let model = h.model()
    await model.loadEncryptionState()
    #expect(model.canRotateKeyNow)

    await model.rotateKeyNow()

    #expect(await h.transport.events == ["putKeyRecord:000002"])
    #expect(await h.transport.keyReasons == ["manualRotation"])
    #expect(try await h.store.latestVersion(spaceURI: H.encryptedCircle.uri.uriString()) == 2)
    let wrap = try #require(await h.crypto.wraps.last)
    #expect(wrap.memberDIDs == [H.bob.didString()])
    #expect(model.state == .complete)
  }

  @Test func rotateNowDisabledWhileRemovalPending() async throws {
    let h = H()
    try await h.seedV1()
    await h.transport.setRoster(H.encryptedCircle.uri, [H.bob, H.carol])
    try await h.store.setPendingRewrap(
      spaceURI: H.encryptedCircle.uri.uriString(), did: CircleKeyManager.aclRemovePrefix + H.bob.didString(),
      reason: CircleKeyManager.aclRemoveReason
    )
    let model = h.model()
    await model.loadEncryptionState()

    #expect(model.canRotateKeyNow == false)
    await model.rotateKeyNow()
    #expect(await h.transport.events.isEmpty)
    #expect(try await h.store.latestVersion(spaceURI: H.encryptedCircle.uri.uriString()) == 1)
  }

  @Test func pendingRewrapsSurfaceInViewModel() async throws {
    let h = H()
    let space = H.encryptedCircle.uri.uriString()
    try await h.store.setPendingRewrap(
      spaceURI: space, did: CircleKeyManager.aclRemovePrefix + H.bob.didString(),
      reason: CircleKeyManager.aclRemoveRotatedReason
    )
    try await h.store.setPendingRewrap(spaceURI: space, did: H.carol.didString(), reason: "directory unavailable")
    try await h.store.setPendingRewrap(
      spaceURI: space, did: H.dave.didString(), reason: CircleKeyManager.historyPendingPrefix + "rewrap failed"
    )
    let eve = try DID(didString: "did:plc:eve111")
    try await h.store.setPendingRewrap(
      spaceURI: space, did: CircleKeyManager.aclAddPrefix + eve.didString(), reason: CircleKeyManager.aclAddReason
    )
    try await h.store.setPendingRewrap(spaceURI: space, did: "__migration__", reason: "migrationIncomplete")
    let model = h.model()

    await model.loadEncryptionState()

    #expect(Set(model.pendingRewraps.map { $0.did }) == [
      H.bob.didString(), H.carol.didString(), H.dave.didString(), eve.didString()
    ])
    #expect(model.pendingBadge(for: H.bob) == "Removal pending")
    #expect(model.pendingBadge(for: eve) == "Access pending")
    #expect(model.pendingBadge(for: H.dave) == "Key refresh pending")
    #expect(model.pendingBadge(for: H.carol) == "Waiting to refresh access")
    #expect(model.pendingBadge(for: H.owner) == nil)
    #expect(model.canRotateKeyNow == false)
  }

  @Test func ineligibleMemberBlocksAddWithReason() async throws {
    let h = H()
    try await h.seedV1()
    await h.transport.setRoster(H.encryptedCircle.uri, [H.bob])
    await h.crypto.setExclusions([H.dave.didString(): "no mailbox keys"])
    let model = h.model()
    model.knownHandles = [H.dave.didString(): "dave.test"]

    guard case .checked(let eligible, let ineligible) = await model.eligibleMembers([H.bob, H.dave]) else {
      Issue.record("eligibility check failed")
      return
    }
    #expect(eligible == [H.bob])
    #expect(ineligible.map { $0.did } == [H.dave])

    await #expect(throws: CircleError.ineligibleMember(reason: "Can't add: dave.test hasn't enabled encrypted features.")) {
      try await model.addMember(did: H.dave)
    }
    #expect(model.state == .failed(message: "Can't add: dave.test hasn't enabled encrypted features."))
    #expect(CircleManagementCopy.ineligibleMember(handle: "did:plc:x") == "Can't add: did:plc:x hasn't enabled encrypted features.")
    let events = await h.transport.events
    #expect(events.isEmpty)
    #expect(await h.transport.roster(H.encryptedCircle.uri) == [H.bob])
  }

  @Test func upgradeOrdersCallsCorrectly() async throws {
    let h = H()
    await h.transport.setRoster(H.plaintextCircle.uri, [H.bob, H.carol, H.dave])
    await h.transport.setMetadata(H.plaintextCircle.uri, h.metadata(history: false, circle: H.plaintextCircle))
    await h.crypto.setExclusions([H.dave.didString(): "no mailbox keys"])
    let model = h.model(H.plaintextCircle)
    await model.loadMembers()

    await model.prepareUpgrade()
    #expect(model.upgradeIneligible.map { $0.did } == [H.dave])

    try await model.upgradeToEncrypted()

    let events = await h.transport.events
    #expect(events == [
      "createEncryptedSpace",
      "putKeyRecord:000001",
      "addMember:\(H.bob.didString())",
      "addMember:\(H.carol.didString())",
      "putMetadata:migratedTo",
      "activateCircle",
    ])
    let created = try #require(await h.transport.createdEncrypted.first)
    #expect(created.circleId == H.plaintextCircle.circleId.description)
    #expect(created.name == H.plaintextCircle.name)
    #expect(created.migratedFrom == H.plaintextCircle.uri)
    #expect(created.history == false)
    let migratedTo = try #require(await h.transport.metadataPuts.last)
    #expect(migratedTo.space == H.plaintextCircle.uri)
    #expect(migratedTo.metadata.migratedTo == EncryptedManagementTransport.newSpace)
    let firstWrap = try #require(await h.crypto.wraps.last { $0.keyVersion == 1 && $0.reason == "created" })
    #expect(firstWrap.memberDIDs == [H.bob.didString(), H.carol.didString()])
    #expect(model.circle.uri == EncryptedManagementTransport.newSpace)
    #expect(model.state == .complete)
    #expect(try await h.store.pendingRewraps(spaceURI: EncryptedManagementTransport.newSpace.uriString()).isEmpty)
  }

  @Test func upgradeIncompleteLeavesMarkerAndRetries() async throws {
    let h = H()
    await h.transport.setRoster(H.plaintextCircle.uri, [H.bob, H.carol])
    await h.transport.setMetadata(H.plaintextCircle.uri, h.metadata(history: nil, circle: H.plaintextCircle))
    await h.transport.setFailingAdds([H.carol.didString()])
    let model = h.model(H.plaintextCircle)
    await model.loadMembers()
    await model.prepareUpgrade()

    await #expect(throws: (any Error).self) {
      try await model.upgradeToEncrypted()
    }

    let newSpace = EncryptedManagementTransport.newSpace.uriString()
    #expect(model.state == .upgradeIncomplete(message: CircleManagementCopy.upgradeIncomplete))
    #expect(CircleManagementCopy.upgradeIncomplete == "Upgrade incomplete — tap to retry")
    let marker = try await h.store.pendingRewraps(spaceURI: newSpace).first { $0.did == "__migration__" }
    #expect(marker?.reason == "migrationIncomplete")
    var events = await h.transport.events
    #expect(!events.contains("putMetadata:migratedTo"))
    #expect(await h.transport.storedMetadata(H.plaintextCircle.uri)?.migratedTo == nil)
    #expect(model.circle.uri == H.plaintextCircle.uri)

    // A fresh view model (e.g. after relaunch) finds the incomplete upgrade.
    let reopened = h.model(H.plaintextCircle)
    await reopened.loadMembers()
    await reopened.loadEncryptionState()
    #expect(reopened.state == .upgradeIncomplete(message: CircleManagementCopy.upgradeIncomplete))

    await h.transport.setFailingAdds([])
    try await reopened.upgradeToEncrypted()

    events = await h.transport.events
    #expect(events.filter { $0 == "createEncryptedSpace" }.count == 1)
    #expect(events.filter { $0 == "putKeyRecord:000001" }.count == 1)
    #expect(events.filter { $0 == "addMember:\(H.bob.didString())" }.count == 1)
    let tail = Array(events.suffix(3))
    #expect(tail == ["addMember:\(H.carol.didString())", "putMetadata:migratedTo", "activateCircle"])
    #expect(try await h.store.pendingRewraps(spaceURI: newSpace).isEmpty)
    #expect(try await h.store.pendingRewraps(spaceURI: H.plaintextCircle.uri.uriString()).isEmpty)
    #expect(reopened.circle.uri == EncryptedManagementTransport.newSpace)
    #expect(reopened.state == .complete)
  }
  @Test func resumeGrantsOnlyMembersWrappedInV1() async throws {
    let h = H()
    await h.transport.setRoster(H.plaintextCircle.uri, [H.bob, H.carol, H.dave])
    await h.transport.setMetadata(H.plaintextCircle.uri, h.metadata(history: nil, circle: H.plaintextCircle))
    await h.crypto.setExclusions([H.dave.didString(): "no mailbox keys"])
    await h.transport.setFailingAdds([H.carol.didString()])
    let model = h.model(H.plaintextCircle)
    await model.loadMembers()

    await #expect(throws: (any Error).self) {
      try await model.upgradeToEncrypted()
    }
    let newSpace = EncryptedManagementTransport.newSpace.uriString()
    // The failed grant is badged and retryable, never silent.
    let pendingAdd = try await h.store.pendingRewraps(spaceURI: newSpace)
      .first { $0.did == CircleKeyManager.aclAddPrefix + H.carol.didString() }
    #expect(pendingAdd?.reason == CircleKeyManager.aclAddReason)

    // Eligibility changes between runs: carol (wrapped in v1) is now excluded,
    // dave (left out of v1) is now eligible.
    await h.crypto.setExclusions([H.carol.didString(): "directory unavailable"])
    await h.transport.setFailingAdds([])
    let reopened = h.model(H.plaintextCircle)
    await reopened.loadMembers()
    await reopened.loadEncryptionState()
    try await reopened.upgradeToEncrypted()

    let events = await h.transport.events
    #expect(events.contains("addMember:\(H.carol.didString())"))
    #expect(!events.contains("addMember:\(H.dave.didString())"))
    #expect(events.filter { $0 == "putKeyRecord:000001" }.count == 1)
    #expect(Set(await h.transport.roster(EncryptedManagementTransport.newSpace)) == [H.bob, H.carol])
    #expect(try await h.store.migrationPlan(spaceURI: newSpace) == nil)
    #expect(try await h.store.pendingRewraps(spaceURI: newSpace).isEmpty)
    #expect(reopened.state == .complete)
  }

  @Test func failedEligibilityCheckBlocksUpgrade() async throws {
    let h = H()
    await h.transport.setRoster(H.plaintextCircle.uri, [H.bob, H.carol])
    await h.transport.setMetadata(H.plaintextCircle.uri, h.metadata(history: nil, circle: H.plaintextCircle))
    await h.crypto.setFailingVersions([1])
    let model = h.model(H.plaintextCircle)
    await model.loadMembers()

    await model.prepareUpgrade()
    #expect(model.upgradeBlockedReason == "Couldn't check who can be carried over. Try again.")
    #expect(model.canConfirmUpgrade == false)
    #expect(model.upgradeIneligible.isEmpty)

    await #expect(throws: CircleError.self) {
      try await model.upgradeToEncrypted()
    }
    #expect(await h.transport.events.isEmpty)
    #expect(model.state == .failed(message: CircleManagementCopy.eligibilityCheckFailed))
  }

  @Test func emptyEligibleSetBlocksUpgrade() async throws {
    let h = H()
    await h.transport.setRoster(H.plaintextCircle.uri, [H.bob, H.carol])
    await h.transport.setMetadata(H.plaintextCircle.uri, h.metadata(history: nil, circle: H.plaintextCircle))
    await h.crypto.setExclusions([H.bob.didString(): "no mailbox keys", H.carol.didString(): "no mailbox keys"])
    let model = h.model(H.plaintextCircle)
    await model.loadMembers()

    await model.prepareUpgrade()
    #expect(model.upgradeBlockedReason == "No members can be carried over yet")
    #expect(model.canConfirmUpgrade == false)

    await #expect(throws: CircleError.self) {
      try await model.upgradeToEncrypted()
    }
    #expect(await h.transport.events.isEmpty)
  }

  @Test func createDefaultsToEncryptedWhenEnrolled() async throws {
    let h = H()
    await h.crypto.setExclusions([H.dave.didString(): "no mailbox keys"])
    let model = CircleManagementViewModel(service: h.service, userDID: H.owner.didString())
    model.knownHandles = [H.dave.didString(): "dave.test"]

    await model.prepareCreate(memberDIDs: [H.bob, H.dave])
    #expect(model.createEncrypted)
    #expect(model.createIneligible.map { $0.did } == [H.dave])

    _ = try await model.createCircle(name: "Close", memberDIDs: [H.bob, H.dave])

    let events = await h.transport.events
    #expect(events.first == "createEncryptedSpace")
    let put = try #require(events.firstIndex(of: "putKeyRecord:000001"))
    let add = try #require(events.firstIndex(of: "addMember:\(H.bob.didString())"))
    #expect(put < add)
    #expect(!events.contains("addMember:\(H.dave.didString())"))
    #expect(!events.contains("createSpace"))
    #expect(model.circle.isEncrypted)
  }

  @Test func createStaysPlaintextWhenNotEnrolled() async throws {
    let h = H(enrolled: false)
    let model = CircleManagementViewModel(service: h.service, userDID: H.owner.didString())

    await model.prepareCreate(memberDIDs: [H.bob])
    #expect(model.createEncrypted == false)
    #expect(model.encryptionAvailability == .notEnrolled)
    #expect(CircleManagementCopy.encryptionUnavailableHint == "Encrypted Circles need encrypted features turned on.")

    _ = try await model.createCircle(name: "Close", memberDIDs: [H.bob])

    let events = await h.transport.events
    #expect(events.first == "createSpace")
    #expect(!events.contains("createEncryptedSpace"))
    #expect(!events.contains { $0.hasPrefix("putKeyRecord") })
    #expect(await h.transport.plaintextCreates.first?.memberDIDs == [H.bob])
    #expect(!model.circle.isEncrypted)

    // The same gate hides the upgrade row.
    let plaintext = h.model(H.plaintextCircle)
    await plaintext.loadEncryptionState()
    #expect(plaintext.encryptionAvailable == false)
  }
}
