import Foundation
import Petrel
import PetrelCatbird

// MARK: - Author epochs

/// Supplies the author's Labyrinth epoch (a `mailboxKeys` record or bare
/// `epochPublic` JSON) whose head is `epochHead`. The FFI verifies it.
protocol AuthorEpochResolver: Sendable {
  func epochJSON(did: DID, epochHead: Data) async throws -> String
}

enum AuthorEpochResolverError: Error, Equatable {
  case recordUnavailable
  case malformedRecord
  case unknownEpochHead
}

/// Reads `blue.catbird.labyrinth.mailboxKeys` from the author's PUBLIC repo:
/// `self` (latest `current`), then the immutable copies at rkey
/// `<epochNumber zero-padded to 12>` downward from `current.epochNumber - 1`
/// until one's `epochHead` equals the requested head (bytes equal). Nothing is
/// verified here beyond head equality; `CircleCrypto.openPost` verifies the
/// epoch and its attestation, so records reach it as the exact bytes the PDS
/// served (never a Petrel re-encoding).
///
/// Results are cached in memory by `(did, head)` for this resolver's lifetime
/// (one per account); nothing is persisted. A head that cannot be resolved
/// (no record, malformed records, not within `maxSteps` copies) is
/// negative-cached for `negativeTTL`, so later pages naming it cost no
/// requests. Thrown fetch errors (network) are not cached.
actor RepoAuthorEpochResolver: AuthorEpochResolver {
  /// Returns the record value JSON at `rkey` in `did`'s `mailboxKeys`
  /// collection, exactly as served, or nil when there is no such record.
  typealias FetchRecord = @Sendable (_ did: String, _ rkey: String) async throws -> String?

  static let collection = "blue.catbird.labyrinth.mailboxKeys"
  static let maxSteps = 64
  /// Larger epoch numbers are rejected as hostile (2^40 rotations is far
  /// beyond any real account) and keep all arithmetic away from overflow.
  static let maxEpochNumber = 1 << 40
  static let negativeTTL: TimeInterval = 3600

  private struct CacheKey: Hashable {
    let did: String
    let head: Data
  }

  private let fetch: FetchRecord
  private let now: @Sendable () -> Date
  private var cache: [CacheKey: String] = [:]
  private var failures: [CacheKey: (error: AuthorEpochResolverError, at: Date)] = [:]
  private var inFlight: [CacheKey: Task<String, Error>] = [:]

  init(fetch: @escaping FetchRecord, now: @escaping @Sendable () -> Date = Date.init) {
    self.fetch = fetch
    self.now = now
  }

  /// Production: `com.atproto.repo.getRecord` against the author's own PDS
  /// (resolved from their DID document), unauthenticated, as for other
  /// public-repo reads. Authoritative for the author's records and independent
  /// of whether the viewer's PDS proxies foreign repos. Issued raw so the
  /// record `value` can be sliced out byte-for-byte.
  static func live(client: ATProtoClient) -> RepoAuthorEpochResolver {
    let pool = PublicPDSClientPool()
    return RepoAuthorEpochResolver { did, rkey in
      let pdsURL = try await client.resolveDIDToPDSURL(did: did)
      let pds = await pool.client(for: pdsURL)
      let network = await pds.networkService
      let request = try await network.createURLRequest(
        endpoint: "com.atproto.repo.getRecord",
        method: "GET",
        headers: ["Accept": "application/json"],
        body: nil,
        queryItems: [
          URLQueryItem(name: "repo", value: did),
          URLQueryItem(name: "collection", value: collection),
          URLQueryItem(name: "rkey", value: rkey),
        ]
      )
      let (data, response) = try await network.performRequestReturningHTTPErrorResponses(
        request, skipTokenRefresh: false
      )
      return try recordValueJSON(statusCode: response.statusCode, body: data)
    }
  }

  /// The live path's response handling: the exact `value` bytes of a
  /// getRecord response; nil for a missing record (400/404); a `URLError`
  /// for anything else (transient, so never negative-cached).
  static func recordValueJSON(statusCode: Int, body: Data) throws -> String? {
    switch statusCode {
    case 200...299:
      guard let value = RawJSON.memberString("value", in: body) else {
        throw AuthorEpochResolverError.malformedRecord
      }
      return value
    case 400, 404:
      return nil
    default:
      throw URLError(.badServerResponse)
    }
  }

  func epochJSON(did: DID, epochHead: Data) async throws -> String {
    let key = CacheKey(did: did.didString(), head: epochHead)
    if let cached = cache[key] { return cached }
    if let failure = failures[key] {
      if now().timeIntervalSince(failure.at) < Self.negativeTTL { throw failure.error }
      failures[key] = nil
    }
    if let running = inFlight[key] { return try await running.value }
    let task = Task { try await self.walk(did: key.did, head: epochHead) }
    inFlight[key] = task
    defer { inFlight[key] = nil }
    do {
      return try await task.value
    } catch let error as AuthorEpochResolverError {
      failures[key] = (error, now())
      throw error
    }
  }

  static func rkey(for epochNumber: Int) -> String {
    String(format: "%012d", epochNumber)
  }

  private func walk(did: String, head: Data) async throws -> String {
    guard let selfJSON = try await fetch(did, "self") else {
      throw AuthorEpochResolverError.recordUnavailable
    }
    guard let current = Self.parse(selfJSON) else { throw AuthorEpochResolverError.malformedRecord }
    remember(did: did, head: current.head, json: selfJSON)
    if current.head == head { return selfJSON }
    // `parse` bounds the number to 0...maxEpochNumber, so this never overflows.
    guard current.number > 0 else { throw AuthorEpochResolverError.unknownEpochHead }

    var number = current.number - 1
    var steps = 0
    while number >= 0, steps < Self.maxSteps {
      steps += 1
      let candidate = number
      number -= 1
      guard let json = try await fetch(did, Self.rkey(for: candidate)),
            let copy = Self.parse(json), copy.number == candidate
      else { continue }
      remember(did: did, head: copy.head, json: json)
      if copy.head == head { return json }
    }
    throw AuthorEpochResolverError.unknownEpochHead
  }

  private func remember(did: String, head: Data, json: String) {
    cache[CacheKey(did: did, head: head)] = json
  }

  private struct EpochFields: Decodable {
    struct Head: Decodable {
      let bytes: String
      enum CodingKeys: String, CodingKey { case bytes = "$bytes" }
    }

    let epochNumber: Int
    let epochHead: Head
  }

  private struct Wrapped: Decodable {
    let current: EpochFields
  }

  private struct Probe: Decodable {
    let current: AnyField?
    struct AnyField: Decodable {}
  }

  /// `(epochNumber, epochHead)` from a `mailboxKeys` record (`current`) or a
  /// bare `epochPublic`. The number must be a JSON integer in
  /// `0...maxEpochNumber`; anything else (fractions, exponents beyond Int,
  /// negatives, booleans) is malformed.
  static func parse(_ json: String) -> (number: Int, head: Data)? {
    let data = Data(json.utf8)
    let decoder = JSONDecoder()
    guard let probe = try? decoder.decode(Probe.self, from: data) else { return nil }
    let fields: EpochFields?
    if probe.current != nil {
      fields = (try? decoder.decode(Wrapped.self, from: data))?.current
    } else {
      fields = try? decoder.decode(EpochFields.self, from: data)
    }
    guard let fields, (0...maxEpochNumber).contains(fields.epochNumber),
          let head = decodeBase64(fields.epochHead.bytes)
    else { return nil }
    return (fields.epochNumber, head)
  }

  /// Accepts padded or unpadded base64 (Rust emits unpadded, Petrel padded).
  private static func decodeBase64(_ string: String) -> Data? {
    var padded = string.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    let remainder = padded.count % 4
    if remainder > 0 { padded += String(repeating: "=", count: 4 - remainder) }
    return Data(base64Encoded: padded)
  }
}

/// One unauthenticated client per PDS host for public-repo reads.
private actor PublicPDSClientPool {
  private var clients: [URL: ATProtoClient] = [:]

  func client(for url: URL) async -> ATProtoClient {
    if let existing = clients[url] { return existing }
    let client = await ATProtoClient(baseURL: url)
    clients[url] = client
    return client
  }
}

// MARK: - Concurrency bound

/// FIFO counting semaphore. Each `openPost` opens a Labyrinth session (network
/// and the archive lock) on an unbounded GCD queue, so callers bound it here.
actor CircleOpenLimiter {
  private let limit: Int
  private var active = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) {
    self.limit = max(1, limit)
  }

  func acquire() async {
    if active < limit {
      active += 1
      return
    }
    // The releasing caller hands its slot over directly.
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    if waiters.isEmpty {
      active = max(0, active - 1)
    } else {
      waiters.removeFirst().resume()
    }
  }
}
