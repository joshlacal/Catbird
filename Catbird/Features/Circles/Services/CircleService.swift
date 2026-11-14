import CatbirdMLSCore
import Foundation
import OSLog
import Petrel
import PetrelCatbird

/// Sends an XRPC procedure whose JSON body is given as exact bytes. Records
/// produced by the FFI go through this seam so they reach the PDS verbatim
/// (spec §7 raw-bytes contract): Petrel's typed encoders add nested `$type`
/// fields that the Rust record parsers reject.
protocol CircleRawXRPC: Sendable {
  /// POSTs `body` unchanged to procedure `nsid`; returns the 2xx response body.
  func procedure(_ nsid: String, body: Data) async throws -> Data
}

/// `CircleRawXRPC` over the client's network service: the same request,
/// auth, headers and service proxy as Petrel's generated procedure calls.
struct NetworkServiceRawXRPC: CircleRawXRPC {
  let client: ATProtoClient

  func procedure(_ nsid: String, body: Data) async throws -> Data {
    let network = await client.networkService
    let request = try await network.createURLRequest(
      endpoint: nsid,
      method: "POST",
      headers: ["Content-Type": "application/json", "Accept": "application/json"],
      body: body,
      queryItems: nil
    )
    let proxy = await network.getServiceDID(for: nsid).map { ["atproto-proxy": $0] }
    let (data, response) = try await network.performRequestReturningHTTPErrorResponses(
      request, skipTokenRefresh: false, additionalHeaders: proxy
    )
    guard (200...299).contains(response.statusCode) else {
      if let generic = ATProtoErrorParser.parseGeneric(data: data, statusCode: response.statusCode) {
        throw generic
      }
      throw CircleError.spaceWriteRejected("HTTP \(response.statusCode)")
    }
    return data
  }
}

/// Production Circle transport.
///
/// Public capability discovery calls the standalone AppView directly.
/// Authenticated Circle reads use Petrel's service map; Space administration
/// and permissioned writes stay on the owner's PDS. No raw session token or
/// PDS DPoP material is exposed to the device.
actor GatewayCircleTransport: CircleTransport {
  private let client: ATProtoClient
  /// The DID of the repo this transport writes (the client's account); tests
  /// inject one.
  private let repoDID: @Sendable () async throws -> String
  /// Raw procedure calls for FFI-produced records; tests inject a recorder.
  private let rawXRPC: any CircleRawXRPC

  init(
    client: ATProtoClient,
    repoDID: (@Sendable () async throws -> String)? = nil,
    rawXRPC: (any CircleRawXRPC)? = nil
  ) {
    self.client = client
    self.repoDID = repoDID ?? { try await client.getDid() }
    self.rawXRPC = rawXRPC ?? NetworkServiceRawXRPC(client: client)
  }

  /// `getFeed` parameters. The AppView omits encrypted items unless asked
  /// (`includeEncrypted`), so a client that can open them always asks.
  static func feedParameters(space: SpaceRef?, cursor: String?) -> BlueCatbirdCircleGetFeed.Parameters {
    BlueCatbirdCircleGetFeed.Parameters(space: space, cursor: cursor, includeEncrypted: true)
  }

  /// `getPostThread` parameters (encrypted nodes included, as for `getFeed`).
  static func threadParameters(uri: ATProtocolURI, space: SpaceRef) -> BlueCatbirdCircleGetPostThread.Parameters {
    BlueCatbirdCircleGetPostThread.Parameters(uri: uri, space: space, includeEncrypted: true)
  }

  /// A procedure body whose `rawMember` is `rawJSON` spliced in byte for byte;
  /// `fields` are ordinary JSON values. `rawJSON` must parse as a JSON object
  /// or array (it is never re-encoded, only checked).
  static func rawBody(fields: [(String, Any)], rawMember: String, rawJSON: String) throws -> Data {
    let raw = Data(rawJSON.utf8)
    let parsed = try? JSONSerialization.jsonObject(with: raw)
    guard parsed is [String: Any] || parsed is [Any] else {
      throw CircleError.invalidParameter("Malformed Circle record.")
    }
    var body = Data("{".utf8)
    for (name, value) in fields {
      body.append(try JSONSerialization.data(withJSONObject: name, options: .fragmentsAllowed))
      body.append(Data(":".utf8))
      body.append(try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
      body.append(Data(",".utf8))
    }
    body.append(try JSONSerialization.data(withJSONObject: rawMember, options: .fragmentsAllowed))
    body.append(Data(":".utf8))
    body.append(raw)
    body.append(Data("}".utf8))
    return body
  }

  let publicEndpointCallCount: Int = 0

  func capabilities() async throws -> CircleCapability {
    // The AppView's global switch says nothing about this account's PDS.
    // listSpaces is an authenticated, read-only PDS query; an empty list is valid.
    do {
      let (status, output) = try await client.com.atproto.space.listSpaces(
        input: ComAtprotoSpaceListSpaces.Parameters(
          spaceType: try NSID(nsidString: CircleConfiguration.spaceType), limit: 1
        )
      )
      guard status == 200, output != nil else { throw CircleError.invalidResponse }
    } catch {
      if Self.isUnsupportedSpacesError(error) { throw CircleError.unsupportedPDS }
      throw error
    }
    let endpoint = CircleConfiguration.appViewBaseURL
      .appendingPathComponent("xrpc/blue.catbird.circle.getCapabilities")
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(from: endpoint)
    } catch {
      throw CircleError.networkError(error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw CircleError.upstreamUnavailable
    }
    guard let output = try? JSONDecoder().decode(
      BlueCatbirdCircleGetCapabilities.Output.self,
      from: data
    ) else {
      throw CircleError.invalidResponse
    }
    return CircleCapability(
      enabled: output.enabled,
      protocolRevision: output.protocolRevision,
      supportsImages: output.supportsImages,
      supportsEncryptedPosts: output.supportsEncryptedPosts ?? false
    )
  }

  static func isUnsupportedSpacesError(_ error: Error) -> Bool {
    guard let error = error as? ATProtoXRPCError else { return false }
    return (error.statusCode == 501 && error.error == "MethodNotImplemented")
      || (error.statusCode == 404 && error.error == "permissioned_endpoint_unavailable")
  }

  func listCircles(cursor: String?) async throws -> CircleListPage {
    let (_, output) = try await client.blue.catbird.circle.listCircles(
      input: BlueCatbirdCircleListCircles.Parameters(cursor: cursor)
    )
    guard let output else { throw CircleError.invalidResponse }
    return CircleListPage(circles: output.circles, cursor: output.cursor)
  }

  /// Issued raw (same request, auth and proxy as the generated call) so the
  /// encrypted records can be sliced byte-exactly for the opener
  /// (`CircleRawRecordCache`); the typed decode is for Swift only.
  func getFeed(space: SpaceRef?, cursor: String?) async throws -> CircleFeedPage {
    let data = try await rawQuery(
      BlueCatbirdCircleGetFeed.typeIdentifier,
      queryItems: Self.feedParameters(space: space, cursor: cursor).asQueryItems(),
      errorType: BlueCatbirdCircleGetFeed.Error.self
    )
    guard let output = try? JSONDecoder().decode(BlueCatbirdCircleGetFeed.Output.self, from: data) else {
      throw CircleError.invalidResponse
    }
    CircleRawRecordCache.shared.register(feedResponse: data)
    return CircleFeedPage(items: output.feed, cursor: output.cursor)
  }

  /// Raw for the same reason as `getFeed`.
  func getPostThread(uri: ATProtocolURI, space: SpaceRef) async throws -> CircleThreadPage {
    let data = try await rawQuery(
      BlueCatbirdCircleGetPostThread.typeIdentifier,
      queryItems: Self.threadParameters(uri: uri, space: space).asQueryItems(),
      errorType: BlueCatbirdCircleGetPostThread.Error.self
    )
    guard let output = try? JSONDecoder().decode(BlueCatbirdCircleGetPostThread.Output.self, from: data) else {
      throw CircleError.invalidResponse
    }
    CircleRawRecordCache.shared.register(threadResponse: data)
    return CircleThreadPage(thread: output.thread, circle: output.circle)
  }

  /// A GET query through the client's network service; the 2xx body. Errors
  /// surface as the generated call's would: a declared lexicon error, else
  /// `invalidResponse`.
  private func rawQuery<E: ATProtoErrorType>(
    _ endpoint: String, queryItems: [URLQueryItem]?, errorType: E.Type
  ) async throws -> Data {
    let network = await client.networkService
    let request = try await network.createURLRequest(
      endpoint: endpoint,
      method: "GET",
      headers: ["Accept": "application/json"],
      body: nil,
      queryItems: queryItems
    )
    let proxy = await network.getServiceDID(for: endpoint).map { ["atproto-proxy": $0] }
    let (data, response) = try await network.performRequestReturningHTTPErrorResponses(
      request, skipTokenRefresh: false, additionalHeaders: proxy
    )
    guard (200...299).contains(response.statusCode) else {
      if let declared = ATProtoErrorParser.parse(data: data, statusCode: response.statusCode, errorType: errorType) {
        throw declared
      }
      throw CircleError.invalidResponse
    }
    return data
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
      input: BlueCatbirdCircleGetMedia.Parameters(space: space, did: authorDID, cid: CIDString(cid))
    )
    guard let output else { throw CircleError.invalidResponse }
    return output.data
  }

  /// Creates the Circle Space on the owner's own PDS and writes its metadata.
  ///
  /// The memberspace policy's `allowedApps` names only the AppView's OAuth
  /// `client_id`, so no other app can mint a credential for this Space. The returned summary is provisional:
  /// `activateCircle` replaces it with the AppView's authoritative view.
  func createSpace(skey: String, circleId: String, name: String, memberDIDs: [DID]) async throws -> CircleSummary {
    let summary = try await createSpaceWithMetadata(
      skey: skey, circleId: circleId, name: name,
      spaceType: CircleConfiguration.spaceType, encrypted: false
    )
    for member in memberDIDs {
      try await addMember(space: summary.uri, did: member)
    }
    return CircleSummary(
      uri: summary.uri,
      circleId: summary.circleId,
      name: summary.name,
      owner: summary.owner,
      memberCount: memberDIDs.count,
      muted: false
    )
  }

  /// Creates an encrypted Circle Space (D17) with `metadata.encryption =
  /// circle-v1` and `historyForNewMembers = true` (§7 default). Members are
  /// added by `CircleService` only after the first key record is written.
  func createEncryptedSpace(skey: String, circleId: String, name: String) async throws -> CircleSummary {
    try await createEncryptedSpace(
      skey: skey, circleId: circleId, name: name, historyForNewMembers: true, migratedFrom: nil
    )
  }

  /// Encrypted Space with an explicit history policy and, for an upgrade from
  /// a plaintext Circle (D17), `metadata.migratedFrom` naming the old Space.
  func createEncryptedSpace(
    skey: String, circleId: String, name: String, historyForNewMembers: Bool, migratedFrom: SpaceRef?
  ) async throws -> CircleSummary {
    try await createSpaceWithMetadata(
      skey: skey, circleId: circleId, name: name,
      spaceType: CircleConfiguration.encryptedSpaceType, encrypted: true,
      historyForNewMembers: historyForNewMembers, migratedFrom: migratedFrom
    )
  }

  func getMetadata(space: SpaceRef) async throws -> BlueCatbirdCircleMetadata? {
    let ownerDID = try DID(didString: try await client.getDid())
    let output: ComAtprotoSpaceGetRecord.Output?
    do {
      (_, output) = try await client.com.atproto.space.getRecord(
        input: ComAtprotoSpaceGetRecord.Parameters(
          space: space,
          repo: ownerDID,
          collection: try NSID(nsidString: CircleConfiguration.metadataCollection),
          rkey: try RecordKey(keyString: "self")
        )
      )
    } catch let error as ATProtoError<ComAtprotoSpaceGetRecord.Error> where error.error == .recordNotFound {
      return nil
    }
    guard let output else { throw CircleError.invalidResponse }
    if case .knownType(let value) = output.value, let metadata = value as? BlueCatbirdCircleMetadata {
      return metadata
    }
    // Third-party lexicon the container did not resolve: decode its JSON form.
    let json = try JSONEncoder().encode(output.value)
    return try JSONDecoder().decode(BlueCatbirdCircleMetadata.self, from: json)
  }

  func putMetadata(space: SpaceRef, metadata: BlueCatbirdCircleMetadata) async throws {
    let ownerDID = try DID(didString: try await client.getDid())
    let (_, output) = try await client.com.atproto.space.putRecord(
      input: ComAtprotoSpacePutRecord.Input(
        space: space,
        repo: ownerDID,
        collection: try NSID(nsidString: CircleConfiguration.metadataCollection),
        rkey: try RecordKey(keyString: "self"),
        // Third-party lexicon: see `createSpaceWithMetadata`.
        validate: false,
        record: ATProtocolValueContainer.knownType(metadata)
      )
    )
    guard output != nil else { throw CircleError.spaceWriteRejected("metadata record rejected") }
  }

  private func createSpaceWithMetadata(
    skey: String, circleId: String, name: String, spaceType: String, encrypted: Bool,
    historyForNewMembers: Bool = true, migratedFrom: SpaceRef? = nil
  ) async throws -> CircleSummary {
    let ownerDID = try DID(didString: try await client.getDid())
    let tid = try TID(tidString: circleId)

    let (_, created) = try await client.com.atproto.space.createSpace(
      input: ComAtprotoSpaceCreateSpace.Input(
        spaceType: try NSID(nsidString: spaceType),
        skey: try RecordKey(keyString: skey),
        policy: ComAtprotoSpaceCreateSpace.InputPolicyUnion(
          ComAtprotoMemberspacePolicy(allowedApps: [try URI(uriString: CircleConfiguration.clientID)])
        )
      )
    )
    guard let created else { throw CircleError.invalidResponse }
    let space = created.space

    let metadata = BlueCatbirdCircleMetadata(
      circleId: tid,
      name: name,
      createdAt: ATProtocolDate(date: Date()),
      migratedFrom: migratedFrom,
      migratedTo: nil,
      historyForNewMembers: encrypted ? historyForNewMembers : nil,
      encryption: encrypted ? BlueCatbirdCircleMetadata.Encryption(scheme: .value_circle_u2d_v1) : nil
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

    return CircleSummary(
      uri: space,
      circleId: tid,
      name: name,
      owner: ownerDID,
      memberCount: 0,
      muted: false
    )
  }

  /// Issued raw (same request, headers and service proxy as Petrel's generated
  /// call) so each key record reaches the FFI exactly as the AppView stored it.
  func getKeys(space: SpaceRef, sinceVersion: Int?) async throws -> CircleKeysResponse {
    let endpoint = BlueCatbirdCircleGetKeys.typeIdentifier
    let network = await client.networkService
    let request = try await network.createURLRequest(
      endpoint: endpoint,
      method: "GET",
      headers: ["Accept": "application/json"],
      body: nil,
      queryItems: BlueCatbirdCircleGetKeys.Parameters(space: space, sinceVersion: sinceVersion).asQueryItems()
    )
    let proxy = await network.getServiceDID(for: endpoint).map { ["atproto-proxy": $0] }
    let (data, response) = try await network.performRequestReturningHTTPErrorResponses(
      request, skipTokenRefresh: false, additionalHeaders: proxy
    )
    guard (200...299).contains(response.statusCode) else {
      // Same error surface as the generated call: a declared lexicon error, else invalidResponse.
      if let declared = ATProtoErrorParser.parse(
        data: data, statusCode: response.statusCode, errorType: BlueCatbirdCircleGetKeys.Error.self
      ) {
        throw declared
      }
      throw CircleError.invalidResponse
    }
    return try CircleKeysResponse(responseBody: data)
  }

  /// Writes a wrapped key record produced by the FFI as its exact bytes
  /// (`com.atproto.space.putRecord` issued raw): a Petrel re-encoding would add
  /// `senderEpoch.$type`, which members' Rust parsers reject. `validate: false`
  /// for the same third-party-lexicon reason as the metadata record; the
  /// AppView validates key records on ingest.
  func putKeyRecord(space: SpaceRef, rkey: String, recordJSON: String) async throws -> ATProtocolURI {
    let ownerDID = try DID(didString: try await repoDID())
    _ = try RecordKey(keyString: rkey)
    let body = try Self.rawBody(
      fields: [
        ("space", space.uriString()),
        ("repo", ownerDID.didString()),
        ("collection", CircleConfiguration.keyCollection),
        ("rkey", rkey),
        ("validate", false)
      ],
      rawMember: "record",
      rawJSON: recordJSON
    )
    let data = try await rawXRPC.procedure("com.atproto.space.putRecord", body: body)
    guard let output = try? JSONDecoder().decode(ComAtprotoSpacePutRecord.Output.self, from: data) else {
      throw CircleError.spaceWriteRejected("key record rejected")
    }
    return output.uri
  }

  /// Writes a sealed post at the canonical `postURI` bound into its AAD. The
  /// URI's author must be this repo: a post sealed as one account must never
  /// land in another's repo (an account switch mid-post), so a mismatch is
  /// refused before anything is written. `validate: false` for the same
  /// third-party-lexicon reason as the key record; the AppView validates
  /// envelopes on ingest. The record is sent as the FFI's exact bytes
  /// (`applyWrites` issued raw), so every attachment, the AAD's `createdAt`
  /// string and the reply refs reach the PDS unchanged.
  func publishEncryptedPost(destination: CircleSummary, postURI: ATProtocolURI, recordJSON: String) async throws -> ATProtocolURI {
    let did = try DID(didString: try await repoDID())
    guard !postURI.isSpace,
          postURI.collection == CirclePostSealer.postCollection,
          let author = try? DID(didString: postURI.authority),
          author == did,
          let rkey = postURI.recordKey
    else {
      throw CircleError.encryptionUnavailable
    }
    _ = try RecordKey(keyString: rkey)
    let create: Data
    do {
      create = try Self.rawBody(
        fields: [
          ("$type", "com.atproto.space.applyWrites#create"),
          ("collection", CirclePostSealer.postCollection),
          ("rkey", rkey)
        ],
        rawMember: "value",
        rawJSON: recordJSON
      )
    } catch {
      throw CircleError.encryptionUnavailable
    }
    let body = try Self.rawBody(
      fields: [("space", destination.uri.uriString()), ("repo", did.didString()), ("validate", false)],
      rawMember: "writes",
      rawJSON: "[" + String(decoding: create, as: UTF8.self) + "]"
    )
    let data = try await rawXRPC.procedure("com.atproto.space.applyWrites", body: body)
    let output = try? JSONDecoder().decode(ComAtprotoSpaceApplyWrites.Output.self, from: data)
    guard let result = output?.results?.first else { throw CircleError.spaceWriteRejected("no result") }
    switch result {
    case .comAtprotoSpaceApplyWritesCreateResult(let createResult):
      return createResult.uri
    case .comAtprotoSpaceApplyWritesUpdateResult, .comAtprotoSpaceApplyWritesDeleteResult:
      throw CircleError.spaceWriteRejected("unexpected applyWrites result")
    }
  }

  func deleteEncryptedPost(uri: ATProtocolURI, circle: CircleSummary) async throws {
    let did = try DID(didString: try await repoDID())
    guard !uri.isSpace,
          uri.collection == CirclePostSealer.postCollection,
          let author = try? DID(didString: uri.authority),
          author == did,
          let rkey = uri.recordKey
    else {
      throw CircleError.invalidParameter("Only your own encrypted posts can be deleted.")
    }
    let delete = ComAtprotoSpaceApplyWrites.Delete(
      collection: try NSID(nsidString: CirclePostSealer.postCollection),
      rkey: try RecordKey(keyString: rkey)
    )
    let input = ComAtprotoSpaceApplyWrites.Input(
      space: circle.uri, repo: did, validate: false,
      writes: [ComAtprotoSpaceApplyWrites.InputWritesUnion(delete)]
    )
    let (_, output) = try await client.com.atproto.space.applyWrites(input: input)
    guard let result = output?.results?.first else { throw CircleError.spaceWriteRejected("no result") }
    guard case .comAtprotoSpaceApplyWritesDeleteResult = result else {
      throw CircleError.spaceWriteRejected("unexpected applyWrites result")
    }
  }

  func deleteSpace(space: SpaceRef) async throws {
    _ = try await client.com.atproto.space.deleteSpace(
      input: ComAtprotoSpaceDeleteSpace.Input(space: space)
    )
  }

  func addMember(space: SpaceRef, did: DID) async throws {
    _ = try await client.com.atproto.memberspace.putMembers(
      input: ComAtprotoMemberspacePutMembers.Input(
        space: space,
        members: [ComAtprotoMemberspaceDefs.Member(did: did, read: true, write: true)]
      )
    )
  }

  func removeMember(space: SpaceRef, did: DID) async throws {
    _ = try await client.com.atproto.memberspace.removeMembers(
      input: ComAtprotoMemberspaceRemoveMembers.Input(space: space, dids: [did])
    )
  }

  /// Full member roster from the owner's own PDS. Paginates to completion so a
  /// truncated page can never read as a shrunken Circle.
  func listMembers(space: SpaceRef) async throws -> [CircleMember] {
    var members: [CircleMember] = []
    var cursor: String?
    var seenCursors: Set<String> = []
    repeat {
      let (_, output) = try await client.com.atproto.memberspace.listMembers(
        input: ComAtprotoMemberspaceListMembers.Parameters(
          space: space, limit: nil, cursor: cursor
        )
      )
      guard let output else { throw CircleError.invalidResponse }
      members.append(contentsOf: output.members.map { CircleMember(did: $0.did, read: $0.read, write: $0.write) })
      if let next = output.cursor {
        guard seenCursors.insert(next).inserted else { throw CircleError.invalidResponse }
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
    try await report(post: post, circle: circle, reason: reason, details: details, disclosure: nil)
  }

  func report(
    post: ATProtocolURI, circle: CircleSummary, reason: CircleReportReason, details: String?,
    disclosure: CircleReportDisclosure?
  ) async throws -> UUID {
    let input = try Self.reportInput(
      post: post, circle: circle, reason: reason, details: details, disclosure: disclosure
    )
    let (_, output) = try await client.blue.catbird.circle.reportRecord(input: input)
    guard let output else { throw CircleError.invalidResponse }
    guard let uuid = UUID(uuidString: output.id) else { throw CircleError.invalidResponse }
    return uuid
  }

  /// The `reportRecord` input; a disclosure becomes `disclosedPostKey` and
  /// `disclosedMedia` (lexicon bound: 32 entries).
  static func reportInput(
    post: ATProtocolURI, circle: CircleSummary, reason: CircleReportReason, details: String?,
    disclosure: CircleReportDisclosure?
  ) throws -> BlueCatbirdCircleReportRecord.Input {
    if let disclosure, disclosure.media.count > CircleReportDisclosure.maxMedia {
      throw CircleError.invalidParameter("Too many attachments to report.")
    }
    return BlueCatbirdCircleReportRecord.Input(
      space: circle.uri, uri: post, reason: reason.clientValue, details: details,
      disclosedPostKey: disclosure.map { Bytes(data: $0.postKey) },
      disclosedMedia: disclosure.map { value in
        value.media.map { .init(cid: $0.cid, key: Bytes(data: $0.key), iv: Bytes(data: $0.iv)) }
      }.flatMap { $0.isEmpty ? nil : $0 }
    )
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
    case .comAtprotoSpaceApplyWritesUpdateResult, .comAtprotoSpaceApplyWritesDeleteResult:
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
    case .comAtprotoSpaceApplyWritesUpdateResult, .comAtprotoSpaceApplyWritesDeleteResult:
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
    case .comAtprotoSpaceApplyWritesCreateResult, .comAtprotoSpaceApplyWritesUpdateResult:
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
    case .comAtprotoSpaceApplyWritesCreateResult, .comAtprotoSpaceApplyWritesUpdateResult:
      throw CircleError.spaceWriteRejected("unexpected applyWrites result")
    }
  }
}

/// The active account's encrypted-Circle machinery (`AppState.circleEncryptionContext()`).
struct CircleEncryptionContext: Sendable {
  let keyManager: CircleKeyManager
  let crypto: any CircleCrypto
  let accountDID: DID
  /// Whether this account has an enrolled Labyrinth mailbox (D16), i.e. it has
  /// turned encrypted features on. Without one the FFI cannot self-wrap.
  /// Throws when enrollment cannot be determined (I9): the caller must not
  /// read that as "not enrolled".
  let mailboxEnrolled: @Sendable () async throws -> Bool
}

/// Whether this device may create or upgrade to an encrypted Circle now
/// (spec §9): an encryption context, an enrolled mailbox, and an AppView that
/// serves encrypted posts. Otherwise Circles are created plaintext.
enum CircleEncryptionAvailability: Equatable, Sendable {
  case available
  case noEncryptionContext
  case notEnrolled
  case serviceUnsupported
  /// Enrolled, but the service's capabilities could not be read. Creating
  /// must stop here (I9): a plaintext Circle would be a silent downgrade.
  case checkFailed

  var isAvailable: Bool { self == .available }
}

/// A D17 upgrade stopped after its new Space was created (key, ACL or the old
/// Space's `migratedTo` still missing). The new Space carries the
/// `__migration__` marker; calling `upgradeToEncrypted` again with `target`
/// resumes from the first unfinished step.
struct CircleUpgradeIncompleteError: Error, Sendable {
  let target: CircleSummary
  let underlying: CircleError
}

/// Typed Circle client boundary. Holds a transport (production gateway or test
/// double) and exposes the focused Circle API surface. Errors stay
/// `CircleError`-shaped and never fall back to public endpoints.
actor CircleService {
  private static let logger = Logger(subsystem: "blue.catbird", category: "CircleService")
  private let transport: any CircleTransport
  /// Opened (decrypted) payloads; read for report disclosures (spec §8).
  private let feedCache: CircleFeedCache = .shared
  /// Key lifecycle for encrypted Circles, fixed at init (tests); nil where
  /// encryption is unavailable or resolved lazily through `encryption`.
  private let fixedKeyManager: CircleKeyManager?
  /// Post sealing for encrypted Circles, fixed at init (tests).
  private let fixedSealing: (sealer: CirclePostSealer, accountDID: DID)?
  /// Wrapping for eligibility dry runs, fixed at init (tests).
  private let fixedCrypto: (any CircleCrypto)?
  /// Mailbox enrollment, fixed at init (tests); nil uses the encryption context.
  private let fixedMailboxEnrolled: (@Sendable () async throws -> Bool)?
  /// Resolves the active account's encryption context on demand (production:
  /// the MLS client may come up after this service was created).
  private let encryption: (@Sendable () async -> CircleEncryptionContext?)?
  /// Spaces whose lifecycle ended in this session. Reads of these are refused
  /// before any request until a fresh authoritative page lists them again.
  private var retiredSpaces: Set<SpaceRef> = []
  /// Spaces this account deleted. They never un-retire: the AppView learns of a
  /// deletion in the background, so its pages can still list one for a while.
  private var deletedSpaces: Set<SpaceRef> = []
  /// Epoch of each Space's latest retirement. It outlives a cleared retirement,
  /// so a result whose request started before that retirement stays rejected.
  private var retirementEpochs: [SpaceRef: UInt64] = [:]
  private var lifecycleEpoch: UInt64 = 0
  /// `supportsEncryptedPosts` from the last successful `capabilities()`, so
  /// the composer's picker gate does not fetch per Circle. Cleared by a key
  /// refresh so Refresh re-asks the service.
  private var encryptedPostsSupported: Bool?

  init(
    transport: any CircleTransport,
    keyManager: CircleKeyManager? = nil,
    crypto: (any CircleCrypto)? = nil,
    accountDID: DID? = nil,
    mailboxEnrolled: (@Sendable () async throws -> Bool)? = nil
  ) {
    self.transport = transport
    self.fixedKeyManager = keyManager
    self.fixedCrypto = crypto
    self.fixedMailboxEnrolled = keyManager == nil ? nil : (mailboxEnrolled ?? { true })
    if let keyManager, let crypto, let accountDID {
      self.fixedSealing = (CirclePostSealer(crypto: crypto, keys: keyManager), accountDID)
    } else {
      self.fixedSealing = nil
    }
    self.encryption = nil
  }

  /// Production: the encryption context is resolved per call, so a service
  /// created before the MLS client was ready still seals once it is.
  init(transport: any CircleTransport, encryption: @escaping @Sendable () async -> CircleEncryptionContext?) {
    self.transport = transport
    self.fixedKeyManager = nil
    self.fixedSealing = nil
    self.fixedCrypto = nil
    self.fixedMailboxEnrolled = nil
    self.encryption = encryption
  }

  private func requireKeyManager() async throws -> CircleKeyManager {
    if let fixedKeyManager { return fixedKeyManager }
    guard let context = await encryption?() else {
      throw CircleError.invalidParameter("Encrypted Circles are unavailable on this device.")
    }
    return context.keyManager
  }

  /// Whether encrypted-Circle machinery exists on this device right now (no
  /// throw, no log): the MLS client may not be up yet.
  func encryptionContextAvailable() async -> Bool {
    if fixedKeyManager != nil { return true }
    return await encryption?() != nil
  }

  /// Spec §9 gate shared by the create flow and the upgrade row.
  func encryptionAvailability() async -> CircleEncryptionAvailability {
    let enrolled: Bool
    do {
      if fixedKeyManager != nil {
        enrolled = try await fixedMailboxEnrolled?() ?? true
      } else if let context = await encryption?() {
        enrolled = try await context.mailboxEnrolled()
      } else {
        return .noEncryptionContext
      }
    } catch {
      // I9: an enrollment check that throws is not "not enrolled"; creating
      // a plaintext Circle here would be a silent downgrade.
      return .checkFailed
    }
    guard enrolled else { return .notEnrolled }
    let capability: CircleCapability
    do {
      capability = try await capabilities()
    } catch {
      return .checkFailed
    }
    guard capability.supportsEncryptedPosts else { return .serviceUnsupported }
    return .available
  }

  /// Composer gate (spec §9): an encrypted Circle may be posted to only when
  /// the service serves encrypted posts and this device holds a key for it.
  /// The key read is local (no key fetch); a plaintext Circle is always ready.
  func canPostEncrypted(circle: CircleSummary) async -> Bool {
    guard circle.isEncrypted else { return true }
    let supported: Bool
    if let encryptedPostsSupported {
      supported = encryptedPostsSupported
    } else {
      supported = (try? await capabilities())?.supportsEncryptedPosts ?? false
    }
    guard supported, let manager = try? await requireKeyManager() else { return false }
    return ((try? await manager.currentKey(circle: circle)) ?? nil) != nil
  }

  /// The picker's Refresh: one key refresh for `circle`, then the gate again.
  func refreshEncryptionKeys(circle: CircleSummary) async -> Bool {
    guard circle.isEncrypted else { return true }
    encryptedPostsSupported = nil
    if let manager = try? await requireKeyManager() {
      _ = try? await manager.refreshKeys(circle: circle)
    }
    return await canPostEncrypted(circle: circle)
  }

  /// D13 before anything is uploaded for an encrypted post: the key the post
  /// would be sealed under exists and is the server's latest (and the
  /// summary's). Each failure class keeps its own user-facing error (I3,
  /// `postingKeyError`); none of them lets the post through.
  func requireEncryptedPostingKey(circle: CircleSummary) async throws {
    guard circle.isEncrypted else { return }
    do {
      let manager = try await requireKeyManager()
      let current = try await manager.keyForPosting(circle: circle)
      if let summaryLatest = circle.latestKeyVersion, summaryLatest > 0, UInt64(summaryLatest) > current.version {
        throw CircleError.encryptionUnavailable
      }
    } catch {
      throw Self.postingKeyError(error)
    }
  }

  /// I3: what the user is told when the posting key cannot be had.
  /// - Offline, directory or session trouble (retry): `keysTemporarilyUnavailable`.
  /// - This device's Keychain unreadable: `keyStoreUnavailable`.
  /// - The summary's owner is not the Space authority: `ownerMismatch`.
  /// - No key, an older key than the server's latest, or a rejected record:
  ///   `encryptionUnavailable`.
  static func postingKeyError(_ error: any Error) -> CircleError {
    switch error {
    case CircleError.ownerMismatch:
      return .ownerMismatch
    case CircleError.keysTemporarilyUnavailable, CircleError.networkError, CircleError.upstreamUnavailable:
      return .keysTemporarilyUnavailable
    case CircleError.keyStoreUnavailable, is CircleKeychainError:
      return .keyStoreUnavailable
    case is URLError:
      return .keysTemporarilyUnavailable
    case is CircleCryptoError:
      switch CircleOpenFailure(error) {
      case .transient: return .keysTemporarilyUnavailable
      case .ownerMismatch: return .ownerMismatch
      case .rejected, .untrusted: return .encryptionUnavailable
      }
    default:
      return .encryptionUnavailable
    }
  }

  private func requireCrypto() async throws -> any CircleCrypto {
    if let fixedCrypto { return fixedCrypto }
    guard let context = await encryption?() else {
      throw CircleError.invalidParameter("Encrypted Circles are unavailable on this device.")
    }
    return context.crypto
  }

  private func sealing() async -> (sealer: CirclePostSealer, accountDID: DID)? {
    if let fixedSealing { return fixedSealing }
    guard let context = await encryption?() else { return nil }
    return (CirclePostSealer(crypto: context.crypto, keys: context.keyManager), context.accountDID)
  }

  func capabilities() async throws -> CircleCapability {
    let result = try await transport.capabilities()
    guard result.protocolRevision == CircleConfiguration.protocolRevision else {
      throw CircleError.protocolRevisionMismatch
    }
    encryptedPostsSupported = result.isCompatible && result.supportsEncryptedPosts
    return result
  }

  func retireSpace(_ space: SpaceRef) {
    lifecycleEpoch += 1
    retiredSpaces.insert(space)
    retirementEpochs[space] = lifecycleEpoch
  }

  /// Whether a result for `space` from a request started at epoch `start`
  /// belongs to a retired lifecycle: the Space is retired now, or it was
  /// retired after the request started.
  private func isRetired(_ space: SpaceRef, since start: UInt64) -> Bool {
    retiredSpaces.contains(space) || retirementEpochs[space, default: 0] > start
  }

  /// A page requested after a Space's latest retirement is the AppView's
  /// current view, which lists only Circles this account may read. A Space it
  /// lists again (a member re-added) resumes; owner deletions never do.
  private func restore(_ spaces: [SpaceRef], since start: UInt64) {
    for space in spaces where !deletedSpaces.contains(space) && retirementEpochs[space, default: 0] <= start {
      retiredSpaces.remove(space)
    }
  }

  func requireImages() async throws {
    let result = try await capabilities()
    guard result.isCompatible, result.supportsImages else {
      throw CircleError.invalidParameter("Images are unavailable for this Circle service.")
    }
  }

  func listCircles(cursor: String? = nil) async throws -> CircleListPage {
    let start = lifecycleEpoch
    let page = try await transport.listCircles(cursor: cursor)
    restore(page.circles.map(\.uri), since: start)
    return page
  }

  func getFeed(space: SpaceRef?, cursor: String? = nil) async throws -> CircleFeedPage {
    if let space, retiredSpaces.contains(space) { throw CircleError.accessRemoved }
    let start = lifecycleEpoch
    let page = try await transport.getFeed(space: space, cursor: cursor)
    if let space, isRetired(space, since: start) { throw CircleError.accessRemoved }
    if space == nil { restore(page.items.map(\.circle.uri), since: start) }
    return CircleFeedPage(items: page.items.filter { !isRetired($0.circle.uri, since: start) }, cursor: page.cursor)
  }

  func getPostThread(uri: ATProtocolURI, space: SpaceRef) async throws -> CircleThreadPage {
    guard !retiredSpaces.contains(space) else { throw CircleError.accessRemoved }
    let start = lifecycleEpoch
    let page = try await transport.getPostThread(uri: uri, space: space)
    guard !isRetired(space, since: start) else { throw CircleError.accessRemoved }
    return page
  }

  func listNotifications(cursor: String? = nil) async throws -> CircleNotificationPage {
    let start = lifecycleEpoch
    let page = try await transport.listNotifications(cursor: cursor)
    // The AppView returns notifications only from Circles this account may read now.
    restore(page.notifications.map(\.circle.uri), since: start)
    return CircleNotificationPage(notifications: page.notifications.filter { !isRetired($0.circle.uri, since: start) }, cursor: page.cursor)
  }

  func media(space: SpaceRef, authorDID: DID, cid: CID) async throws -> Data {
    guard !retiredSpaces.contains(space) else { throw CircleError.accessRemoved }
    let start = lifecycleEpoch
    try await requireImages()
    let data = try await transport.media(space: space, authorDID: authorDID, cid: cid)
    guard !isRetired(space, since: start) else { throw CircleError.accessRemoved }
    return data
  }

  /// Creates a Circle. Encrypted: the Space is created empty, `v1` is written
  /// wrapped to `memberDIDs` (spec §6 rule 1), and only then are the members
  /// granted on the Space ACL, so no member is ever in a Space without a key.
  func createSpace(
    skey: String, circleId: String, name: String, memberDIDs: [DID], encrypted: Bool = false
  ) async throws -> CircleSummary {
    guard encrypted else {
      return try await transport.createSpace(skey: skey, circleId: circleId, name: name, memberDIDs: memberDIDs)
    }
    let keyManager = try await requireKeyManager()
    let summary = try await transport.createEncryptedSpace(
      skey: skey, circleId: circleId, name: name, historyForNewMembers: true, migratedFrom: nil
    )
    _ = try await keyManager.createInitialKey(circle: summary, memberDIDs: memberDIDs)
    for member in memberDIDs {
      try await transport.addMember(space: summary.uri, did: member)
    }
    return CircleSummary(
      uri: summary.uri,
      circleId: summary.circleId,
      name: summary.name,
      owner: summary.owner,
      memberCount: memberDIDs.count,
      muted: summary.muted
    )
  }

  func deleteSpace(space: SpaceRef) async throws {
    try await transport.deleteSpace(space: space)
    deletedSpaces.insert(space)
    retireSpace(space)
  }

  func addMember(space: SpaceRef, did: DID) async throws {
    // An encrypted Circle needs its key records updated; see `addMember(circle:)`.
    guard space.spaceType != CircleConfiguration.encryptedSpaceType else {
      throw CircleError.invalidParameter("Encrypted Circles require a key update to add a member.")
    }
    // Addition is idempotent and never upgrades an existing restricted grant.
    let roster = try await transport.listMembers(space: space)
    guard !roster.contains(where: { $0.did == did }) else { return }
    try await transport.addMember(space: space, did: did)
  }

  func removeMember(space: SpaceRef, did: DID) async throws {
    // Removing from an encrypted Circle without rotating would leave the member
    // able to read new posts; see `removeMember(circle:)` (fail closed).
    guard space.spaceType != CircleConfiguration.encryptedSpaceType else {
      throw CircleError.invalidParameter("Encrypted Circles require a key rotation to remove a member.")
    }
    try await transport.removeMember(space: space, did: did)
  }

  /// Adds a member. Encrypted: delegated to `CircleKeyManager.addMember`, which
  /// reads the roster under its own queue and orders the ACL grant against the
  /// key write per spec §6 rules 2–3 (history visible: grant then re-wrap
  /// history; hidden: rotate then grant).
  /// `historyVisible` has no default (I4: fail closed): every caller states
  /// the owner's current setting, read at add time.
  func addMember(circle: CircleSummary, did: DID, historyVisible: Bool) async throws {
    guard circle.isEncrypted else {
      try await addMember(space: circle.uri, did: did)
      return
    }
    try await requireKeyManager().addMember(circle: circle, did: did, historyVisible: historyVisible)
  }

  /// Removes a member. Encrypted: delegated to `CircleKeyManager.removeMember`
  /// (D14: rotate to `vN+1` first, then the ACL removal, queued and retried on
  /// failure without a second rotation).
  func removeMember(circle: CircleSummary, did: DID) async throws {
    guard circle.isEncrypted else {
      try await removeMember(space: circle.uri, did: did)
      return
    }
    try await requireKeyManager().removeMember(circle: circle, did: did)
  }

  func listMembers(space: SpaceRef) async throws -> [CircleMember] {
    try await transport.listMembers(space: space)
  }

  // MARK: - Encrypted Circle management (spec §6, §7, §9)

  /// The owner's metadata record for `space`, or nil when it has none.
  func metadata(space: SpaceRef) async throws -> BlueCatbirdCircleMetadata? {
    try await transport.getMetadata(space: space)
  }

  /// §7: writes `historyForNewMembers` into the Space's metadata record,
  /// keeping every other field. A missing record is never fabricated (its
  /// `createdAt` is not ours to invent): the write fails with `invalidResponse`.
  func setHistoryForNewMembers(circle: CircleSummary, _ value: Bool) async throws {
    guard let current = try await transport.getMetadata(space: circle.uri) else {
      throw CircleError.invalidResponse
    }
    try await transport.putMetadata(space: circle.uri, metadata: current.with(historyForNewMembers: value))
  }

  /// Dry-run wrap of a throwaway key to `dids`: the members the FFI excluded
  /// (D16: no verifiable Labyrinth mailbox) with its reasons. Nothing is
  /// written. An exclusion can be transient, so callers present it as retryable.
  func eligibility(circle: CircleSummary, dids: [DID]) async throws -> (eligible: [DID], ineligible: [(DID, reason: String)]) {
    guard !dids.isEmpty else { return ([], []) }
    let crypto = try await requireCrypto()
    let outcome = try await crypto.wrapCircleKey(
      circleID: circle.circleId.description,
      keyVersion: 1,
      spaceURI: circle.uri.uriString(),
      reason: "created",
      memberDIDs: dids.map { $0.didString() },
      circleKey: try await crypto.generateCircleKey(),
      createdAt: Date()
    )
    let excluded = Dictionary(outcome.excluded.map { ($0.did, $0.reason) }, uniquingKeysWith: { first, _ in first })
    return (
      dids.filter { excluded[$0.didString()] == nil },
      dids.compactMap { did in excluded[did.didString()].map { (did, reason: $0) } }
    )
  }

  /// §6 rule 7: owner-triggered rotation to `vN+1`.
  func rotateKey(circle: CircleSummary, reason: String) async throws {
    _ = try await requireKeyManager().rotate(circle: circle, reason: reason)
  }

  func pendingRewraps(circle: CircleSummary) async throws -> [(did: String, reason: String)] {
    try await requireKeyManager().pendingRewraps(circle: circle)
  }

  func retryPendingRewraps(circle: CircleSummary) async throws {
    try await requireKeyManager().retryPendingRewraps(circle: circle)
  }

  /// §6 rules 5–6 on the owner's device (launch / management appear).
  func reconcileEpochs(circle: CircleSummary) async throws {
    try await requireKeyManager().reconcileEpochs(circle: circle)
  }

  /// The new Space of an unfinished upgrade from `old`, if this device started one.
  func pendingUpgradeTarget(from old: CircleSummary) async throws -> CircleSummary? {
    guard let uri = try await requireKeyManager().pendingMigrationTarget(from: old) else { return nil }
    return CircleSummary(
      uri: try SpaceRef(uriString: uri), circleId: old.circleId, name: old.name,
      owner: old.owner, memberCount: nil, muted: false
    )
  }

  /// D17 upgrade of the plaintext Circle `old`, steps 1–4 (the caller
  /// activates the returned Space, step 5):
  /// 1. create a `blue.catbird.circle.encrypted` Space with the same `circleId`
  ///    and name, `metadata.migratedFrom = old`, `historyForNewMembers` copied;
  ///    then record the `__migration__` marker and the plan (`eligible`, step 2);
  /// 2. write `v1` wrapped to the plan's members;
  /// 3. grant each of them on the new ACL (`__aclAdd__` pending until granted);
  /// 4. write `migratedTo` on the old Space's metadata.
  /// A failure in steps 2–4 throws `CircleUpgradeIncompleteError`. Calling
  /// again with its `target` resumes from the persisted plan: `eligible` is
  /// then ignored, so the grants are exactly `v1`'s recipients, never a freshly
  /// computed set. `migratedTo` is written only after every one of them is in.
  /// Old plaintext posts stay in the old Space.
  func upgradeToEncrypted(
    from old: CircleSummary, eligible: [DID], resuming target: CircleSummary? = nil
  ) async throws -> CircleSummary {
    guard !old.isEncrypted else {
      throw CircleError.invalidParameter("This Circle is already encrypted.")
    }
    let keyManager = try await requireKeyManager()
    // The old record carries `createdAt` for step 4; it is never invented.
    guard let oldMetadata = try await transport.getMetadata(space: old.uri) else {
      throw CircleError.invalidResponse
    }
    if target == nil, oldMetadata.migratedTo != nil {
      throw CircleError.invalidParameter("This Circle was already upgraded.")
    }
    let new: CircleSummary
    if let target {
      new = target
    } else {
      let skey = await TIDGenerator.shared.nextStr()
      new = try await transport.createEncryptedSpace(
        skey: skey,
        circleId: old.circleId.description,
        name: old.name,
        historyForNewMembers: oldMetadata.historyForNewMembers ?? true,
        migratedFrom: old.uri
      )
    }
    var members = eligible
    do {
      if target == nil {
        try await keyManager.markMigrationIncomplete(from: old, to: new)
        try await keyManager.setMigrationPlan(circle: new, eligible: eligible, step: 2)
      } else {
        guard let plan = try await keyManager.migrationPlan(circle: new) else {
          throw CircleError.invalidResponse
        }
        members = plan.eligible
      }
      // Step 2 (kept on resume once this device holds a key for the new Space).
      if try await keyManager.latestLocalVersion(circle: new) == nil {
        _ = try await keyManager.createInitialKey(circle: new, memberDIDs: members)
      }
      try await keyManager.setMigrationPlan(circle: new, eligible: members, step: 3)
      // Step 3: only v1's recipients.
      let granted = Set(try await transport.listMembers(space: new.uri).map(\.did))
      for did in members where !granted.contains(did) {
        try await keyManager.grantWrappedMember(circle: new, did: did)
      }
      try await keyManager.setMigrationPlan(circle: new, eligible: members, step: 4)
      // Step 4, only once every one of them is in.
      try await transport.putMetadata(space: old.uri, metadata: oldMetadata.with(migratedTo: new.uri))
    } catch {
      throw CircleUpgradeIncompleteError(target: new, underlying: circleError(from: error))
    }
    // The upgrade is complete. A marker left by a Keychain failure only makes a
    // later retry repeat step 4 (idempotent) and clear it then.
    try? await keyManager.clearMigrationMarkers(from: old, to: new)
    return CircleSummary(
      uri: new.uri, circleId: new.circleId, name: new.name, owner: new.owner,
      memberCount: members.count, muted: new.muted
    )
  }

  func updatePreferences(space: SpaceRef, muted: Bool) async throws -> Bool {
    try await transport.updatePreferences(space: space, muted: muted)
  }

  /// Reports a post. For an encrypted Circle the report discloses the post
  /// key and its media keys (spec §8; the sheet shows the consent first),
  /// taken from this account's opened copy of `(post, cid)`.
  func report(
    post: ATProtocolURI, circle: CircleSummary, reason: CircleReportReason, details: String? = nil, cid: CID? = nil
  ) async throws -> UUID {
    try await report(
      post: post, circle: circle, reason: reason, details: details, cid: cid.map { CIDString($0) }
    )
  }

  func report(
    post: ATProtocolURI, circle: CircleSummary, reason: CircleReportReason, details: String? = nil, cid: CIDString?
  ) async throws -> UUID {
    guard circle.isEncrypted else {
      return try await transport.report(post: post, circle: circle, reason: reason, details: details)
    }
    let disclosure = try await reportDisclosure(post: post, cid: cid, circle: circle)
    return try await transport.report(
      post: post, circle: circle, reason: reason, details: details, disclosure: disclosure
    )
  }

  /// The §8 disclosure for an encrypted post this account opened.
  func reportDisclosure(post: ATProtocolURI, cid: CID?, circle: CircleSummary) async throws -> CircleReportDisclosure {
    try await reportDisclosure(post: post, cid: cid.map { CIDString($0) }, circle: circle)
  }

  func reportDisclosure(post: ATProtocolURI, cid: CIDString?, circle: CircleSummary) async throws -> CircleReportDisclosure {
    guard let cid, let accountDID = await activeAccountDID(),
          let payload = feedCache.openedPayload(
            accountDID: accountDID.didString(), space: circle.uri, uri: post, cid: cid
          ),
          payload.keyVersion > 0
    else {
      throw CircleError.invalidParameter(CircleReportCopy.notOpened)
    }
    guard payload.media.count <= CirclePostSealer.maxAttachments else {
      throw CircleError.invalidParameter("Too many attachments to report.")
    }
    guard let circleKey = try await requireKeyManager().key(circle: circle, version: payload.keyVersion) else {
      throw CircleError.encryptionUnavailable
    }
    let postKey: Data
    do {
      postKey = try await requireCrypto().postKey(
        circleKey: circleKey, circleID: circle.circleId.description, postURI: post.uriString()
      )
    } catch {
      throw CircleError.encryptionUnavailable
    }
    return CircleReportDisclosure(
      postKey: postKey,
      media: payload.media.map { .init(cid: $0.cid.string, key: $0.key, iv: $0.iv) }
    )
  }

  private func activeAccountDID() async -> DID? {
    if let fixedSealing { return fixedSealing.accountDID }
    return await encryption?()?.accountDID
  }

  func activateCircle(space: SpaceRef) async throws -> CircleSummary {
    try await transport.activateCircle(space: space)
  }

  /// Plaintext Circle: an `app.bsky.feed.post` via the transport. Encrypted
  /// Circle (spec §4.5): seal under the latest key (`CirclePostSealer`, D13)
  /// and write a `blue.catbird.circle.post` at the rkey bound into the AAD.
  /// Every failure on the encrypted path throws; nothing ever falls back to a
  /// plaintext or public write.
  func publishPost(destination: CircleSummary, draft: CirclePostDraft) async throws -> ATProtocolURI {
    try await publish(destination: destination, draft: draft).uri
  }

  /// `publishPost`, also reporting a §4.4 repost. After an encrypted publish
  /// the server's latest key version is re-read; if the post was sealed under
  /// an older key, it is re-sealed under the latest one with a fresh rkey,
  /// published, and the stale record deleted. At most one retry; a failed
  /// retry keeps the original post (it was accepted and stays readable to
  /// members holding its key).
  func publish(destination: CircleSummary, draft: CirclePostDraft) async throws -> CirclePublishResult {
    guard destination.isEncrypted else {
      guard draft.encryptedMedia.isEmpty else {
        throw CircleError.invalidParameter("Encrypted attachments can only be posted to an encrypted Circle.")
      }
      let uri = try await transport.publishPost(destination: destination, draft: draft)
      return CirclePublishResult(uri: uri, repostedAfterKeyRefresh: false)
    }
    guard let sealing = await sealing() else { throw CircleError.encryptionUnavailable }
    let first = try await sealAndWrite(destination: destination, draft: draft, sealing: sealing)

    // §4.4 race backstop (I7). The post is already written; a failed check is
    // logged and reported (`keyCheckFailed`), never swallowed.
    let latest: Int
    do {
      latest = try await transport.getKeys(space: destination.uri, sinceVersion: first.keyVersion).latestKeyVersion
    } catch {
      Self.logger.warning(
        "Circles: the post-publish key check failed (\(String(describing: type(of: error)), privacy: .public)); the post may need reposting"
      )
      return CirclePublishResult(uri: first.uri, repostedAfterKeyRefresh: false, keyCheckFailed: true)
    }
    guard latest > first.keyVersion else {
      return CirclePublishResult(uri: first.uri, repostedAfterKeyRefresh: false)
    }
    let refreshed = CircleSummary(
      uri: destination.uri, circleId: destination.circleId, name: destination.name, owner: destination.owner,
      memberCount: destination.memberCount, muted: destination.muted, latestKeyVersion: latest
    )
    let second: (uri: ATProtocolURI, postURI: ATProtocolURI, keyVersion: Int)
    do {
      second = try await sealAndWrite(destination: refreshed, draft: draft, sealing: sealing)
    } catch {
      Self.logger.error(
        "Circles: repost after key refresh failed (\(String(describing: type(of: error)), privacy: .public))"
      )
      return CirclePublishResult(uri: first.uri, repostedAfterKeyRefresh: false)
    }
    do {
      try await transport.deleteEncryptedPost(uri: first.postURI, circle: destination)
    } catch {
      Self.logger.error(
        "Circles: deleting the stale post failed (\(String(describing: type(of: error)), privacy: .public))"
      )
    }
    return CirclePublishResult(uri: second.uri, repostedAfterKeyRefresh: true)
  }

  /// Seals `draft` under the latest key at a fresh rkey and writes it.
  private func sealAndWrite(
    destination: CircleSummary, draft: CirclePostDraft, sealing: (sealer: CirclePostSealer, accountDID: DID)
  ) async throws -> (uri: ATProtocolURI, postURI: ATProtocolURI, keyVersion: Int) {
    let rkey = await TIDGenerator.shared.nextTID().description
    let postURI = try CirclePostSealer.canonicalPostURI(authorDID: sealing.accountDID, rkey: rkey)
    let sealed: (recordJSON: String, attachments: [Blob])
    do {
      sealed = try await sealing.sealer.seal(
        draft: draft, media: draft.encryptedMedia, circle: destination,
        authorDID: sealing.accountDID, postURI: postURI
      )
    } catch let error as CircleError {
      throw error
    } catch {
      throw Self.postingKeyError(error)
    }
    guard let keyVersion = CircleKeyManager.recordHeader(fromRecordJSON: sealed.recordJSON)?.keyVersion else {
      throw CircleError.encryptionUnavailable
    }
    // The server's answer may use the space URI form; crypto used `postURI`.
    let uri = try await transport.publishEncryptedPost(
      destination: destination, postURI: postURI, recordJSON: sealed.recordJSON
    )
    return (uri, postURI, keyVersion)
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

extension BlueCatbirdCircleMetadata {
  /// A copy with `historyForNewMembers` replaced, every other field kept.
  func with(historyForNewMembers value: Bool) -> BlueCatbirdCircleMetadata {
    BlueCatbirdCircleMetadata(
      circleId: circleId, name: name, createdAt: createdAt, migratedFrom: migratedFrom,
      migratedTo: migratedTo, historyForNewMembers: value, encryption: encryption
    )
  }

  /// A copy with `migratedTo` replaced, every other field kept.
  func with(migratedTo value: SpaceRef) -> BlueCatbirdCircleMetadata {
    BlueCatbirdCircleMetadata(
      circleId: circleId, name: name, createdAt: createdAt, migratedFrom: migratedFrom,
      migratedTo: value, historyForNewMembers: historyForNewMembers, encryption: encryption
    )
  }
}
