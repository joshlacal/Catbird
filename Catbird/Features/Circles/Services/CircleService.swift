import Foundation
import Petrel
import PetrelCatbird

/// Production Circle transport over the existing gateway `ATProtoClient`.
///
/// All requests go through Petrel's normal gateway network path (`client.blue
/// .catbird.circle.*` and `client.com.atproto.space.*`); no raw session token
/// or PDS DPoP material is exposed to the device. Writes go to the exact
/// Circle Space and never fall back to the public repo.
actor GatewayCircleTransport: CircleTransport {
  private let client: ATProtoClient

  init(client: ATProtoClient) {
    self.client = client
  }

  let publicEndpointCallCount: Int = 0

  func capabilities() async throws -> CircleCapability {
    let (_, output) = try await client.blue.catbird.circle.getCapabilities()
    guard let output else { throw CircleError.invalidResponse }
    return CircleCapability(
      enabled: output.enabled,
      protocolRevision: output.protocolRevision,
      supportsImages: output.supportsImages
    )
  }

  func listCircles(cursor: String?) async throws -> CircleListPage {
    let (_, output) = try await client.blue.catbird.circle.listCircles(
      input: BlueCatbirdCircleListCircles.Parameters(cursor: cursor)
    )
    guard let output else { throw CircleError.invalidResponse }
    return CircleListPage(circles: output.circles, cursor: output.cursor)
  }

  func getFeed(space: SpaceRef?, cursor: String?) async throws -> CircleFeedPage {
    let (_, output) = try await client.blue.catbird.circle.getFeed(
      input: BlueCatbirdCircleGetFeed.Parameters(space: space, cursor: cursor)
    )
    guard let output else { throw CircleError.invalidResponse }
    return CircleFeedPage(items: output.feed, cursor: output.cursor)
  }

  func getPostThread(uri: ATProtocolURI, space: SpaceRef) async throws -> CircleThreadPage {
    let (_, output) = try await client.blue.catbird.circle.getPostThread(
      input: BlueCatbirdCircleGetPostThread.Parameters(uri: uri, space: space)
    )
    guard let output else { throw CircleError.invalidResponse }
    return CircleThreadPage(thread: output.thread, circle: output.circle)
  }

  func listNotifications(cursor: String?) async throws -> CircleNotificationPage {
    let (_, output) = try await client.blue.catbird.circle.listNotifications(
      input: BlueCatbirdCircleListNotifications.Parameters(cursor: cursor)
    )
    guard let output else { throw CircleError.invalidResponse }
    return CircleNotificationPage(notifications: output.notifications, cursor: output.cursor)
  }

  func media(space: SpaceRef, authorDID: DID, cid: CID) async throws -> Data {
    let (_, output) = try await client.blue.catbird.circle.getMedia(
      input: BlueCatbirdCircleGetMedia.Parameters(space: space, did: authorDID, cid: cid)
    )
    guard let output else { throw CircleError.invalidResponse }
    return output.data
  }

  func createCircle(name: String, memberDIDs: [DID]) async throws -> CircleOperation {
    let (_, output) = try await client.blue.catbird.circle.createCircle(
      input: BlueCatbirdCircleCreateCircle.Input(name: name, memberDids: memberDIDs)
    )
    guard let output else { throw CircleError.invalidResponse }
    return output
  }

  func updateMember(space: SpaceRef, memberDID: DID, action: CircleMemberAction) async throws -> CircleOperation {
    let (_, output) = try await client.blue.catbird.circle.updateMember(
      input: BlueCatbirdCircleUpdateMember.Input(
        space: space, memberDid: memberDID, action: action.generated
      )
    )
    guard let output else { throw CircleError.invalidResponse }
    return output
  }

  func updatePreferences(space: SpaceRef, muted: Bool) async throws -> Bool {
    let (_, output) = try await client.blue.catbird.circle.updatePreferences(
      input: BlueCatbirdCircleUpdatePreferences.Input(space: space, muted: muted)
    )
    guard let output else { throw CircleError.invalidResponse }
    return output.muted
  }

  func report(
    post: ATProtocolURI, circle: CircleSummary, reason: CircleReportReason, details: String?
  ) async throws -> UUID {
    let (_, output) = try await client.blue.catbird.circle.reportRecord(
      input: BlueCatbirdCircleReportRecord.Input(
        space: circle.uri, uri: post, reason: reason.clientValue, details: details
      )
    )
    guard let output else { throw CircleError.invalidResponse }
    guard let uuid = UUID(uuidString: output.id) else { throw CircleError.invalidResponse }
    return uuid
  }

  func activate(space: SpaceRef) async throws -> CircleAccessState {
    let (_, output) = try await client.blue.catbird.circle.activateSpace(
      input: BlueCatbirdCircleActivateSpace.Input(space: space)
    )
    guard let output else { throw CircleError.invalidResponse }
    return CircleAccessState(rawValue: output.accessState.rawValue) ?? .unsupported
  }

  func publishPost(destination: CircleSummary, draft: CirclePostDraft) async throws -> ATProtocolURI {
    let did = try await client.getDid()
    let tid = await TIDGenerator.shared.nextTID()

    let post = AppBskyFeedPost(
      text: draft.text,
      entities: nil,
      facets: draft.facets,
      reply: draft.reply,
      embed: draft.embed,
      langs: draft.langs,
      labels: draft.labels,
      tags: nil,
      createdAt: draft.createdAt
    )

    let create = ComAtprotoSpaceApplyWrites.Create(
      collection: try NSID(nsidString: "app.bsky.feed.post"),
      rkey: try RecordKey(keyString: tid.description),
      value: ATProtocolValueContainer.knownType(post)
    )

    let input = ComAtprotoSpaceApplyWrites.Input(
      space: destination.uri,
      repo: try DID(didString: did),
      validate: true,
      writes: [ComAtprotoSpaceApplyWrites.InputWritesUnion(create)]
    )

    let (_, output) = try await client.com.atproto.space.applyWrites(input: input)
    guard let result = output?.results?.first else { throw CircleError.spaceWriteRejected("no result") }
    switch result {
    case .comAtprotoSpaceApplyWritesCreateResult(let createResult):
      return createResult.uri
    case .comAtprotoSpaceApplyWritesUpdateResult, .comAtprotoSpaceApplyWritesDeleteResult, .unexpected:
      throw CircleError.spaceWriteRejected("unexpected applyWrites result")
    }
  }

  func like(post: AppBskyFeedDefs.PostView, circle: CircleSummary) async throws -> ATProtocolURI {
    let did = try await client.getDid()
    let tid = await TIDGenerator.shared.nextTID()
    let like = AppBskyFeedLike(
      subject: ComAtprotoRepoStrongRef(uri: post.uri, cid: post.cid),
      createdAt: ATProtocolDate(date: Date()),
      via: nil
    )

    let create = ComAtprotoSpaceApplyWrites.Create(
      collection: try NSID(nsidString: "app.bsky.feed.like"),
      rkey: try RecordKey(keyString: tid.description),
      value: ATProtocolValueContainer.knownType(like)
    )

    let input = ComAtprotoSpaceApplyWrites.Input(
      space: circle.uri,
      repo: try DID(didString: did),
      validate: true,
      writes: [ComAtprotoSpaceApplyWrites.InputWritesUnion(create)]
    )

    let (_, output) = try await client.com.atproto.space.applyWrites(input: input)
    guard let result = output?.results?.first else { throw CircleError.spaceWriteRejected("no result") }
    switch result {
    case .comAtprotoSpaceApplyWritesCreateResult(let createResult):
      return createResult.uri
    case .comAtprotoSpaceApplyWritesUpdateResult, .comAtprotoSpaceApplyWritesDeleteResult, .unexpected:
      throw CircleError.spaceWriteRejected("unexpected applyWrites result")
    }
  }

  func deletePost(uri: ATProtocolURI, circle: CircleSummary) async throws {
    let did = try await client.getDid()
    let rkey = uri.recordKey ?? ""

    let delete = ComAtprotoSpaceApplyWrites.Delete(
      collection: try NSID(nsidString: "app.bsky.feed.post"),
      rkey: try RecordKey(keyString: rkey)
    )

    let input = ComAtprotoSpaceApplyWrites.Input(
      space: circle.uri,
      repo: try DID(didString: did),
      validate: true,
      writes: [ComAtprotoSpaceApplyWrites.InputWritesUnion(delete)]
    )

    let (_, output) = try await client.com.atproto.space.applyWrites(input: input)
    guard let result = output?.results?.first else { throw CircleError.spaceWriteRejected("no result") }
    switch result {
    case .comAtprotoSpaceApplyWritesDeleteResult:
      return
    case .comAtprotoSpaceApplyWritesCreateResult, .comAtprotoSpaceApplyWritesUpdateResult, .unexpected:
      throw CircleError.spaceWriteRejected("unexpected applyWrites result")
    }
  }

  func deleteLike(uri: ATProtocolURI, circle: CircleSummary) async throws {
    let did = try await client.getDid()
    let rkey = uri.recordKey ?? ""

    let delete = ComAtprotoSpaceApplyWrites.Delete(
      collection: try NSID(nsidString: "app.bsky.feed.like"),
      rkey: try RecordKey(keyString: rkey)
    )

    let input = ComAtprotoSpaceApplyWrites.Input(
      space: circle.uri,
      repo: try DID(didString: did),
      validate: true,
      writes: [ComAtprotoSpaceApplyWrites.InputWritesUnion(delete)]
    )

    let (_, output) = try await client.com.atproto.space.applyWrites(input: input)
    guard let result = output?.results?.first else { throw CircleError.spaceWriteRejected("no result") }
    switch result {
    case .comAtprotoSpaceApplyWritesDeleteResult:
      return
    case .comAtprotoSpaceApplyWritesCreateResult, .comAtprotoSpaceApplyWritesUpdateResult, .unexpected:
      throw CircleError.spaceWriteRejected("unexpected applyWrites result")
    }
  }
}

/// Typed Circle client boundary. Holds a transport (production gateway or test
/// double) and exposes the focused Circle API surface. Errors stay
/// `CircleError`-shaped and never fall back to public endpoints.
actor CircleService {
  private let transport: any CircleTransport

  init(transport: any CircleTransport) {
    self.transport = transport
  }

  func capabilities() async throws -> CircleCapability {
    try await transport.capabilities()
  }

  func listCircles(cursor: String? = nil) async throws -> CircleListPage {
    try await transport.listCircles(cursor: cursor)
  }

  func getFeed(space: SpaceRef?, cursor: String? = nil) async throws -> CircleFeedPage {
    try await transport.getFeed(space: space, cursor: cursor)
  }

  func getPostThread(uri: ATProtocolURI, space: SpaceRef) async throws -> CircleThreadPage {
    try await transport.getPostThread(uri: uri, space: space)
  }

  func listNotifications(cursor: String? = nil) async throws -> CircleNotificationPage {
    try await transport.listNotifications(cursor: cursor)
  }

  func media(space: SpaceRef, authorDID: DID, cid: CID) async throws -> Data {
    try await transport.media(space: space, authorDID: authorDID, cid: cid)
  }

  func createCircle(name: String, memberDIDs: [DID]) async throws -> CircleOperation {
    try await transport.createCircle(name: name, memberDIDs: memberDIDs)
  }

  func updateMember(space: SpaceRef, memberDID: DID, action: CircleMemberAction) async throws -> CircleOperation {
    try await transport.updateMember(space: space, memberDID: memberDID, action: action)
  }

  func updatePreferences(space: SpaceRef, muted: Bool) async throws -> Bool {
    try await transport.updatePreferences(space: space, muted: muted)
  }

  func report(post: ATProtocolURI, circle: CircleSummary, reason: CircleReportReason, details: String? = nil) async throws -> UUID {
    try await transport.report(post: post, circle: circle, reason: reason, details: details)
  }

  func activate(space: SpaceRef) async throws -> CircleAccessState {
    try await transport.activate(space: space)
  }

  func publishPost(destination: CircleSummary, draft: CirclePostDraft) async throws -> ATProtocolURI {
    try await transport.publishPost(destination: destination, draft: draft)
  }

  func like(post: AppBskyFeedDefs.PostView, circle: CircleSummary) async throws -> ATProtocolURI {
    try await transport.like(post: post, circle: circle)
  }

  func deletePost(uri: ATProtocolURI, circle: CircleSummary) async throws {
    try await transport.deletePost(uri: uri, circle: circle)
  }

  func deleteLike(uri: ATProtocolURI, circle: CircleSummary) async throws {
    try await transport.deleteLike(uri: uri, circle: circle)
  }
}
