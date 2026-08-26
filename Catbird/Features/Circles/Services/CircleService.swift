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

  /// Creates the Circle Space on the owner's own PDS and writes its metadata.
  ///
  /// `#allowList` names only the AppView's OAuth `client_id`, so no other app
  /// can mint a credential for this Space. The returned summary is provisional:
  /// `activateCircle` replaces it with the AppView's authoritative view.
  func createSpace(skey: String, circleId: String, name: String, memberDIDs: [DID]) async throws -> CircleSummary {
    let ownerDID = try DID(didString: try await client.getDid())
    let tid = try TID(tidString: circleId)

    let (_, created) = try await client.com.atproto.simplespace.createSpace(
      input: ComAtprotoSimplespaceCreateSpace.Input(
        type: try NSID(nsidString: CircleConfiguration.spaceType),
        skey: try RecordKey(keyString: skey),
        policy: ComAtprotoSimplespaceCreateSpace.InputPolicyUnion(
          ComAtprotoSimplespaceDefs.MemberListPolicy()
        ),
        appAccess: ComAtprotoSimplespaceCreateSpace.InputAppAccessUnion(
          ComAtprotoSimplespaceDefs.AllowList(allowed: [CircleConfiguration.clientID])
        )
      )
    )
    guard let created else { throw CircleError.invalidResponse }
    let space = created.uri

    let metadata = BlueCatbirdCircleMetadata(
      circleId: tid,
      name: name,
      createdAt: ATProtocolDate(date: Date()),
      migratedFrom: nil,
      migratedTo: nil
    )
    let (_, putOutput) = try await client.com.atproto.space.putRecord(
      input: ComAtprotoSpacePutRecord.Input(
        space: space,
        repo: ownerDID,
        collection: try NSID(nsidString: CircleConfiguration.metadataCollection),
        rkey: try RecordKey(keyString: "self"),
        // `validate: false` is required, not a shortcut. A PDS validates records
        // against lexicons it knows, and `blue.catbird.circle.metadata` is a
        // third-party lexicon it does not; the live Spaces PDS rejects this write
        // with "Unknown lexicon type" under validation. Nothing is lost: the
        // AppView validates metadata on ingest. Records in known namespaces
        // (app.bsky.feed.post/like) keep validation on.
        validate: false,
        record: ATProtocolValueContainer.knownType(metadata)
      )
    )
    guard putOutput != nil else {
      throw CircleError.spaceWriteRejected("metadata record rejected")
    }

    for member in memberDIDs {
      try await addMember(space: space, did: member)
    }

    return CircleSummary(
      uri: space,
      circleId: tid,
      name: name,
      owner: ownerDID,
      memberCount: memberDIDs.count,
      muted: false
    )
  }

  func deleteSpace(space: SpaceRef) async throws {
    _ = try await client.com.atproto.simplespace.deleteSpace(
      input: ComAtprotoSimplespaceDeleteSpace.Input(space: space)
    )
  }

  func addMember(space: SpaceRef, did: DID) async throws {
    _ = try await client.com.atproto.simplespace.addMember(
      input: ComAtprotoSimplespaceAddMember.Input(space: space, did: did)
    )
  }

  func removeMember(space: SpaceRef, did: DID) async throws {
    _ = try await client.com.atproto.simplespace.removeMember(
      input: ComAtprotoSimplespaceRemoveMember.Input(space: space, did: did)
    )
  }

  /// Full member roster from the owner's own PDS. Paginates to completion so a
  /// truncated page can never read as a shrunken Circle.
  func listMembers(space: SpaceRef) async throws -> [DID] {
    var members: [DID] = []
    var cursor: String?
    var seenCursors: Set<String> = []
    repeat {
      let (_, output) = try await client.com.atproto.simplespace.listMembers(
        input: ComAtprotoSimplespaceListMembers.Parameters(
          space: space, limit: nil, cursor: cursor
        )
      )
      guard let output else { throw CircleError.invalidResponse }
      members.append(contentsOf: output.members.map(\.did))
      // A server echoing a constant cursor would spin this loop forever and
      // grow `members` without bound. Treat a repeated cursor as end-of-list.
      if let next = output.cursor, seenCursors.insert(next).inserted {
        cursor = next
      } else {
        cursor = nil
      }
    } while cursor != nil
    return members
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

  func activateCircle(space: SpaceRef) async throws -> CircleSummary {
    let (_, output) = try await client.blue.catbird.circle.activateCircle(
      input: BlueCatbirdCircleActivateCircle.Input(space: space)
    )
    guard let output else { throw CircleError.invalidResponse }
    return output.circle
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

  func createSpace(skey: String, circleId: String, name: String, memberDIDs: [DID]) async throws -> CircleSummary {
    try await transport.createSpace(skey: skey, circleId: circleId, name: name, memberDIDs: memberDIDs)
  }

  func deleteSpace(space: SpaceRef) async throws {
    try await transport.deleteSpace(space: space)
  }

  func addMember(space: SpaceRef, did: DID) async throws {
    try await transport.addMember(space: space, did: did)
  }

  func removeMember(space: SpaceRef, did: DID) async throws {
    try await transport.removeMember(space: space, did: did)
  }

  func listMembers(space: SpaceRef) async throws -> [DID] {
    try await transport.listMembers(space: space)
  }

  func updatePreferences(space: SpaceRef, muted: Bool) async throws -> Bool {
    try await transport.updatePreferences(space: space, muted: muted)
  }

  func report(post: ATProtocolURI, circle: CircleSummary, reason: CircleReportReason, details: String? = nil) async throws -> UUID {
    try await transport.report(post: post, circle: circle, reason: reason, details: details)
  }

  func activateCircle(space: SpaceRef) async throws -> CircleSummary {
    try await transport.activateCircle(space: space)
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
