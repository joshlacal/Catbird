import CPetrelBLAKE3
import CatbirdMLS
import CryptoKit
import Foundation
import PetrelCore
import PetrelCrypto
import PetrelCatbird

/// In-process home `mls-ds` plus per-account PDS/Space hosts serving the verified native archive
/// (`LabyrinthSession`) contract. Swift port of `catbird-mls/tests/support/native_archive_auth.rs`
/// (Space tokens, RFC 9421 PoP, `Atproto-Space-Mac`, LtHash commits, DAG-CBOR CIDs,
/// `mailboxKeys` CAS) and the `client_live_chat_data_plane.rs` mock DS (enrollment, group
/// invite/accept/welcome, entries, ES256 `#mls-receipt-1` I13 receipts, epoch heads).
///
/// Fixed test-only keys. Each account's PDS is `https://<plc-id>.pds.catbird.blue`, so the PDS host
/// names the OAuth principal; DS principals are the enrolled chat device a request names.
/// Requests that break the contract are refused and recorded in `contractViolations`.
final class NativeArchiveMockNetwork: @unchecked Sendable {
  typealias JSON = [String: Any]

  struct Reply {
    var status: Int
    var headers: [String: String] = ["Content-Type": "application/json"]
    var body: Data
  }

  static let shared = NativeArchiveMockNetwork()
  static let dsDid = "did:web:chat.catbird.blue"
  static let dsEndpoint = "https://chat.catbird.blue"
  static let batch = "blue.catbird.labyrinth.batch"
  static let ownerBatch = "blue.catbird.labyrinth.ownerBatch"
  private static let dsHost = "chat.catbird.blue"
  private static let pdsSuffix = ".pds.catbird.blue"
  private static let mailboxKeysCollection = "blue.catbird.labyrinth.mailboxKeys"
  private static let credentialLabel = "atproto-space-credential"

  static func pdsEndpoint(for did: String) -> String {
    "https://\(did.dropFirst("did:plc:".count))\(pdsSuffix)"
  }

  private struct RecordKey: Hashable, Comparable {
    let space: String
    let repo: String
    let collection: String
    let rkey: String

    static func < (lhs: RecordKey, rhs: RecordKey) -> Bool {
      (lhs.space, lhs.repo, lhs.collection, lhs.rkey) < (rhs.space, rhs.repo, rhs.collection, rhs.rkey)
    }
  }

  private struct StoredRecord {
    let value: Any
    let cid: CID
  }

  private struct SpaceOperation {
    let collection: String
    let rkey: String
    let rev: String
    let cid: String?
    let previousCID: String?
  }

  private struct Fault: Error {
    let message: String
  }

  private let lock = NSLock()
  private var signingKeys: [String: P256.Signing.PrivateKey] = [:]
  private var kemKeys: [String: P256.KeyAgreement.PrivateKey] = [:]
  private var violations: [String] = []
  private var statusOverrides: [String: Int] = [:]
  private var overrideRejections: [String: Int] = [:]
  private var mainThreadRequest = false
  private var sequence: UInt64 = 0
  // PDS + Space world.
  private var records: [RecordKey: StoredRecord] = [:]
  private var mailboxKeys: [String: [String: StoredRecord]] = [:]
  private var repoRevisions: [String: String] = [:]
  private var repoOperations: [String: [SpaceOperation]] = [:]
  private var spentDelegations: Set<String> = []
  private struct RepositorySnapshot {
    let root: CID
    let revision: String
    let commit: CID
    let car: Data
  }
  private var signedRepositories: [String: RepositorySnapshot] = [:]
  private var pdsRecords: [String: (value: JSON, cid: CID)] = [:]
  private var blobs: [String: Data] = [:]
  // DS world.
  private var deviceKeys: [String: [String: Data]] = [:]
  private var conversationKeyPackages: [String: [JSON]] = [:]
  private var directRequestRevisions: [String: Int64] = [:]
  private var conversations: [String: JSON] = [:]
  private var entries: [String: [JSON]] = [:]
  private var pendingWelcomes: [String: [JSON]] = [:]
  private var leafRecoveries: [String: [JSON]] = [:]
  private var epochHeads: [String: [JSON]] = [:]
  /// Per conversation device leaf periods: `userDid`, `deviceId`, `joinedSeq`, `removedSeq`.
  private var leafPeriods: [String: [JSON]] = [:]
  /// Message IDs whose application entry `getEntries` serves with an altered `I13` receipt signature.
  private var forgedReceiptMessageIds: Set<String> = []
  private var spaceDenialForgery: SpaceDenialForgery?

  /// How a conversation Space refusal deviates from the authority's signed denial
  /// (`mls-ds` `space_denial_two_home_live.rs` relays).
  enum SpaceDenialForgery {
    /// The refusal without its `denial`.
    case unsigned
    /// The denial's `jti` claim altered under the original signature.
    case tampered
  }

  func reset() {
    lock.lock()
    defer { lock.unlock() }
    violations = []
    statusOverrides = [:]
    overrideRejections = [:]
    mainThreadRequest = false
    sequence = 0
    records = [:]
    mailboxKeys = [:]
    repoRevisions = [:]
    repoOperations = [:]
    spentDelegations = []
    pdsRecords = [:]
    signedRepositories = [:]
    blobs = [:]
    deviceKeys = [:]
    conversationKeyPackages = [:]
    directRequestRevisions = [:]
    conversations = [:]
    entries = [:]
    pendingWelcomes = [:]
    leafRecoveries = [:]
    epochHeads = [:]
    leafPeriods = [:]
    forgedReceiptMessageIds = []
    spaceDenialForgery = nil
  }

  // MARK: - Test controls

  /// Every Space operation on `space` answers `status` (`503` offline, `403` access revoked). A
  /// `403` conversation Space credential request gets the authority's signed denial, as from `mls-ds`.
  func setStatusOverride(_ status: Int?, forSpace space: String) {
    locked { statusOverrides[space] = status }
  }

  /// Serve each signed Space denial `forgery`d; `nil` serves it as the authority signed it.
  func forgeSpaceDenials(_ forgery: SpaceDenialForgery?) {
    locked { spaceDenialForgery = forgery }
  }

  /// Space operations on `space` answered with its status override so far.
  func overrideRejections(forSpace space: String) -> Int {
    locked { overrideRejections[space] ?? 0 }
  }

  func recordCount(space: String, repo: String, collection: String) -> Int {
    locked { records.keys.filter { $0.space == space && $0.repo == repo && $0.collection == collection }.count }
  }

  /// Sealed message items across `collection` batch records (the server-visible `items` arrays).
  func archivedItemCount(space: String, repo: String, collection: String) -> Int {
    locked {
      records.filter { $0.key.space == space && $0.key.repo == repo && $0.key.collection == collection }
        .reduce(0) { $0 + (($1.value.value as? JSON)?["items"] as? [Any] ?? []).count }
    }
  }

  var contractViolations: [String] { locked { violations } }
  var sawMainThreadRequest: Bool { locked { mainThreadRequest } }

  /// `getEntries` serves each listed message's application entry with one bit of its `I13`
  /// receipt signature flipped; the stored entry is unchanged, so `[]` serves every entry genuine.
  func forgeReceipts(messageIds: Set<String>) {
    locked { forgedReceiptMessageIds = messageIds }
  }

  /// Hex Labyrinth device key of the `account` mailbox device bound to chat device `chatDeviceId`.
  func labyrinthDeviceKeyHex(account: String, chatDeviceId: String) -> String? {
    locked {
      guard let chatKey = deviceKeys[account]?[chatDeviceId] else { return nil }
      let mailbox = "at:space/\(account)/blue.catbird.labyrinth.mailbox/self"
      for (key, record) in records
      where key.space == mailbox && key.repo == account && key.collection == "blue.catbird.labyrinth.device" {
        guard let value = record.value as? JSON,
              let binding = value["chatBinding"] as? JSON,
              bytes(binding["transportPubkey"]) == chatKey,
              let deviceKey = bytes(value["deviceKeyPubkey"])
        else { continue }
        return deviceKey.map { String(format: "%02x", $0) }.joined()
      }
      return nil
    }
  }

  // MARK: - Dispatch

  func handle(_ request: URLRequest, body: Data, onMainThread: Bool) -> Reply {
    lock.lock()
    defer { lock.unlock() }
    if onMainThread {
      mainThreadRequest = true
    }
    guard let url = request.url, let host = url.host?.lowercased() else {
      return xrpcError(400, "InvalidRequest", "missing host")
    }
    let method = request.httpMethod ?? "GET"
    if host == Self.dsHost, url.path == "/.well-known/did.json" {
      return reply(200, didDocument(Self.dsDid))
    }
    if host == "plc.directory", url.path.hasPrefix("/did:plc:") {
      return reply(200, didDocument(String(url.path.dropFirst())))
    }
    guard url.path.hasPrefix("/xrpc/") else {
      return xrpcError(404, "NotFound", url.path)
    }
    let nsid = String(url.path.dropFirst("/xrpc/".count))
    let rawQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
    do {
      if host == Self.dsHost {
        return try handleDS(nsid: nsid, method: method, rawQuery: rawQuery, request: request, body: body)
      }
      guard host.hasSuffix(Self.pdsSuffix) else {
        return xrpcError(404, "NotFound", host)
      }
      let account = "did:plc:" + host.dropLast(Self.pdsSuffix.count)
      return try handlePDS(account: account, nsid: nsid, method: method, rawQuery: rawQuery, request: request, body: body)
    } catch let fault as Fault {
      violations.append("\(nsid): \(fault.message)")
      return xrpcError(500, "FixtureContractViolation", fault.message)
    } catch {
      violations.append("\(nsid): \(error)")
      return xrpcError(500, "FixtureContractViolation", "\(error)")
    }
  }

  /// `PetrelPlatformTransport` `httpOverride` entry: the same dispatch `NativeArchiveMockURLProtocol` uses.
  func handle(_ request: PlatformHttpRequest) -> PlatformHttpResponse {
    guard let url = URL(string: request.url) else {
      let reply = xrpcError(400, "InvalidRequest", "invalid URL")
      return PlatformHttpResponse(status: UInt16(reply.status), headers: [], body: reply.body)
    }
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = request.method
    for header in request.headers {
      urlRequest.setValue(header.value, forHTTPHeaderField: header.name)
    }
    let reply = handle(urlRequest, body: request.body ?? Data(), onMainThread: Thread.isMainThread)
    return PlatformHttpResponse(
      status: UInt16(reply.status),
      headers: reply.headers.map { PlatformHttpHeader(name: $0.key, value: $0.value) },
      body: reply.body
    )
  }

  // MARK: - PDS + Space host (native_archive_auth.rs)

  private func handlePDS(
    account: String, nsid: String, method: String, rawQuery: String, request: URLRequest, body: Data
  ) throws -> Reply {
    if nsid == "com.atproto.sync.getBlocks" {
      return xrpcError(501, "NotImplemented")
    }
    let params = try strictQuery(rawQuery)
    let now = nowSeconds()
    switch nsid {
    case "com.atproto.identity.resolveDid":
      return reply(200, ["didDoc": didDocument(try required(params, "did"))])
    case "com.atproto.sync.getRecord", "com.atproto.sync.getRepo", "com.atproto.sync.getLatestCommit":
      guard method == "GET", try required(params, "did") == account else {
        return xrpcError(400, "InvalidRequest", "repository mismatch")
      }
      if nsid == "com.atproto.sync.getRecord" {
        let collection = try required(params, "collection")
        let rkey = try required(params, "rkey")
        let present = collection == Self.mailboxKeysCollection
          ? mailboxKeys[account]?[rkey] != nil
          : pdsRecords["\(account)|\(collection)|\(rkey)"] != nil
        guard present else { return xrpcError(404, "RecordNotFound") }
      }
      let snapshot = try repositorySnapshot(did: account)
      if nsid == "com.atproto.sync.getLatestCommit" {
        return reply(200, ["cid": snapshot.commit.string, "rev": snapshot.revision])
      }
      return Reply(status: 200, headers: ["Content-Type": "application/vnd.ipld.car"], body: snapshot.car)
    case "com.atproto.repo.uploadBlob":
      let cid = CID.fromBlob(body)
      blobs["\(account)|\(cid.string)"] = body
      return reply(200, [
        "blob": [
          "$type": "blob",
          "ref": ["$link": cid.string],
          "mimeType": "application/octet-stream",
          "size": body.count,
        ],
      ])
    case "com.atproto.repo.createRecord", "com.atproto.repo.putRecord", "com.atproto.repo.getRecord",
         "com.atproto.repo.listRecords", "com.atproto.repo.deleteRecord":
      let json = method == "POST" ? try object(body) : nil
      let collection = (json?["collection"] as? String) ?? params["collection"]
      if collection == Self.mailboxKeysCollection {
        return try mailboxKeysRecord(account: account, nsid: nsid, params: params, body: json)
      }
      return try repoRecord(nsid: nsid, params: params, body: json)
    case "com.atproto.space.getDelegationToken":
      let space = try SpaceURI(try required(params, "space"))
      let token = SpaceToken.mint(typ: SpaceToken.delegation, key: signingKey(account), claims: [
        "iss": account, "sub": space.raw, "aud": "\(space.authority)#atproto_pds",
        "iat": now, "exp": now + 60, "jti": "delegation-\(next())",
      ])
      return reply(200, ["token": token])
    case "com.atproto.space.authorizeSpaceSync", "com.atproto.space.getSpaceCredential":
      return try spaceCredential(account: account, body: try object(body), relayed: false, now: now)
    case "com.atproto.space.applyWrites":
      return try applyWrites(account: account, body: try object(body))
    case "com.atproto.space.deleteRecord":
      let json = try object(body)
      return try applyWrites(account: account, body: [
        "space": json["space"] ?? NSNull(), "repo": json["repo"] ?? NSNull(),
        "writes": [[
          "$type": "com.atproto.space.applyWrites#delete",
          "collection": json["collection"] ?? NSNull(), "rkey": json["rkey"] ?? NSNull(),
        ]],
      ])
    case "com.atproto.space.listSpaces":
      let spaces = Set(records.keys.filter { $0.repo == account }.map(\.space)).sorted()
      return reply(200, ["spaces": spaces.map { ["uri": $0] }])
    case "com.atproto.space.getSpace" where params["space"] == nil:
      return xrpcError(400, "InvalidRequest", "space required")
    default:
      guard method == "GET", nsid.hasPrefix("com.atproto.space.") else {
        throw Fault(message: "unsupported native Space fixture endpoint")
      }
      return try spaceRead(
        account: account, nsid: nsid, params: params,
        authorization: try header(request, "authorization"),
        audience: try header(request, "atproto-space-audience"),
        signatureInput: try header(request, "signature-input"),
        signature: try header(request, "signature"),
        acceptSignature: request.value(forHTTPHeaderField: "accept-signature")
          ?? request.value(forHTTPHeaderField: "atproto-space-want-mac"),
        now: now
      )
    }
  }

  private func didDocument(_ did: String) -> JSON {
    var methods: [JSON] = []
    if did == Self.dsDid {
      methods.append(verificationMethod(did, "#mls-receipt-1", receiptKey.publicKey))
    }
    methods.append(verificationMethod(did, "#atproto", signingKey(did).publicKey))
    let kem = kemKey(did).publicKey.compressedRepresentation
    methods.append(verificationMethod(did, "#atproto_kem", try! P256.Signing.PublicKey(compressedRepresentation: kem)))
    var services: [JSON] = []
    if did.hasPrefix("did:plc:") {
      services.append(["id": "#atproto_pds", "type": "AtprotoPersonalDataServer", "serviceEndpoint": Self.pdsEndpoint(for: did)])
    }
    return ["id": did, "verificationMethod": methods, "service": services]
  }

  private func verificationMethod(_ did: String, _ fragment: String, _ key: P256.Signing.PublicKey) -> JSON {
    ["id": did + fragment, "controller": did, "type": "Multikey",
     "publicKeyMultibase": String(P256DIDKey(publicKey: key).value.dropFirst("did:key:".count))]
  }

  private func mailboxKeysRecord(account: String, nsid: String, params: [String: String], body: JSON?) throws -> Reply {
    let repo = try (body?["repo"] as? String) ?? required(params, "repo")
    let rkey = (body?["rkey"] as? String) ?? params["rkey"]
    let uri = { (rkey: String) in "at://\(repo)/\(Self.mailboxKeysCollection)/\(rkey)" }
    switch nsid {
    case "com.atproto.repo.createRecord":
      guard account == repo else { return xrpcError(403, "NotAuthorized") }
      guard let rkey, let body, let value = body["record"] else { throw Fault(message: "mailbox record missing") }
      if mailboxKeys[repo]?[rkey] != nil {
        return xrpcError(400, "DuplicateRecord")
      }
      let cid = try dagCborCID(value)
      mailboxKeys[repo, default: [:]][rkey] = StoredRecord(value: value, cid: cid)
      return reply(200, ["uri": uri(rkey), "cid": cid.string])
    case "com.atproto.repo.putRecord":
      guard account == repo else { return xrpcError(403, "NotAuthorized") }
      guard let rkey, let body, let value = body["record"] else { throw Fault(message: "mailbox record missing") }
      if body.keys.contains("swapRecord"), (body["swapRecord"] as? String) != mailboxKeys[repo]?[rkey]?.cid.string {
        return xrpcError(400, "InvalidSwap")
      }
      let cid = try dagCborCID(value)
      mailboxKeys[repo, default: [:]][rkey] = StoredRecord(value: value, cid: cid)
      return reply(200, ["uri": uri(rkey), "cid": cid.string])
    case "com.atproto.repo.getRecord":
      guard let rkey else { throw Fault(message: "mailbox rkey missing") }
      guard let record = mailboxKeys[repo]?[rkey] else { return xrpcError(404, "RecordNotFound") }
      return reply(200, ["uri": uri(rkey), "cid": record.cid.string, "value": record.value])
    case "com.atproto.repo.listRecords":
      let limit = try pageLimit(params, default: 100)
      var listed = (mailboxKeys[repo] ?? [:]).sorted { $0.key < $1.key }
        .filter { params["cursor"] == nil || $0.key > params["cursor"]! }
      let more = listed.count > limit
      listed = Array(listed.prefix(limit))
      var out: JSON = ["records": listed.map { ["uri": uri($0.key), "cid": $0.value.cid.string, "value": $0.value.value] }]
      if more, let last = listed.last { out["cursor"] = last.key }
      return reply(200, out)
    default:
      guard account == repo else { return xrpcError(403, "NotAuthorized") }
      guard let rkey else { throw Fault(message: "mailbox rkey missing") }
      if let expected = body?["swapRecord"] as? String, mailboxKeys[repo]?[rkey]?.cid.string != expected {
        return xrpcError(400, "InvalidSwap")
      }
      mailboxKeys[repo]?[rkey] = nil
      return reply(200, JSON())
    }
  }

  /// Non-mailbox repo records (`blue.catbird.chat.device`, `.declaration`), as the mock DS stores them.
  private func repoRecord(nsid: String, params: [String: String], body: JSON?) throws -> Reply {
    switch nsid {
    case "com.atproto.repo.createRecord":
      guard let body, let repo = body["repo"] as? String, let collection = body["collection"] as? String,
            let rkey = body["rkey"] as? String, let value = body["record"] as? JSON
      else { throw Fault(message: "createRecord body malformed") }
      if pdsRecords["\(repo)|\(collection)|\(rkey)"] != nil {
        return xrpcError(400, "DuplicateRecord")
      }
      let cid = try dagCborCID(value)
      pdsRecords["\(repo)|\(collection)|\(rkey)"] = (value, cid)
      return reply(200, ["uri": "at://\(repo)/\(collection)/\(rkey)", "cid": cid.string])
    case "com.atproto.repo.putRecord":
      guard let body, let repo = body["repo"] as? String, let collection = body["collection"] as? String,
            let rkey = body["rkey"] as? String, let value = body["record"] as? JSON
      else { throw Fault(message: "putRecord body malformed") }
      let cid = try dagCborCID(value)
      pdsRecords["\(repo)|\(collection)|\(rkey)"] = (value, cid)
      return reply(200, ["uri": "at://\(repo)/\(collection)/\(rkey)", "cid": cid.string])
    case "com.atproto.repo.getRecord":
      let (repo, collection, rkey) = (try required(params, "repo"), try required(params, "collection"), try required(params, "rkey"))
      guard let record = pdsRecords["\(repo)|\(collection)|\(rkey)"] else { return xrpcError(400, "RecordNotFound") }
      return reply(200, ["uri": "at://\(repo)/\(collection)/\(rkey)", "cid": record.cid.string, "value": record.value])
    case "com.atproto.repo.listRecords":
      let prefix = "\(try required(params, "repo"))|\(try required(params, "collection"))|"
      let listed = pdsRecords.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }.map { entry in
        let parts = entry.key.split(separator: "|").map(String.init)
        return ["uri": "at://\(parts[0])/\(parts[1])/\(parts[2])", "cid": entry.value.cid.string, "value": entry.value.value] as JSON
      }
      return reply(200, ["records": listed])
    default:
      throw Fault(message: "repo deleteRecord outside mailboxKeys")
    }
  }

  private func spaceCredential(account: String, body: JSON, relayed: Bool, now: UInt64) throws -> Reply {
    let space = try SpaceURI(try text(body, "space"))
    if relayed, try text(body, "authorityDid") != space.authority {
      throw Fault(message: "relay authority mismatch")
    }
    let kid: String
    if relayed {
      kid = try text(body, "cnfKey")
    } else if let credKey = body["credentialKey"] as? String {
      kid = credKey
    } else {
      kid = try text(body, "credentialKid")
    }
    _ = try P256DIDKey(kid)
    guard let delegation = SpaceToken.verify(try text(body, "delegationToken"), typ: SpaceToken.delegation, issuerKey: { self.signingKey($0).publicKey }),
          delegation["iss"] as? String == account, delegation["sub"] as? String == space.raw,
          delegation["aud"] as? String == "\(space.authority)#atproto_pds",
          let exp = uint64(delegation["exp"]), exp > now, let jti = delegation["jti"] as? String
    else { throw Fault(message: "delegation account/Space/expiry mismatch") }
    // `mls-ds` `space_host`: once the delegation verifies, a non-member of a conversation Space is
    // refused with the authority's signed denial of exactly this request.
    if statusOverrides[space.raw] == 403, space.spaceType == "blue.catbird.labyrinth.conversation" {
      overrideRejections[space.raw, default: 0] += 1
      return try spaceDenial(space, requester: account, kid: kid, now: now)
    }
    if let denied = overridden(space.raw) { return denied }
    guard spentDelegations.insert("\(account):\(jti)").inserted else { throw Fault(message: "delegation replay") }
    let expires = now + 600
    let credential = SpaceToken.mint(typ: SpaceToken.credential, key: signingKey(space.authority), claims: [
      "iss": space.authority, "sub": space.raw, "iat": now, "exp": expires,
      "jti": "credential-\(next())", "cnf": ["kid": kid],
    ])
    let expiresAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(expires)))
    return reply(200, ["credential": credential, "expiresAt": expiresAt])
  }

  /// `mls-ds` `mint_space_denial`: the authority's `#atproto` ES256 refusal of `requester`'s
  /// credential request under PoP key `kid`, binding the Space's conversation, generation and MLS
  /// group, live 60 s; `forgeSpaceDenials` serves it unsigned or tampered instead.
  private func spaceDenial(_ space: SpaceURI, requester: String, kid: String, now: UInt64) throws -> Reply {
    guard let dash = space.skey.lastIndex(of: "-"),
          let generation = UInt64(space.skey[space.skey.index(after: dash)...]),
          let group = bytes((conversations[String(space.skey[..<dash])]?["coordinates"] as? JSON)?["groupId"])
    else { throw Fault(message: "denied Space names no fixture conversation") }
    var claims: JSON = [
      "iss": space.authority, "sub": space.raw, "aud": requester, "iat": now, "exp": now + 60,
      "jti": UUID().uuidString.lowercased(), "cnf": ["kid": kid],
      "conversationId": String(space.skey[..<dash]), "generation": generation, "groupId": hex(group),
      "reason": "notActiveMember",
    ]
    let denial = SpaceToken.mint(typ: SpaceToken.denial, key: signingKey(space.authority), claims: claims)
    var refusal: JSON = ["error": "NotAuthorized", "message": "requester is not an active member of this conversation Space"]
    switch spaceDenialForgery {
    case nil:
      refusal["denial"] = denial
    case .unsigned:
      break
    case .tampered:
      var parts = denial.split(separator: ".").map(String.init)
      claims["jti"] = "\(claims["jti"]!)-altered"
      parts[1] = JWTBase64URL.encode(try JSONSerialization.data(withJSONObject: claims, options: [.withoutEscapingSlashes]))
      refusal["denial"] = parts.joined(separator: ".")
    }
    return reply(403, refusal)
  }

  private func applyWrites(account: String, body: JSON) throws -> Reply {
    let space = try SpaceURI(try text(body, "space"))
    let repo = try text(body, "repo")
    guard repo == account else { return xrpcError(403, "NotAuthorized") }
    guard let writes = body["writes"] as? [JSON] else { throw Fault(message: "writes missing") }
    if let denied = overridden(space.raw) { return denied }
    var working = records
    let rev = tid(next())
    var results: [JSON] = []
    var operations: [SpaceOperation] = []
    for (index, write) in writes.enumerated() {
      let collection = try text(write, "collection")
      let rkey = (write["rkey"] as? String) ?? tid(sequence + UInt64(index) + 1)
      let key = RecordKey(space: space.raw, repo: repo, collection: collection, rkey: rkey)
      let current = working[key]
      if write.keys.contains("swapRecord"), (write["swapRecord"] as? String) != current?.cid.string {
        return xrpcError(400, "InvalidSwap")
      }
      let action = try text(write, "$type").split(separator: "#").last.map(String.init) ?? ""
      var cid: CID?
      switch action {
      case "create" where current != nil:
        return xrpcError(400, "RecordAlreadyExists")
      case "update" where current == nil, "delete" where current == nil:
        return xrpcError(400, "RecordNotFound")
      case "create", "update":
        guard let value = write["value"] else { throw Fault(message: "write value missing") }
        let stored = StoredRecord(value: value, cid: try dagCborCID(value))
        working[key] = stored
        cid = stored.cid
      case "delete":
        working[key] = nil
      default:
        throw Fault(message: "unsupported Space write action")
      }
      var result: JSON = ["$type": "com.atproto.space.applyWrites#\(action)Result"]
      if let cid {
        result["uri"] = space.recordURI(repo, collection, rkey)
        result["cid"] = cid.string
      }
      results.append(result)
      operations.append(SpaceOperation(
        collection: collection,
        rkey: rkey,
        rev: rev,
        cid: cid?.string,
        previousCID: current?.cid.string
      ))
    }
    records = working
    let repoKey = "\(space.raw)|\(repo)"
    repoRevisions[repoKey] = rev
    repoOperations[repoKey, default: []].append(contentsOf: operations)
    return reply(200, ["results": results])
  }

  private func spaceRead(
    account: String, nsid: String, params: [String: String], authorization: String, audience: String,
    signatureInput: String, signature: String, acceptSignature: String?, now: UInt64
  ) throws -> Reply {
    let space = try SpaceURI(try required(params, "space"))
    let writer = ["com.atproto.space.getSpace", "com.atproto.space.listWriters", "com.atproto.space.listRepos"].contains(nsid)
      ? space.authority
      : try required(params, "repo")
    guard audience == writer else { throw Fault(message: "Space audience mismatch") }
    let scheme = "Atproto-Space-Credential "
    guard authorization.hasPrefix(scheme) else { throw Fault(message: "Space credential missing") }
    let jwt = String(authorization.dropFirst(scheme.count))
    guard let claims = SpaceToken.verify(jwt, typ: SpaceToken.credential, issuerKey: { self.signingKey($0).publicKey }),
          claims["iss"] as? String == space.authority, claims["sub"] as? String == space.raw,
          let exp = uint64(claims["exp"]), exp > now,
          let cnf = (claims["cnf"] as? JSON)?["kid"] as? String
    else { throw Fault(message: "Space credential binding mismatch") }
    try verifyPresentation(authorization: authorization, audience: audience, signatureInput: signatureInput, signature: signature, cnf: cnf)
    if space.spaceType == "blue.catbird.labyrinth.mailbox", space.authority != account || writer != account || space.skey != "self" {
      return xrpcError(403, "NotAuthorized")
    }
    if let denied = overridden(space.raw) { return denied }
    let written = records
      .filter { $0.key.space == space.raw && $0.key.repo == writer }
      .sorted { "\($0.key.collection)/\($0.key.rkey)".utf8.lexicographicallyPrecedes("\($1.key.collection)/\($1.key.rkey)".utf8) }
    switch nsid {
    case "com.atproto.space.getRecord":
      let collection = try required(params, "collection")
      let rkey = try required(params, "rkey")
      guard let record = records[RecordKey(space: space.raw, repo: writer, collection: collection, rkey: rkey)] else {
        return xrpcError(404, "RecordNotFound")
      }
      let uri = space.recordURI(writer, collection, rkey)
      let (label, share, secret) = try sharedSecret(writer, acceptSignature, profile: "atproto-space-record")
      var out = reply(200, ["uri": uri, "cid": record.cid.string, "value": record.value])
      attachRecordMac(&out, secret: secret, keyShare: share, label: label, uri: uri, cid: record.cid.string)
      return out
    case "com.atproto.space.listRecords":
      let collection = params["collection"]
      let reverse = params["reverse"] == "true"
      var matching = written.filter { entry in
        let path = "\(entry.key.collection)/\(entry.key.rkey)"
        return (collection == nil || entry.key.collection == collection)
          && (params["cursor"].map { reverse ? path < $0 : path > $0 } ?? true)
      }
      if reverse { matching.reverse() }
      let limit = try pageLimit(params, default: 50)
      let more = matching.count > limit
      matching = Array(matching.prefix(limit))
      let listed: [JSON] = matching.map { entry in
        var item: JSON = ["collection": entry.key.collection, "rkey": entry.key.rkey, "cid": entry.value.cid.string]
        if params["excludeValues"] != "true" { item["value"] = entry.value.value }
        return item
      }
      var out: JSON = ["records": listed]
      if more, let last = matching.last { out["cursor"] = "\(last.key.collection)/\(last.key.rkey)" }
      return reply(200, out)
    case "com.atproto.space.listWriters", "com.atproto.space.listRepos":
      guard params.keys.allSatisfy({ ["space", "cursor", "limit"].contains($0) }) else {
        return xrpcError(400, "InvalidRequest", "unknown inventory parameter")
      }
      let dids = Set(records.keys.filter { $0.space == space.raw }.map(\.repo)).sorted()
      let rows = dids.map { did -> (did: String, repoRev: String, spaceRev: String, data: Data) in
        let rev = repoRevisions["\(space.raw)|\(did)"] ?? tid(0)
        let data = commitment(records.filter { $0.key.space == space.raw && $0.key.repo == did })
        return (did, rev, rev, data)
      }
      let data = try inventoryCommitment(rows)
      let rev = rows.map(\.spaceRev).max() ?? tid(0)
      let commitmentHex = hex(data)
      var offset = 0
      if let cursor = params["cursor"] {
        let parts = cursor.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3, let parsedOffset = Int(parts[2]), parsedOffset >= 0 {
          guard parts[0] == rev, parts[1] == commitmentHex else {
            return xrpcError(409, "SnapshotChanged", "writer inventory changed during pagination")
          }
          offset = parsedOffset
        } else if let parsedOffset = Int(cursor), parsedOffset >= 0 {
          offset = parsedOffset
        } else {
          return xrpcError(400, "InvalidRequest", "invalid inventory cursor")
        }
      }
      guard offset < rows.count || (offset == 0 && rows.isEmpty) else {
        return xrpcError(400, "InvalidRequest", "inventory cursor is past the terminal page")
      }
      let limit = try pageLimit(params, default: 100)
      let end = min(offset + limit, rows.count)
      let complete = end == rows.count
      let page = rows[offset ..< end]
      let (label, share, secret) = try sharedSecret(space.authority, acceptSignature, profile: "atproto-space-commit")
      var body: JSON = [
        "repos": page.map { [
          "$type": "com.atproto.space.defs#repoWrite",
          "repo": $0.did,
          "repoRev": $0.repoRev,
          "spaceRev": $0.spaceRev,
          "data": ["$bytes": $0.data.base64EncodedString()],
        ] },
        "complete": complete,
        "commit": [
          "space": space.raw, "repo": space.authority, "rev": rev, "ver": 1,
          "data": ["$bytes": data.base64EncodedString()],
        ],
      ]
      if !complete {
        body["cursor"] = "\(rev).\(commitmentHex).\(end)"
      }
      var out = reply(200, body)
      attachCommitMac(&out, secret: secret, keyShare: share, label: label, space: space.raw, repo: space.authority, rev: rev, data: data)
      return out
    case "com.atproto.space.getLatestCommit", "com.atproto.space.getRepo", "com.atproto.space.listRepoOps":
      let rev = repoRevisions["\(space.raw)|\(writer)"] ?? tid(0)
      let data = commitment(written)
      let (label, share, secret) = try sharedSecret(writer, acceptSignature, profile: "atproto-space-commit")
      let commit: JSON = [
        "space": space.raw, "repo": writer, "rev": rev, "ver": 1,
        "data": ["$bytes": data.base64EncodedString()],
      ]
      if nsid == "com.atproto.space.getLatestCommit" {
        var out = reply(200, ["commit": commit])
        attachCommitMac(&out, secret: secret, keyShare: share, label: label, space: space.raw, repo: writer, rev: rev, data: data)
        return out
      }
      if nsid == "com.atproto.space.getRepo" {
        var out = Reply(
          status: 200,
          headers: ["Content-Type": "application/vnd.dasl.star"],
          body: try starArchive(space: space.raw, writer: writer, rev: rev, data: data, records: written)
        )
        attachCommitMac(&out, secret: secret, keyShare: share, label: label, space: space.raw, repo: writer, rev: rev, data: data)
        return out
      }

      var operations = repoOperations["\(space.raw)|\(writer)"] ?? []
      if let since = params["since"] {
        operations.removeAll { $0.rev <= since }
      }
      let start: Int
      if let cursor = params["cursor"] {
        guard let parsed = Int(cursor), parsed >= 0 else {
          return xrpcError(400, "InvalidRequest", "invalid oplog cursor")
        }
        start = parsed
      } else {
        start = 0
      }
      guard start <= operations.count else {
        return xrpcError(400, "InvalidRequest", "oplog cursor is past the terminal page")
      }
      let limit = try pageLimit(params, default: 100)
      let end = min(start + limit, operations.count)
      let excludeValues = params["excludeValues"] == "true"
      let selected: [JSON] = operations[start ..< end].map { operation in
        var op: JSON = [
          "collection": operation.collection,
          "rkey": operation.rkey,
          "rev": operation.rev,
          "cid": operation.cid ?? NSNull(),
          "prev": operation.previousCID ?? NSNull(),
        ]
        if !excludeValues, let cid = operation.cid {
          let key = RecordKey(
            space: space.raw, repo: writer, collection: operation.collection, rkey: operation.rkey
          )
          if let current = records[key], current.cid.string == cid {
            op["value"] = current.value
          }
        }
        return op
      }
      if end < operations.count {
        return reply(200, ["ops": selected, "cursor": String(end)])
      }
      var out = reply(200, ["ops": selected, "commit": commit])
      attachCommitMac(&out, secret: secret, keyShare: share, label: label, space: space.raw, repo: writer, rev: rev, data: data)
      return out
    case "com.atproto.space.getBlob":
      let cid = try required(params, "cid")
      guard let bytes = blobs["\(writer)|\(cid)"] else {
        return xrpcError(404, "BlobNotFound")
      }
      return Reply(status: 200, headers: ["Content-Type": "application/octet-stream"], body: bytes)
    case "com.atproto.space.getSpace":
      return reply(200, ["uri": space.raw, "policy": [
        "$type": "blue.catbird.labyrinth.conversationPolicy", "authority": space.authority,
      ]])
    default:
      throw Fault(message: "unsupported Space read")
    }
  }

  /// RFC 9421 `atproto-space-credential` minimal profile, verified with the credential `cnf` key.
  private func verifyPresentation(authorization: String, audience: String, signatureInput: String, signature: String, cnf: String) throws {
    let params = "(\"authorization\" \"atproto-space-audience\");tag=\"\(Self.credentialLabel)\""
    guard signatureInput == "\(Self.credentialLabel)=\(params)",
          signature.hasPrefix("\(Self.credentialLabel)=:"), signature.hasSuffix(":"),
          let raw = Data(base64Encoded: String(signature.dropFirst(Self.credentialLabel.count + 2).dropLast())),
          let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: raw)
    else { throw Fault(message: "malformed RFC 9421 presentation") }
    let base = "\"authorization\": \(authorization)\n\"atproto-space-audience\": \(audience)\n\"@signature-params\": \(params)"
    guard try P256DIDKey(cnf).publicKey.isValidSignature(ecdsa, for: Data(base.utf8)) else {
      throw Fault(message: "Space proof binding mismatch")
    }
  }

  /// Parse Nov-12 RFC 9421 `Accept-Signature: <label>=("<profile>";sf);keyid="<did:key:...>";tag="<profile>"`.
  private func sharedSecret(_ writer: String, _ acceptSignature: String?, profile: String) throws -> (label: String, keyShare: String, secret: Data) {
    guard let acceptSignature, !acceptSignature.isEmpty else {
      throw Fault(message: "Accept-Signature missing")
    }
    for member in acceptSignature.split(separator: ",") {
      let trimmed = member.trimmingCharacters(in: .whitespaces)
      guard let eq = trimmed.firstIndex(of: "=") else { continue }
      let label = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
      let rest = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
      guard let closeParen = rest.firstIndex(of: ")"), rest.hasPrefix("(") else { continue }
      let inner = String(rest[rest.index(after: rest.startIndex) ..< closeParen]).trimmingCharacters(in: .whitespaces)
      guard inner == "\"\(profile)\";sf" else { continue }
      let paramString = String(rest[rest.index(after: closeParen)...])
      var keyShare: String?
      var tag: String?
      for part in paramString.split(separator: ";") {
        let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2 else { continue }
        let k = kv[0].trimmingCharacters(in: .whitespaces)
        let v = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        if k == "keyid" { keyShare = v }
        if k == "tag" { tag = v }
      }
      if tag == profile, let share = keyShare, !share.isEmpty {
        let secret = try SpaceMAC.decapsulate(privateKey: kemKey(writer), keyShare: share)
        return (label, share, secret)
      }
    }
    throw Fault(message: "Accept-Signature profile \(profile) mismatch: \(acceptSignature)")
  }

  private func sfEscape(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
  }

  private func attachRecordMac(
    _ reply: inout Reply, secret: Data, keyShare: String, label: String, uri: String, cid: String
  ) {
    let profile = "atproto-space-record"
    let covered = "uri=\(sfEscape(uri)), cid=\(sfEscape(cid))"
    attachMacHeaders(&reply, profile: profile, headerName: "Atproto-Space-Record", covered: covered, secret: secret, keyShare: keyShare, label: label)
  }

  private func attachCommitMac(
    _ reply: inout Reply, secret: Data, keyShare: String, label: String, space: String, repo: String, rev: String, data: Data
  ) {
    let profile = "atproto-space-commit"
    let covered = "ver=1, repo=\(sfEscape(repo)), space=\(sfEscape(space)), rev=\(sfEscape(rev)), data=:\(data.base64EncodedString()):"
    attachMacHeaders(&reply, profile: profile, headerName: "Atproto-Space-Commit", covered: covered, secret: secret, keyShare: keyShare, label: label)
  }

  private func attachMacHeaders(
    _ reply: inout Reply, profile: String, headerName: String, covered: String, secret: Data, keyShare: String, label: String
  ) {
    let sigParams = "(\(sfEscape(profile));sf);keyid=\(sfEscape(keyShare));tag=\(sfEscape(profile))"
    let base = Data("\"\(profile)\";sf: \(covered)\n\"@signature-params\": \(sigParams)".utf8)
    let mac = Data(HMAC<SHA256>.authenticationCode(for: base, using: SymmetricKey(data: secret)))
    reply.headers[headerName] = covered
    reply.headers["Signature-Input"] = "\(label)=\(sigParams)"
    reply.headers["Signature"] = "\(label)=:\(mac.base64EncodedString()):"
    reply.headers["Vary"] = "accept-signature"
  }

  /// Produce one canonical, signed repository head for the whole current record set. Record reads,
  /// full exports and head queries share it until a record changes.
  private func repositorySnapshot(did: String) throws -> RepositorySnapshot {
    typealias Leaf = (path: Data, cid: CID, depth: Int)
    var blocks: [CID: Data] = [:]
    var leaves: [Leaf] = []
    func add(_ path: String, _ value: Any) throws {
      let encoded = try DAGCBOR.encodeValue(try dataModel(value))
      let cid = CID.fromDAGCBOR(encoded)
      let key = Data(path.utf8)
      var zeros = 0
      for byte in SHA256.hash(data: key) {
        zeros += byte.leadingZeroBitCount
        if byte != 0 { break }
      }
      leaves.append((key, cid, zeros / 2))
      blocks[cid] = encoded
    }
    for (key, record) in pdsRecords where key.hasPrefix(did + "|") {
      let path = key.dropFirst(did.count + 1).replacingOccurrences(of: "|", with: "/")
      try add(path, record.value)
    }
    for (rkey, record) in mailboxKeys[did] ?? [:] {
      try add("\(Self.mailboxKeysCollection)/\(rkey)", record.value)
    }
    leaves.sort { $0.path.lexicographicallyPrecedes($1.path) }

    func tree(_ records: ArraySlice<Leaf>, depth: Int) throws -> CID {
      var entries: [JSON] = []
      var left: Any = NSNull()
      func subtree(_ range: ArraySlice<Leaf>) throws -> Any {
        guard !range.isEmpty else { return NSNull() }
        return CIDAsLink(cid: try tree(range, depth: depth - 1), representation: .link)
      }
      var start = records.startIndex
      var prior = Data()
      for position in records.indices where records[position].depth == depth {
        let lower = try subtree(records[start..<position])
        if entries.isEmpty { left = lower } else { entries[entries.count - 1]["t"] = lower }
        let record = records[position]
        let prefix = zip(prior, record.path).prefix(while: { $0.0 == $0.1 }).count
        entries.append(["p": Int64(prefix), "k": Data(record.path.dropFirst(prefix)), "t": NSNull(),
                        "v": CIDAsLink(cid: record.cid, representation: .link)])
        prior = record.path
        start = position + 1
      }
      let tail = try subtree(records[start..<records.endIndex])
      if entries.isEmpty { left = tail } else { entries[entries.count - 1]["t"] = tail }
      let raw = try DAGCBOR.encodeValue(["l": left, "e": entries] as JSON)
      let cid = CID.fromDAGCBOR(raw)
      blocks[cid] = raw
      return cid
    }
    let root = try tree(leaves[...], depth: leaves.map(\.depth).max() ?? 0)
    if let prior = signedRepositories[did], prior.root == root { return prior }
    let revision = tid(next())
    var commit: JSON = ["did": did, "version": Int64(3), "rev": revision, "prev": NSNull(),
                        "data": CIDAsLink(cid: root, representation: .link)]
    commit["sig"] = try P256WireSignature.sign(try DAGCBOR.encodeValue(commit), using: signingKey(did))
    let raw = try DAGCBOR.encodeValue(commit)
    let cid = CID.fromDAGCBOR(raw)
    let header: JSON = ["version": Int64(1), "roots": [CIDAsLink(cid: cid, representation: .link)]]
    var car = starFrame(try DAGCBOR.encodeValue(header))
    car.append(starFrame(cid.bytes + raw))
    for (cid, block) in blocks.sorted(by: { $0.key.string < $1.key.string }) {
      car.append(starFrame(cid.bytes + block))
    }
    let snapshot = RepositorySnapshot(root: root, revision: revision, commit: cid, car: car)
    signedRepositories[did] = snapshot
    return snapshot
  }

  private func inventoryCommitment(
    _ rows: [(did: String, repoRev: String, spaceRev: String, data: Data)]
  ) throws -> Data {
    var state = [UInt8](repeating: 0, count: 2048)
    for row in rows {
      guard row.data.count == 32 else { throw Fault(message: "inventory row commitment malformed") }
      var input = Data("atproto-space-writer-inventory-v1".utf8)
      for field in [row.did, row.repoRev, row.spaceRev] {
        let bytes = Data(field.utf8)
        guard bytes.count <= Int(UInt16.max) else { throw Fault(message: "inventory field too long") }
        input.appendBigEndian(UInt16(bytes.count))
        input.append(bytes)
      }
      input.append(row.data)
      var hasher = petrel_blake3_hasher()
      petrel_blake3_hasher_init(&hasher)
      input.withUnsafeBytes { petrel_blake3_hasher_update(&hasher, $0.baseAddress, $0.count) }
      var element = [UInt8](repeating: 0, count: state.count)
      element.withUnsafeMutableBufferPointer {
        petrel_blake3_hasher_finalize(&hasher, $0.baseAddress, $0.count)
      }
      for offset in stride(from: 0, to: state.count, by: 2) {
        let lhs = UInt16(state[offset]) | UInt16(state[offset + 1]) << 8
        let rhs = UInt16(element[offset]) | UInt16(element[offset + 1]) << 8
        let sum = lhs &+ rhs
        state[offset] = UInt8(truncatingIfNeeded: sum)
        state[offset + 1] = UInt8(truncatingIfNeeded: sum >> 8)
      }
    }
    return Data(SHA256.hash(data: Data(state)))
  }

  private func starArchive(
    space: String, writer: String, rev: String, data: Data,
    records: [(key: RecordKey, value: StoredRecord)]
  ) throws -> Data {
    var archive = Data([0x2A, 0x6C, 1, 0])
    let metadata: JSON = [
      "$type": "atproto-space-repo", "ver": 1, "repo": writer,
      "space": space, "rev": rev, "data": ["$bytes": data.base64EncodedString()],
    ]
    archive.append(starFrame(try DAGCBOR.encodeValue(try dataModel(metadata))))
    for record in records {
      archive.append(0x01)
      archive.append(starFrame(Data("\(record.key.collection)/\(record.key.rkey)".utf8)))
      archive.append(starFrame(try DAGCBOR.encodeValue(try dataModel(record.value.value))))
    }
    archive.append(0x00)
    return archive
  }

  private func starFrame(_ bytes: Data) -> Data {
    var length = UInt64(bytes.count)
    var frame = Data()
    repeat {
      var byte = UInt8(length & 0x7F)
      length >>= 7
      if length != 0 { byte |= 0x80 }
      frame.append(byte)
    } while length != 0
    frame.append(bytes)
    return frame
  }
  private func commitment<S: Sequence>(_ entries: S) -> Data where S.Element == (key: RecordKey, value: StoredRecord) {
    var hash = SpaceSetHash()
    for entry in entries {
      hash.add(path: "\(entry.key.collection)/\(entry.key.rkey)", cid: entry.value.cid.string)
    }
    return hash.digest
  }

  private func overridden(_ space: String) -> Reply? {
    guard let status = statusOverrides[space] else { return nil }
    overrideRejections[space, default: 0] += 1
    return xrpcError(status, status == 403 ? "Forbidden" : "SpaceUnavailable", space)
  }

  // MARK: - Home mls-ds (client_live_chat_data_plane.rs mock DS)

  private func handleDS(nsid: String, method: String, rawQuery: String, request: URLRequest, body: Data) throws -> Reply {
    let q = lenientQuery(rawQuery)
    let b = method == "POST" ? ((try? object(body)) ?? JSON()) : JSON()
    let signed = (b["signedRequest"] as? JSON)?["body"] as? JSON ?? JSON()
    switch nsid {
    case "blue.catbird.labyrinth.getMailboxKeysRecord":
      let did = try required(q, "did")
      let rkey = try required(q, "rkey")
      guard let record = mailboxKeys[did]?[rkey] else {
        return xrpcError(404, "RecordNotFound")
      }
      return reply(200, [
        "uri": "at://\(did)/\(Self.mailboxKeysCollection)/\(rkey)",
        "cid": record.cid.string,
        "value": record.value,
      ])
    case "blue.catbird.chat.relaySpaceCredential":
      return try spaceCredential(account: try principal(b["actorDeviceId"]), body: b, relayed: true, now: nowSeconds())
    case "blue.catbird.chat.relaySpaceRead":
      let audience = try text(b, "spaceAudience")
      guard try text(b, "targetDid") == audience else { throw Fault(message: "relay target/audience mismatch") }
      return try spaceRead(
        account: try principal(b["actorDeviceId"]), nsid: try text(b, "nsid"),
        params: try strictQuery(b["query"] as? String ?? ""),
        authorization: "Atproto-Space-Credential \(try text(b, "credential"))", audience: audience,
        signatureInput: try text(b, "signatureInput"), signature: try text(b, "signature"),
        acceptSignature: (b["acceptSignature"] as? String) ?? (b["wantMac"] as? String), now: nowSeconds()
      )
    case "blue.catbird.labyrinth.publishEpochHead":
      let (write, account, key) = try deviceSignedClaim(request, header: "catbird-labyrinth-write", deviceField: "actorDeviceId", domain: "CATBIRD-LABYRINTH-WRITE\0")
      guard write["endpointNsid"] as? String == nsid, write["payloadSha256"] as? String == hex(Data(SHA256.hash(data: body))) else {
        return xrpcError(400, "InvalidRequest", "write body does not bind this payload")
      }
      guard let epoch = b["epoch"] as? JSON, let number = uint64(epoch["epochNumber"]) else {
        return xrpcError(400, "InvalidRequest", "epoch head does not verify")
      }
      guard bytes((epoch["attestation"] as? JSON)?["transportPubkey"]) == key else {
        return xrpcError(400, "AttestationNotCaller", "head not attested by caller")
      }
      var chain = epochHeads[account] ?? []
      if let existing = chain.first(where: { uint64($0["epochNumber"]) == number }) {
        return NSDictionary(dictionary: existing).isEqual(to: epoch)
          ? reply(200, JSON()) : xrpcError(409, "EpochHeadConflict", "different head at this epoch")
      }
      let links = chain.last.map { latest in
        uint64(latest["epochNumber"]).map { $0 + 1 } == number
          && bytes(epoch["previousEpochHead"]) == bytes(latest["epochHead"])
      } ?? (number == 0)
      guard links else { return xrpcError(400, "InvalidEpochChain", "head does not extend the chain") }
      chain.append(epoch)
      epochHeads[account] = chain
      return reply(200, JSON())
    case "blue.catbird.labyrinth.getEpochHead":
      try verifyRead(request, nsid: nsid, rawQuery: rawQuery)
      let chain = epochHeads[q["did"] ?? ""] ?? []
      let end: Int?
      if let wanted = q["epochNumber"] {
        end = chain.firstIndex { uint64($0["epochNumber"]).map { String($0) } == wanted }
      } else {
        end = chain.isEmpty ? nil : chain.count - 1
      }
      guard let end else { return xrpcError(404, "EpochNotFound", "no such epoch head") }
      return reply(200, ["epoch": chain[end], "chain": Array(chain[...end]), "floorSeq": chain[0]["epochNumber"]!])
    case "blue.catbird.labyrinth.getChatDeviceKeys":
      try verifyRead(request, nsid: nsid, rawQuery: rawQuery)
      let keys = (deviceKeys[q["did"] ?? ""] ?? [:]).sorted { $0.key < $1.key }.map(\.value)
      return reply(200, ["items": keys.map { key -> JSON in
        ["keyId": JWTBase64URL.encode(Data(SHA256.hash(data: key))), "signingPublicKey": ["$bytes": key.base64EncodedString()]]
      }])
    case "blue.catbird.labyrinth.getMemberDevices":
      // `mls-ds` `member_devices`: `did`'s leaf periods with the chat seqs that added and removed
      // them; only a past or present participant may read the conversation's leaf view.
      let caller = try verifyRead(request, nsid: nsid, rawQuery: rawQuery)
      let periods = leafPeriods[q["threadId"] ?? ""] ?? []
      guard periods.contains(where: { $0["userDid"] as? String == caller }) else {
        return xrpcError(404, "ConversationNotFound")
      }
      let did = q["did"] ?? ""
      return reply(200, ["items": periods.filter { $0["userDid"] as? String == did }.compactMap { period -> JSON? in
        guard let key = deviceKeys[did]?[period["deviceId"] as? String ?? ""] else { return nil }
        var item: JSON = [
          "keyId": JWTBase64URL.encode(Data(SHA256.hash(data: key))),
          "signingPublicKey": ["$bytes": key.base64EncodedString()], "joinedSeq": period["joinedSeq"] ?? 0,
        ]
        item["removedSeq"] = period["removedSeq"]
        return item
      }])
    case "blue.catbird.chat.enrollDevice":
      let did = try text(signed, "actorDid")
      let device = try text(signed, "deviceId")
      // `mls-ds` enrollment is create-only per (did, deviceId).
      if deviceKeys[did]?[device] != nil {
        return xrpcError(400, "DeviceAlreadyExists", "DeviceAlreadyExists")
      }
      guard let key = bytes(signed["signaturePublicKey"]), key.count == 32 else { throw Fault(message: "enrollment key malformed") }
      let keyId = try text(signed, "keyId")
      guard keyId == JWTBase64URL.encode(Data(SHA256.hash(data: key))) else {
        throw Fault(message: "enrollment keyId does not name its signaturePublicKey")
      }
      let packages = signed["keyPackages"] as? [JSON] ?? []
      let enrolledAt = try text(signed, "signedAt")
      deviceKeys[did, default: [:]][device] = key
      conversationKeyPackages["\(did)|\(device)", default: []].append(contentsOf: packages)
      // `mls-ds` `enroll_device` answers `{device: deviceView}` (`blue.catbird.chat.defs#deviceView`):
      // this device under this key at generation 1, which the client binds before any PDS write.
      return reply(200, ["device": [
        "deviceId": device,
        "keyId": keyId,
        "signaturePublicKey": ["$bytes": key.base64EncodedString()],
        "authGeneration": 1,
        "status": "active",
        "createdAt": enrolledAt,
        "updatedAt": enrolledAt,
        "availablePackageCount": packages.count,
        "reservedPackageCount": 0,
      ] as JSON])
    case "blue.catbird.chat.replenishKeyPackages":
      let slot = "\(try text(signed, "actorDid"))|\(try text(signed, "actorDeviceId"))"
      conversationKeyPackages[slot, default: []].append(contentsOf: signed["keyPackages"] as? [JSON] ?? [])
      return reply(200, ["acceptedCount": 4])
    case "blue.catbird.chat.publishDirectRequestKeys":
      // `mls-ds` `publish_request_keys`: each publication advances the revision by one.
      let slot = "\(try text(signed, "actorDid"))|\(try text(signed, "actorDeviceId"))"
      guard let revision = int64(signed["revision"]), revision == (directRequestRevisions[slot] ?? 0) + 1 else {
        return xrpcError(400, "InvalidRequest", "request-key revision must advance by one")
      }
      directRequestRevisions[slot] = revision
      return reply(200, ["published": true])
    case "blue.catbird.chat.createConversation":
      return try createConversation(b)
    case "blue.catbird.chat.acceptConversation":
      return try acceptConversation(b)
    case "blue.catbird.chat.submitTransition":
      return try submitTransition(b)
    case "blue.catbird.chat.sendMessage":
      return try sendMessage(b)
    case "blue.catbird.chat.getConversations":
      return reply(200, ["conversations": conversations.sorted { $0.key < $1.key }.map(\.value)])
    case "blue.catbird.chat.getPendingWelcomes":
      let device = q["actorDeviceId"] ?? ""
      var found: [JSON] = []
      for slot in Array(pendingWelcomes.keys) where slot.hasSuffix("|\(device)") {
        found += pendingWelcomes[slot] ?? []
        pendingWelcomes[slot] = []
      }
      return reply(200, ["welcomes": found])
    case "blue.catbird.chat.acknowledgeWelcome":
      return reply(200, ["acknowledged": true])
    case "blue.catbird.chat.getConversationState":
      let cid = q["conversationId"] ?? ""
      let device = q["actorDeviceId"] ?? ""
      guard let state = conversations[cid] else { return xrpcError(400, "ConversationNotFound", cid) }
      let currentLeaf = (state["leaves"] as? [JSON] ?? []).contains { $0["deviceId"] as? String == device }
      let conversationSpacePrefix =
        "at:space/\(Self.dsDid)/blue.catbird.labyrinth.conversation/\(cid)-"
      if !currentLeaf, statusOverrides.contains(where: {
        $0.value == 403 && $0.key.hasPrefix(conversationSpacePrefix)
      }) {
        // The fixture's Space override is global, so its DS projection must not
        // claim that a fresh, non-member device can read that conversation.
        return xrpcError(400, "ConversationNotFound", cid)
      }
      // Every coordinate change supersedes the open requests: exactly the open ones are pending,
      // served as the DS holds them.
      let requests = (leafRecoveries[cid] ?? []).filter { request in
        currentLeaf && request["requesterDeviceId"] as? String != device && request["status"] as? String == "open"
      }
      // `accountDeletions` is required by the lexicon (PetrelCatbird 0f4f58a2);
      // this mock models no account deletions, so the list is empty.
      return reply(200, [
        "state": state, "pendingLeafRecoveryRequests": requests,
        "pendingResetRequests": [Any](), "pendingLeaveRequests": [Any](),
        "accountDeletions": [Any](),
      ])
    case "blue.catbird.chat.getLeafRecoveryInbox":
      let device = q["actorDeviceId"] ?? ""
      let items = leafRecoveries.values.flatMap { $0 }.filter { $0["requesterDeviceId"] as? String == device }
      var out: JSON = [
        "items": items, "snapshotEventCursor": "fixture-events",
        "snapshotExpiresAt": "2099-01-01T00:00:00.000Z", "hasMore": false,
      ]
      out["inventorySessionId"] = q["inventorySessionId"]
      return reply(200, out)
    case "blue.catbird.chat.getEntries":
      let after = Int64(q["afterSeq"] ?? "0") ?? 0
      let list = (entries[q["conversationId"] ?? ""] ?? []).filter { int64($0["seq"]) ?? 0 > after }.map(served)
      return reply(200, ["entries": list])
    case "blue.catbird.chat.acknowledgeEntries":
      let wm = int64(b["upToSeq"]) ?? 0
      return reply(200, ["watermarkSeq": wm])
    default:
      return reply(200, JSON())
    }
  }

  private func createConversation(_ b: JSON) throws -> Reply {
    guard let sr = b["signedRequest"] as? JSON, let body = sr["body"] as? JSON, let manifest = body["manifest"] as? JSON else {
      throw Fault(message: "createConversation body malformed")
    }
    let cid = try text(body, "conversationId")
    let coords = body["next"] ?? NSNull()
    if let existingState = conversations[cid],
      let existingEntry = entries[cid]?.first,
      let existingSr = existingEntry["signedRequest"] as? JSON,
      (existingSr["operationId"] as? String) == (sr["operationId"] as? String)
    {
      return reply(200, ["result": [
        "$type": "blue.catbird.chat.defs#conversationCreatedResult",
        "coordinates": existingState["coordinates"] ?? coords,
        "entry": existingEntry,
      ] as JSON])
    }
    let actorLeaf = manifest["actorLeaf"] as? JSON ?? JSON()
    let participants = (manifest["participants"] as? [JSON] ?? []).map { participant -> JSON in
      var p = participant
      p["leafCount"] = participant["userDid"] as? String == actorLeaf["userDid"] as? String ? 1 : 0
      return p
    }
    let entry = try controlEntry(
      type: "creationEntry",
      signedRequest: sr,
      coordinate: coords as? JSON ?? JSON(),
      seq: 1
    )
    conversations[cid] = [
      "conversationKind": "group", "sequencerDid": Self.dsDid, "coordinates": coords,
      "participants": participants, "leaves": [actorLeaf],
      "metadataSnapshot": body["metadataSnapshot"] ?? NSNull(), "snapshotSeq": 1,
    ]
    entries[cid, default: []].append(entry)
    leafPeriods[cid] = [["userDid": actorLeaf["userDid"] ?? NSNull(), "deviceId": actorLeaf["deviceId"] ?? NSNull(), "joinedSeq": 1]]
    // `mls-ds` answers the sequenced creation entry carrying the exact signed request.
    return reply(200, ["result": [
      "$type": "blue.catbird.chat.defs#conversationCreatedResult", "coordinates": coords,
      "entry": entry,
    ] as JSON])
  }

  /// Group participant acceptance: an inviter-visible leaf-recovery request for the invitee's device.
  private func acceptConversation(_ b: JSON) throws -> Reply {
    guard let sr = b["signedRequest"] as? JSON, let body = sr["body"] as? JSON, let next = body["next"] as? JSON else {
      throw Fault(message: "acceptConversation body malformed")
    }
    let cid = try text(next, "conversationId")
    let invitee = try text(body, "actorDid")
    let inviteeDevice = try text(body, "actorDeviceId")
    let recoveryRequestId = try text(body, "recoveryRequestId")
    guard let keyPackage = conversationKeyPackages["\(invitee)|\(inviteeDevice)"]?.popLast(),
          var state = conversations[cid]
    else { throw Fault(message: "invitee must have a conversation KeyPackage") }
    state["coordinates"] = next
    state["participants"] = (state["participants"] as? [JSON] ?? []).map { participant -> JSON in
      var p = participant
      if p["userDid"] as? String == invitee { p["status"] = "active" }
      return p
    }
    let seq = (entries[cid]?.count ?? 0) + 1
    let entry = try controlEntry(
      type: "participantAcceptanceEntry",
      signedRequest: sr,
      coordinate: next,
      seq: seq
    )
    entries[cid, default: []].append(entry)
    state["snapshotSeq"] = seq
    conversations[cid] = state
    let signedAt = ISO8601DateFormatter.fractional.date(from: try text(body, "signedAt")) ?? Date()
    let expiresAt = ISO8601DateFormatter.fractional.string(from: signedAt.addingTimeInterval(300))
    var requests = (leafRecoveries[cid] ?? []).map { request -> JSON in
      guard request["status"] as? String == "open" else { return request }
      var superseded = request
      superseded["status"] = "superseded"
      var reservation = request["reservation"] as? JSON ?? JSON()
      reservation["status"] = "released"
      superseded["reservation"] = reservation
      return superseded
    }
    let view: JSON = [
      "$type": "blue.catbird.chat.defs#leafRecoveryView", "conversationId": cid,
      "recoveryRequestId": recoveryRequestId, "requesterDid": invitee, "requesterDeviceId": inviteeDevice,
      "recoveryKind": "add", "boundCoordinate": next, "status": "open",
      "requestedAt": body["signedAt"] ?? NSNull(), "expiresAt": expiresAt,
      "reservation": [
        "conversationId": cid, "recoveryRequestId": recoveryRequestId, "boundCoordinate": next,
        "requesterDid": invitee, "requesterDeviceId": inviteeDevice,
        "requesterKeyId": body["keyId"] ?? NSNull(), "requesterAuthGeneration": body["authGeneration"] ?? NSNull(),
        "keyPackageRef": keyPackage["keyPackageRef"] ?? NSNull(),
        "cipherSuite": "MLS_256_XWING_CHACHA20POLY1305_SHA256_Ed25519",
        "purpose": "leafRecovery", "status": "active", "expiresAt": expiresAt, "keyPackage": keyPackage,
      ] as JSON,
    ]
    requests.append(view)
    leafRecoveries[cid] = requests
    // `mls-ds` answers the acceptance entry, its coordinate, and recovery view.
    return reply(200, ["seq": seq, "coordinates": next, "entry": entry, "recovery": view])
  }

  private func submitTransition(_ b: JSON) throws -> Reply {
    guard let sr = b["signedRequest"] as? JSON, let body = sr["body"] as? JSON, let next = body["next"] as? JSON else {
      throw Fault(message: "submitTransition body malformed")
    }
    let type = body["$type"] as? String ?? ""
    let cid = try text(next, "conversationId")
    guard var state = conversations[cid] else { throw Fault(message: "unknown conversation") }
    guard jsonEqual(state["coordinates"], body["prior"]) else {
      throw Fault(message: "transition built against a superseded coordinate")
    }
    let seq = (entries[cid]?.count ?? 0) + 1
    let manifest = body["manifest"] as? JSON ?? JSON()
    if type.hasSuffix("leafRecoveryFulfillmentBody"), let bundle = manifest["welcomeBundle"] as? JSON {
      for delivery in bundle["deliveries"] as? [JSON] ?? [] {
        let slot = "\(try text(delivery, "recipientDid"))|\(try text(delivery, "recipientDeviceId"))"
        pendingWelcomes[slot, default: []].append([
          "welcomeId": bundle["welcomeId"] ?? NSNull(), "conversationId": cid, "sequencerDid": Self.dsDid,
          "transitionSeq": seq, "coordinates": next, "opaqueWelcome": bundle["opaqueWelcome"] ?? NSNull(),
          "metadataSnapshot": body["metadataSnapshot"] ?? NSNull(),
        ])
      }
    }
    // The exact entry is added after its schema arm is selected below.
    state["coordinates"] = next
    state["snapshotSeq"] = seq
    if let snapshot = body["metadataSnapshot"] { state["metadataSnapshot"] = snapshot }
    var leaves = state["leaves"] as? [JSON] ?? []
    for change in manifest["leafChanges"] as? [JSON] ?? [] {
      if change["$type"] as? String == "blue.catbird.chat.defs#removeLeaf" {
        leaves.removeAll { $0["userDid"] as? String == change["userDid"] as? String && $0["deviceId"] as? String == change["deviceId"] as? String }
        leafPeriods[cid] = (leafPeriods[cid] ?? []).map { period in
          guard period["removedSeq"] == nil, period["userDid"] as? String == change["userDid"] as? String,
                period["deviceId"] as? String == change["deviceId"] as? String else { return period }
          return period.merging(["removedSeq": seq]) { $1 }
        }
      } else if change["$type"] as? String == "blue.catbird.chat.defs#addLeafByRecovery" {
        leaves.append(["userDid": change["userDid"] ?? NSNull(), "deviceId": change["deviceId"] ?? NSNull(), "leafOrigin": "recovery"])
        leafPeriods[cid, default: []].append(["userDid": change["userDid"] ?? NSNull(), "deviceId": change["deviceId"] ?? NSNull(), "joinedSeq": seq])
      }
    }
    state["leaves"] = leaves
    var participants = state["participants"] as? [JSON] ?? []
    for change in body["participantChanges"] as? [JSON] ?? [] where change["$type"] as? String == "blue.catbird.chat.defs#removeParticipant" {
      participants.removeAll { $0["userDid"] as? String == change["userDid"] as? String }
    }
    state["participants"] = participants.map { participant -> JSON in
      var p = participant
      p["leafCount"] = leaves.filter { $0["userDid"] as? String == participant["userDid"] as? String }.count
      return p
    }
    conversations[cid] = state
    leafRecoveries[cid] = (leafRecoveries[cid] ?? []).map { request -> JSON in
      guard request["status"] as? String == "open" else { return request }
      let fulfilled = request["recoveryRequestId"] as? String == body["recoveryRequestId"] as? String
      var updated = request
      updated["status"] = fulfilled ? "fulfilled" : "superseded"
      var reservation = request["reservation"] as? JSON ?? JSON()
      reservation["status"] = fulfilled ? "consumed" : "released"
      updated["reservation"] = reservation
      return updated
    }
    let entryKinds = [
      "commitTransitionBody": "commitEntry", "leafRecoveryFulfillmentBody": "leafRecoveryFulfillmentEntry",
      "policyTransitionBody": "policyEntry", "metadataTransitionBody": "metadataEntry",
    ]
    guard let entryKind = entryKinds[String(type.dropFirst("blue.catbird.chat.defs#".count))] else {
      throw Fault(message: "fixture has no entry kind for \(type)")
    }
    let entry = try controlEntry(
      type: entryKind,
      signedRequest: sr,
      coordinate: next,
      seq: seq
    )
    entries[cid, default: []].append(entry)
    // `mls-ds` answers the sequenced entry carrying the exact signed request and receipt.
    return reply(200, [
      "coordinates": next,
      "entry": entry,
      "welcomes": [Any](),
    ])
  }

  private func controlEntry(
    type: String,
    signedRequest: JSON,
    coordinate: JSON,
    seq: Int
  ) throws -> JSON {
    guard let body = signedRequest["body"] as? JSON else {
      throw Fault(message: "control entry has no signed body")
    }
    let conversationId = try text(coordinate, "conversationId")
    let entryId = try text(body, body["transitionId"] == nil ? "conversationId" : "transitionId")
    let actor = try text(body, "actorDid")
    let device = try text(body, "actorDeviceId")
    let receivedAt = try text(body, "signedAt")
    guard let signedAt = ISO8601DateFormatter.fractional.date(from: receivedAt) else {
      throw Fault(message: "control request has invalid signedAt")
    }
    let issuedAtMs = Int64(signedAt.timeIntervalSince1970 * 1000)
    let commitment = try controlRequestDigest(signedRequest)
    let receipt = try signedSequencerReceipt(
      conversationId: conversationId,
      coordinate: coordinate,
      actorDid: actor,
      actorDeviceId: device,
      entryId: entryId,
      commitment: commitment,
      seq: UInt64(seq),
      issuedAtMs: issuedAtMs
    )
    return [
      "$type": "blue.catbird.chat.defs#\(type)",
      "entryId": entryId,
      "conversationId": conversationId,
      "seq": seq,
      "signedRequest": signedRequest,
      "sequencerReceipt": receipt,
      "receivedAt": receivedAt,
    ]
  }

  private func controlRequestDigest(_ signedRequest: JSON) throws -> Data {
    guard let body = signedRequest["body"] as? JSON,
          let type = body["$type"] as? String,
          let domain = body["signatureDomain"] as? String
    else {
      throw Fault(message: "control request is missing its type or signature domain")
    }
    let data = try JSONSerialization.data(withJSONObject: lexiconBodyJSON(body))
    let projected: Any
    switch type {
    case BlueCatbirdChatDefs.CreationBody.typeIdentifier:
      projected = try JSONDecoder().decode(BlueCatbirdChatDefs.CreationBody.self, from: data).toCBORValue()
    case BlueCatbirdChatDefs.CommitTransitionBody.typeIdentifier:
      projected = try JSONDecoder().decode(BlueCatbirdChatDefs.CommitTransitionBody.self, from: data).toCBORValue()
    case BlueCatbirdChatDefs.PolicyTransitionBody.typeIdentifier:
      projected = try JSONDecoder().decode(BlueCatbirdChatDefs.PolicyTransitionBody.self, from: data).toCBORValue()
    case BlueCatbirdChatDefs.ParticipantAcceptanceBody.typeIdentifier:
      projected = try JSONDecoder().decode(BlueCatbirdChatDefs.ParticipantAcceptanceBody.self, from: data).toCBORValue()
    case BlueCatbirdChatDefs.MetadataTransitionBody.typeIdentifier:
      projected = try JSONDecoder().decode(BlueCatbirdChatDefs.MetadataTransitionBody.self, from: data).toCBORValue()
    case BlueCatbirdChatDefs.LeafRecoveryFulfillmentBody.typeIdentifier:
      projected = try JSONDecoder().decode(BlueCatbirdChatDefs.LeafRecoveryFulfillmentBody.self, from: data).toCBORValue()
    default:
      throw Fault(message: "fixture has no canonical control body for \(type)")
    }
    var transcript = Data(domain.utf8)
    transcript.append(try DAGCBOR.encodeValue(canonicalBodyValue(projected, wire: body)))

    guard let actor = body["actorDid"] as? String,
          let device = body["actorDeviceId"] as? String,
          let key = deviceKeys[actor]?[device],
          let signature = bytes(signedRequest["signature"]),
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
          publicKey.isValidSignature(signature, for: transcript)
    else {
      throw Fault(message: "canonical control transcript does not verify")
    }
    return Data(SHA256.hash(data: transcript))
  }

  private func lexiconBodyJSON(_ value: Any, field: String? = nil) -> Any {
    let byteFields: Set<String> = [
      "archiveCommitment", "authorDeviceId", "blobId", "bytes", "ciphertext",
      "ciphertextSha256", "confirmationTag", "contentSignature", "conversationId",
      "epochHead", "groupContextHash", "groupId", "joinKeyPackageRef", "key",
      "keyPackageRef", "messageId", "nonce", "opaqueWelcome", "originTransitionId",
      "sha256", "signaturePublicKey", "transitionId", "waveform",
    ]
    if let object = value as? JSON {
      return Dictionary(uniqueKeysWithValues: object.map { key, nested in
        (key, lexiconBodyJSON(nested, field: key))
      })
    }
    if let array = value as? [Any] {
      return array.map { lexiconBodyJSON($0, field: field) }
    }
    if let field, byteFields.contains(field), let string = value as? String,
       bytes(string) != nil
    {
      return ["$bytes": string]
    }
    return value
  }

  private func canonicalBodyValue(_ value: Any, wire: Any?) -> Any {
    if let map = value as? OrderedCBORMap {
      let wireObject = wire as? JSON
      var converted = OrderedCBORMap()
      var sawType = false
      for entry in map.entries {
        if entry.key == "$type" {
          guard wireObject?["$type"] != nil else { continue }
          sawType = true
        }
        converted.append(
          key: entry.key,
          value: canonicalBodyValue(entry.value, wire: wireObject?[entry.key])
        )
      }
      if !sawType, let wireType = wireObject?["$type"] as? String {
        converted.append(key: "$type", value: wireType)
      }
      return converted
    }
    if let values = value as? [Any] {
      let wireValues = wire as? [Any] ?? []
      return values.enumerated().map {
        canonicalBodyValue($0.element, wire: $0.offset < wireValues.count ? wireValues[$0.offset] : nil)
      }
    }
    if let text = value as? String, text.utf8.count == 36, let uuid = UUID(uuidString: text) {
      var bytes = uuid.uuid
      return Data(bytes: &bytes, count: MemoryLayout.size(ofValue: bytes))
    }
    return value
  }

  private func signedSequencerReceipt(
    conversationId: String,
    coordinate: JSON,
    actorDid: String,
    actorDeviceId: String,
    entryId: String,
    commitment: Data,
    seq: UInt64,
    issuedAtMs: Int64
  ) throws -> JSON {
    guard let groupId = bytes(coordinate["groupId"]) else {
      throw Fault(message: "receipt coordinate has no groupId")
    }
    let epoch = uint64(coordinate["epoch"]) ?? 0
    let kid = "\(Self.dsDid)#mls-receipt-1"
    var transcript = Data("catbird-mls-sequencer-receipt-v2\0".utf8)
    for field in [Data(Self.dsDid.utf8), Data(kid.utf8), Data(conversationId.utf8), groupId] {
      transcript.appendLengthPrefixed(field)
    }
    transcript.appendBigEndian(epoch)
    transcript.appendLengthPrefixed(Data("\(actorDid)#\(actorDeviceId)".utf8))
    transcript.appendLengthPrefixed(Data(entryId.utf8))
    transcript.append(commitment)
    transcript.appendBigEndian(seq)
    transcript.appendBigEndian(UInt64(bitPattern: issuedAtMs))
    let signature = try P256WireSignature.sign(transcript, using: receiptKey)
    return [
      "kid": kid,
      "sequencerDid": Self.dsDid,
      "conversationId": conversationId,
      "generation": coordinate["generation"] ?? 0,
      "groupId": ["$bytes": groupId.base64EncodedString()],
      "epoch": epoch,
      "seq": seq,
      "entryId": entryId,
      "senderDid": actorDid,
      "senderDeviceId": actorDeviceId,
      "archiveCommitment": ["$bytes": commitment.base64EncodedString()],
      "issuedAtMs": issuedAtMs,
      "signature": ["$bytes": signature.base64EncodedString()],
    ]
  }

  /// The DS sequences the entry, mints its ID, and signs the `I13` receipt over it.
  private func sendMessage(_ b: JSON) throws -> Reply {
    guard let sr = b["signedRequest"] as? JSON, let body = sr["body"] as? JSON, let prior = body["prior"] as? JSON else {
      throw Fault(message: "sendMessage body malformed")
    }
    let cid = try text(prior, "conversationId")
    let messageId = try text(body, "messageId")
    if let replayed = entries[cid]?.first(where: { (($0["signedRequest"] as? JSON)?["body"] as? JSON)?["messageId"] as? String == messageId }) {
      guard jsonEqual(replayed["signedRequest"], sr) else { throw Fault(message: "uncertain send retries must replay the exact signed ciphertext") }
      return reply(200, ["entry": replayed, "sequencerReceipt": replayed["sequencerReceipt"] ?? NSNull()])
    }
    let actor = try text(body, "actorDid")
    let device = try text(body, "actorDeviceId")
    guard let groupId = bytes(prior["groupId"]),
          let commitment = bytes((body["aad"] as? JSON)?["archiveCommitment"]), commitment.count == 32
    else { throw Fault(message: "sendMessage coordinates malformed") }
    let epoch = uint64(prior["epoch"]) ?? 0
    let seq = UInt64((entries[cid]?.count ?? 0) + 1)
    let entryId = UUID().uuidString.lowercased()
    let issuedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
    let kid = "\(Self.dsDid)#mls-receipt-1"
    var transcript = Data("catbird-mls-sequencer-receipt-v2\0".utf8)
    for field in [Data(Self.dsDid.utf8), Data(kid.utf8), Data(cid.utf8), groupId] { transcript.appendLengthPrefixed(field) }
    transcript.appendBigEndian(epoch)
    transcript.appendLengthPrefixed(Data("\(actor)#\(device)".utf8))
    transcript.appendLengthPrefixed(Data(entryId.utf8))
    transcript.append(commitment)
    transcript.appendBigEndian(seq)
    transcript.appendBigEndian(UInt64(bitPattern: issuedAtMs))
    let signature = try P256WireSignature.sign(transcript, using: receiptKey)
    let receipt: JSON = [
      "kid": kid, "sequencerDid": Self.dsDid, "conversationId": cid, "generation": prior["generation"] ?? 0,
      "groupId": ["$bytes": groupId.base64EncodedString()], "epoch": epoch, "seq": seq, "entryId": entryId,
      "senderDid": actor, "senderDeviceId": device,
      "archiveCommitment": ["$bytes": commitment.base64EncodedString()], "issuedAtMs": issuedAtMs,
      "signature": ["$bytes": signature.base64EncodedString()],
    ]
    let entry: JSON = [
      "$type": "blue.catbird.chat.defs#applicationEntry", "entryId": entryId, "conversationId": cid,
      "seq": seq, "signedRequest": sr, "sequencerReceipt": receipt, "receivedAt": body["signedAt"] ?? NSNull(),
    ]
    entries[cid, default: []].append(entry)
    return reply(200, ["entry": entry, "sequencerReceipt": receipt])
  }

  /// `mls-ds` device-signed Labyrinth request: base64url claim `header` with an Ed25519
  /// `{header}-signature` over `domain || claim` by an enrolled chat device.
  private func deviceSignedClaim(_ request: URLRequest, header: String, deviceField: String, domain: String) throws -> (JSON, String, Data) {
    guard let claimBytes = request.value(forHTTPHeaderField: header).flatMap({ try? JWTBase64URL.decode($0) }),
          let signature = request.value(forHTTPHeaderField: "\(header)-signature").flatMap({ try? JWTBase64URL.decode($0) }),
          let claim = (try? JSONSerialization.jsonObject(with: claimBytes)) as? JSON,
          let device = claim[deviceField] as? String
    else { throw Fault(message: "missing device-signed claim") }
    guard let enrolled = deviceKeys.first(where: { $0.value[device] != nil }),
          let key = enrolled.value[device],
          (try? Curve25519.Signing.PublicKey(rawRepresentation: key))?.isValidSignature(signature, for: Data(domain.utf8) + claimBytes) == true
    else { throw Fault(message: "device signature does not verify for an enrolled device") }
    return (claim, enrolled.key, key)
  }

  /// `read_auth::verify`: the claim names its account, this route, and this exact canonical query.
  /// Returns the verified caller account.
  @discardableResult
  private func verifyRead(_ request: URLRequest, nsid: String, rawQuery: String) throws -> String {
    let (claim, account, _) = try deviceSignedClaim(request, header: "catbird-labyrinth-read", deviceField: "deviceId", domain: "CATBIRD-LABYRINTH-READ\0")
    let pairs = decodedPairs(rawQuery)
    guard claim["did"] as? String == account, claim["nsid"] as? String == nsid,
          claim["query"] as? String == canonicalQuery(pairs),
          pairs.filter({ $0.0 == "actorDeviceId" }).map(\.1) == [claim["deviceId"] as? String ?? ""]
    else { throw Fault(message: "read claim does not bind this account, route, and query") }
    return account
  }

  private func principal(_ device: Any?) throws -> String {
    guard let device = device as? String,
          let account = deviceKeys.first(where: { $0.value[device] != nil })?.key
    else { throw Fault(message: "relay names no enrolled chat device") }
    return account
  }

  // MARK: - Helpers

  private lazy var receiptKey = Self.fixtureSigningKey(Self.dsDid, "mls-receipt")

  private func signingKey(_ did: String) -> P256.Signing.PrivateKey {
    if let key = signingKeys[did] { return key }
    let key = Self.fixtureSigningKey(did, "sign")
    signingKeys[did] = key
    return key
  }

  private func kemKey(_ did: String) -> P256.KeyAgreement.PrivateKey {
    if let key = kemKeys[did] { return key }
    let key = (0 ..< 128).lazy.compactMap { try? P256.KeyAgreement.PrivateKey(rawRepresentation: Self.fixtureScalar(did, "kem", $0)) }.first!
    kemKeys[did] = key
    return key
  }

  private static func fixtureSigningKey(_ did: String, _ purpose: String) -> P256.Signing.PrivateKey {
    (0 ..< 128).lazy.compactMap { try? P256.Signing.PrivateKey(rawRepresentation: fixtureScalar(did, purpose, $0)) }.first!
  }

  /// `native_archive_auth.rs` `key()`: SHA-256 over a fixture-only domain, purpose, DID, attempt.
  private static func fixtureScalar(_ did: String, _ purpose: String, _ attempt: Int) -> Data {
    var data = Data("catbird-native-archive-fixture-only\0".utf8) + Data(purpose.utf8) + Data(did.utf8)
    data.appendBigEndian(UInt32(attempt))
    return Data(SHA256.hash(data: data))
  }

  private func next() -> UInt64 {
    sequence += 1
    return sequence
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  private func nowSeconds() -> UInt64 {
    UInt64(Date().timeIntervalSince1970)
  }

  private func tid(_ sequence: UInt64) -> String {
    let alphabet = Array("234567abcdefghijklmnopqrstuvwxyz")
    let value = (UInt64(1) << 62) | sequence
    return String((0 ..< 13).reversed().map { alphabet[Int((value >> (5 * UInt64($0))) & 31)] })
  }

  /// CIDv1 (dag-cbor, sha2-256) of a record as written, in the ATProto data model.
  private func dagCborCID(_ value: Any) throws -> CID {
    CID.fromDAGCBOR(try DAGCBOR.encodeValue(try dataModel(value)))
  }

  private func dataModel(_ value: Any) throws -> Any {
    switch value {
    case let string as String:
      return string
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
      guard !CFNumberIsFloatType(number) else { throw Fault(message: "floats are not DAG-CBOR") }
      return number.int64Value
    case is NSNull:
      return NSNull()
    case let array as [Any]:
      return try array.map(dataModel)
    case let object as JSON:
      if object.count == 1, let encoded = object["$bytes"] as? String {
        guard let data = Data(base64Unpadded: encoded) else { throw Fault(message: "invalid $bytes") }
        return data
      }
      if object.count == 1, let link = object["$link"] as? String {
        return CIDAsLink(cid: try CID.parse(link), representation: .link)
      }
      return try object.mapValues(dataModel)
    default:
      throw Fault(message: "unsupported record value \(type(of: value))")
    }
  }

  private func bytes(_ value: Any?) -> Data? {
    if let object = value as? JSON, let encoded = object["$bytes"] as? String { return Data(base64Unpadded: encoded) }
    return (value as? String).flatMap { Data(base64Unpadded: $0) }
  }

  /// The entry as `getEntries` serves it (see `forgeReceipts(messageIds:)`).
  private func served(_ entry: JSON) -> JSON {
    guard let messageId = ((entry["signedRequest"] as? JSON)?["body"] as? JSON)?["messageId"] as? String,
          forgedReceiptMessageIds.contains(messageId),
          var receipt = entry["sequencerReceipt"] as? JSON,
          var signature = bytes(receipt["signature"]), !signature.isEmpty
    else { return entry }
    signature[signature.startIndex] ^= 0x01
    receipt["signature"] = ["$bytes": signature.base64EncodedString()]
    var forged = entry
    forged["sequencerReceipt"] = receipt
    return forged
  }

  private func jsonEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return NSArray(object: lhs).isEqual(to: [rhs])
  }

  private func object(_ data: Data) throws -> JSON {
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { throw Fault(message: "body is not a JSON object") }
    return object
  }

  private func text(_ object: JSON, _ field: String) throws -> String {
    guard let value = object[field] as? String else { throw Fault(message: "missing \(field)") }
    return value
  }

  private func required(_ params: [String: String], _ field: String) throws -> String {
    guard let value = params[field] else { throw Fault(message: "missing \(field)") }
    return value
  }

  private func header(_ request: URLRequest, _ name: String) throws -> String {
    guard let value = request.value(forHTTPHeaderField: name) else { throw Fault(message: "missing \(name)") }
    return value
  }

  private func pageLimit(_ params: [String: String], default fallback: Int) throws -> Int {
    let limit = try params["limit"].map { raw -> Int in
      guard let value = Int(raw) else { throw Fault(message: "invalid page limit") }
      return value
    } ?? fallback
    guard (1 ... 1000).contains(limit) else { throw Fault(message: "invalid page limit") }
    return limit
  }

  private func uint64(_ value: Any?) -> UInt64? { (value as? NSNumber)?.uint64Value }
  private func int64(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }

  private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

  private func decodedPairs(_ rawQuery: String) -> [(String, String)] {
    rawQuery.split(separator: "&").compactMap { pair in
      let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0) }
      return parts.count == 2 ? (parts[0], parts[1]) : nil
    }
  }

  /// Fixture routes: duplicate parameters are refused (`native_archive_auth.rs` `query_params`).
  private func strictQuery(_ rawQuery: String) throws -> [String: String] {
    var params: [String: String] = [:]
    for (key, value) in decodedPairs(rawQuery) {
      guard params.updateValue(value, forKey: key) == nil else { throw Fault(message: "duplicate query parameter \(key)") }
    }
    return params
  }

  /// Mock DS routes keep the last repeated key (`supportedProtocolVersions=1&...=2`).
  private func lenientQuery(_ rawQuery: String) -> [String: String] {
    Dictionary(decodedPairs(rawQuery), uniquingKeysWith: { _, last in last })
  }

  /// `mls-ds` `canonical_query`: decoded pairs sorted bytewise, RFC 3986 re-encoded.
  private func canonicalQuery(_ pairs: [(String, String)]) -> String {
    let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let encode = { (value: String) in value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value }
    return pairs.sorted { ($0.0.utf8.lexicographicallyPrecedes($1.0.utf8)) || ($0.0 == $1.0 && $0.1.utf8.lexicographicallyPrecedes($1.1.utf8)) }
      .map { "\(encode($0.0))=\(encode($0.1))" }
      .joined(separator: "&")
  }

  private func reply(_ status: Int, _ value: Any) -> Reply {
    Reply(status: status, body: (try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8))
  }

  private func xrpcError(_ status: Int, _ error: String, _ message: String = "") -> Reply {
    reply(status, ["error": error, "message": message])
  }
}

/// `at:space/{authority}/{spaceType}/{skey}` (`atproto_spaces::SpaceUri`). Strict, like the
/// reference hosts: the alpha form `at://{authority}/space/...` is rejected.
private struct SpaceURI {
  static let prefix = "at:space/"

  let raw: String
  let authority: String
  let spaceType: String
  let skey: String

  init(_ raw: String) throws {
    let parts = raw.hasPrefix(Self.prefix)
      ? raw.dropFirst(Self.prefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init) : []
    guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }), parts[0].hasPrefix("did:") else {
      throw CocoaError(.coderInvalidValue)
    }
    (self.raw, authority, spaceType, skey) = (raw, parts[0], parts[1], parts[2])
  }

  func recordURI(_ author: String, _ collection: String, _ rkey: String) -> String {
    "\(raw)/\(author)/\(collection)/\(rkey)"
  }
}

/// Compact ES256 Space delegation/credential tokens (`atproto_spaces::tokens`) and the authority's
/// signed Space denial (`mls-ds` `space_host`).
private enum SpaceToken {
  static let delegation = "atproto-space-delegation+jwt"
  static let credential = "atproto-space-credential+jwt"
  static let denial = "catbird-space-denial+jwt"

  static func mint(typ: String, key: P256.Signing.PrivateKey, claims: [String: Any]) -> String {
    let encode = { (value: Any) in JWTBase64URL.encode(try! JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])) }
    let input = encode(["alg": "ES256", "typ": typ, "kid": "#atproto"]) + "." + encode(claims)
    return input + "." + JWTBase64URL.encode(try! P256WireSignature.sign(Data(input.utf8), using: key))
  }

  /// Claims of a `typ` token whose ES256 signature verifies under its issuer's `#atproto` key.
  static func verify(_ jwt: String, typ: String, issuerKey: (String) -> P256.Signing.PublicKey) -> [String: Any]? {
    let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3,
          let headerData = try? JWTBase64URL.decode(parts[0]),
          let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any],
          header["alg"] as? String == "ES256", header["typ"] as? String == typ,
          let claimsData = try? JWTBase64URL.decode(parts[1]),
          let claims = (try? JSONSerialization.jsonObject(with: claimsData)) as? [String: Any],
          let issuer = claims["iss"] as? String,
          let signature = (try? JWTBase64URL.decode(parts[2])).flatMap({ try? P256.Signing.ECDSASignature(rawRepresentation: $0) }),
          issuerKey(issuer).isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8))
    else { return nil }
    return claims
  }
}

private extension Data {
  init?(base64Unpadded value: String) {
    let padded = value + String(repeating: "=", count: (4 - value.utf8.count % 4) % 4)
    self.init(base64Encoded: padded)
  }

  mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
    Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
  }

  mutating func appendLengthPrefixed(_ field: Data) {
    appendBigEndian(UInt32(field.count))
    append(field)
  }
}

private extension ISO8601DateFormatter {
  static var fractional: ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }
}

/// Routes `MLSBoundedURLSession` traffic into `NativeArchiveMockNetwork.shared`.
final class NativeArchiveMockURLProtocol: URLProtocol, @unchecked Sendable {
  private static let queue = DispatchQueue(
    label: "blue.catbird.mls.test.native-archive-urlprotocol",
    qos: .userInitiated,
    attributes: .concurrent
  )

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let request = self.request
    let body = Self.body(of: request)
    let onMain = Thread.isMainThread
    Self.queue.async { [weak self] in
      guard let self, let url = request.url else { return }
      let reply = NativeArchiveMockNetwork.shared.handle(request, body: body, onMainThread: onMain)
      let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
      self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      self.client?.urlProtocol(self, didLoad: reply.body)
      self.client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}

  private static func body(of request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var out = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { break }
      out.append(buffer, count: count)
    }
    return out
  }
}
