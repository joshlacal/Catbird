import Foundation
import Petrel
import PetrelCatbird

/// Typealias for the generated Circle summary representation.
public typealias CircleSummary = BlueCatbirdCircleDefs.CircleSummary

extension SpaceRef: @retroactive Equatable, @retroactive Hashable {
  public static func == (lhs: SpaceRef, rhs: SpaceRef) -> Bool {
    lhs.spaceDID == rhs.spaceDID && lhs.spaceType == rhs.spaceType && lhs.skey == rhs.skey
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(spaceDID)
    hasher.combine(spaceType)
    hasher.combine(skey)
  }
}

extension BlueCatbirdCircleDefs.CircleSummary: @retroactive Equatable {
  public static func == (lhs: BlueCatbirdCircleDefs.CircleSummary, rhs: BlueCatbirdCircleDefs.CircleSummary) -> Bool {
    lhs.uri == rhs.uri &&
    lhs.circleId == rhs.circleId &&
    lhs.name == rhs.name &&
    lhs.owner == rhs.owner &&
    lhs.memberCount == rhs.memberCount &&
    lhs.muted == rhs.muted
  }
}

extension BlueCatbirdCircleDefs.CircleSummary {
  /// True iff the space-ref's type segment is the encrypted Circle space type.
  var isEncrypted: Bool {
    uri.spaceType == CircleConfiguration.encryptedSpaceType
  }
}

/// Identity of the standalone Circle AppView.
///
/// `clientID` and `serviceDID` are NOT interchangeable. `clientID` is the
/// AppView's OAuth client identifier — the HTTPS URL of its client-metadata
/// document — and is the value named in the memberspace policy's `allowedApps`. `serviceDID`
/// is only the `atproto-proxy` target, not an OAuth client identifier.
enum CircleConfiguration {
  static let protocolRevision = "d4def6e9f521896ed8222f576d54923d00b5fbeb"

  /// Service identifier the gateway proxies Circle reads to.
  static let serviceDID = "did:web:circles.catbird.blue#atproto_circles"

  /// NSID prefix registered against `serviceDID`. Petrel's service-DID map is
  /// longest-prefix matched, so this one entry routes every generated
  /// `blue.catbird.circle.*` read without per-call header plumbing.
  static let serviceNSIDPrefix = "blue.catbird.circle"

  /// OAuth client_id of the AppView, per `nest/circle-appview/src/oauth.rs`,
  /// which derives it as `{base_url}/oauth/client-metadata.json`.
  static let clientID = "https://circles.catbird.blue/oauth/client-metadata.json"

  /// Space type for every Catbird Circle.
  static let spaceType = "blue.catbird.circle"

  /// Space type for end-to-end encrypted Circles. OAuth scopes are granted per
  /// space type, so every scope list naming `spaceType` must also name this.
  static let encryptedSpaceType = "blue.catbird.circle.encrypted"

  /// Collection holding wrapped Circle content keys (encrypted Circles).
  static let keyCollection = "blue.catbird.circle.key"

  /// Collection holding encrypted Circle posts.
  static let postCollection = "blue.catbird.circle.post"

  /// Most key versions a member is re-wrapped to when joining.
  static let maxRewrapVersions = 24

  /// Oldest key version (by age) that is still re-wrapped to a new member.
  static let maxRewrapAge: TimeInterval = 365 * 24 * 3600

  /// Grace window during which a post sealed under a just-rotated key is accepted.
  static let staleKeyGrace: TimeInterval = 600

  /// Collection holding a Circle's metadata record.
  static let metadataCollection = "blue.catbird.circle.metadata"

  /// Base URL used to start the AppView's server-side OAuth flow.
  static let appViewBaseURL = URL(string: "https://circles.catbird.blue")!
}

/// The single immutable audience for a Circle-capable post.
///
/// A post targets exactly one destination: Public or one named Circle. No
/// failure may retry against the public repo, so the destination is decided
/// once and carried unchanged through submission.
public enum CircleDestination: Equatable, Sendable {
  case `public`
  case circle(CircleSummary)
}

/// Immutable snapshot of a post submission, captured before uploads begin.
public struct PostSubmission: Sendable, Equatable {
  public let id: UUID
  public let destination: CircleDestination
  public let text: String
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    destination: CircleDestination,
    text: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.destination = destination
    self.text = text
    self.createdAt = createdAt
  }
}

/// Access state of a Circle Space, surfaced as an explicit transition rather
/// than being inferred from URI shape in rendering code.
public enum CircleAccessState: String, Sendable {
  case active
  case expired
  case removed
  case unsupported
  /// The AppView has no OAuth grant for this account yet, so it refused the
  /// read. Recoverable by authorizing the AppView; never a Space deletion.
  case needsAuthorization
}

/// A single page of hydrated Circle feed items. Circle identity lives beside
/// every hydrated post; consumers never infer privacy from URI shape.
public struct CircleFeedPage: Sendable {
  public let items: [BlueCatbirdCircleDefs.FeedItem]
  public let cursor: String?

  public init(items: [BlueCatbirdCircleDefs.FeedItem], cursor: String?) {
    self.items = items
    self.cursor = cursor
  }
}


/// Page of Circles owned or joined by the active account.
struct CircleListPage: Sendable {
  let circles: [BlueCatbirdCircleDefs.CircleSummary]
  let cursor: String?
}

/// A Space-bounded post thread plus its Circle identity.
struct CircleThreadPage: Sendable {
  let thread: AppBskyFeedDefs.ThreadViewPost
  let circle: BlueCatbirdCircleDefs.CircleSummary
}

/// A page of private Circle notifications.
struct CircleNotificationPage: Sendable {
  let notifications: [BlueCatbirdCircleDefs.Notification]
  let cursor: String?
}

struct CircleMember: Sendable, Equatable {
  let did: DID
  let read: Bool
  let write: Bool
}

/// Server-advertised Circle capability metadata.
struct CircleCapability: Sendable, Equatable {
  let enabled: Bool
  let protocolRevision: String
  let supportsImages: Bool
  var supportsEncryptedPosts: Bool = false

  var isCompatible: Bool {
    enabled && protocolRevision == CircleConfiguration.protocolRevision
  }
}


/// Reason reported against a Circle record through the private moderation path.
enum CircleReportReason: String, Sendable {
  case spam
  case abuse
  case other

  var clientValue: BlueCatbirdCircleReportRecord.InputReason {
    switch self {
    case .spam: return .value_spam
    case .abuse: return .value_abuse
    case .other: return .value_other
    }
  }
}

/// Draft content for a Circle post. Image upload happens through the user's
/// PDS via Nest; the final record write goes through `com.atproto.space`.
struct CirclePostDraft: Sendable {
  let text: String
  let facets: [AppBskyRichtextFacet]?
  let reply: AppBskyFeedPost.ReplyRef?
  let langs: [LanguageCodeContainer]
  let labels: AppBskyFeedPost.AppBskyFeedPostLabelsUnion?
  let embed: AppBskyFeedPost.AppBskyFeedPostEmbedUnion?
  let createdAt: ATProtocolDate
  /// Encrypted Circles only: media already encrypted and uploaded as
  /// ciphertext. Its keys travel only inside the sealed payload.
  let encryptedMedia: [CircleEncryptedMedia]

  init(
    text: String,
    facets: [AppBskyRichtextFacet]? = nil,
    reply: AppBskyFeedPost.ReplyRef? = nil,
    langs: [LanguageCodeContainer] = [],
    labels: AppBskyFeedPost.AppBskyFeedPostLabelsUnion? = nil,
    embed: AppBskyFeedPost.AppBskyFeedPostEmbedUnion? = nil,
    createdAt: ATProtocolDate = ATProtocolDate(date: Date()),
    encryptedMedia: [CircleEncryptedMedia] = []
  ) {
    self.text = text
    self.facets = facets
    self.reply = reply
    self.langs = langs
    self.labels = labels
    self.embed = embed
    self.createdAt = createdAt
    self.encryptedMedia = encryptedMedia
  }
}

/// Visibility context of a post (public network or a private Circle Space).
public enum PostVisibilityContext: Equatable, Hashable, Sendable, CustomStringConvertible {
  case `public`
  case circle(BlueCatbirdCircleDefs.CircleSummary)

  public var description: String {
    switch self {
    case .public: return "public"
    case .circle(let circle): return "circle(\(circle.name))"
    }
  }
}

/// Capability matrix for interactions on a post based on its visibility context.
public struct PostCapabilities: Equatable, Sendable {
  public let canReply: Bool
  public let canLike: Bool
  public let canDelete: Bool
  public let canRepost: Bool
  public let canQuote: Bool
  public let canPublicShare: Bool

  public var canSharePublicly: Bool {
    canPublicShare
  }

  public static let circle = PostCapabilities(
    canReply: true,
    canLike: true,
    canDelete: false,
    canRepost: false,
    canQuote: false,
    canPublicShare: false
  )

  public static let `public` = PostCapabilities(
    canReply: true,
    canLike: true,
    canDelete: false,
    canRepost: true,
    canQuote: true,
    canPublicShare: true
  )

  public static func forContext(_ context: PostVisibilityContext, isAuthor: Bool = false) -> PostCapabilities {
    switch context {
    case .public:
      return PostCapabilities(
        canReply: true,
        canLike: true,
        canDelete: isAuthor,
        canRepost: true,
        canQuote: true,
        canPublicShare: true
      )
    case .circle:
      return PostCapabilities(
        canReply: true,
        canLike: true,
        canDelete: isAuthor,
        canRepost: false,
        canQuote: false,
        canPublicShare: false
      )
    }
  }
}

/// Errors raised by the Circle transport. These remain Circle-scoped and are
/// never swallowed or redirected to the public path.
public enum CircleError: Error, LocalizedError, Equatable {
  case upstreamUnavailable
  case accessRemoved
  case accessExpired
  case unsupportedPDS
  case protocolRevisionMismatch
  case authRequired
  case clientNotInitialized
  case invalidResponse
  case missingLikeUri
  case networkError(String)
  case spaceWriteRejected(String)
  case notAuthorized
  case invalidParameter(String)
  /// Another writer's Circle key record occupies the version this device just
  /// wrote; the local key was not adopted (refresh and retry).
  case keyVersionConflict
  /// An encrypted Circle's key is missing, older than the server's latest, or
  /// the post could not be sealed. The post is not written (fail closed).
  case encryptionUnavailable
  /// A member a dry-run wrap excluded (D16); `reason` is the user-facing copy.
  /// Retryable: the exclusion can be transient.
  case ineligibleMember(reason: String)
  /// The Circle summary's `owner` is not the authority of its Space URI (the
  /// real owner). Nothing from that summary drives key trust.
  case ownerMismatch
  /// The Circle's keys could not be checked right now (offline, directory or
  /// session unavailable). Retryable; nothing was posted (I3).
  case keysTemporarilyUnavailable
  /// This device's Circle key store could not be read (for example the
  /// Keychain before first unlock). Retryable; nothing was posted (I3).
  case keyStoreUnavailable

  public static func == (lhs: CircleError, rhs: CircleError) -> Bool {
    switch (lhs, rhs) {
    case (.upstreamUnavailable, .upstreamUnavailable): return true
    case (.accessRemoved, .accessRemoved): return true
    case (.accessExpired, .accessExpired): return true
    case (.unsupportedPDS, .unsupportedPDS): return true
    case (.protocolRevisionMismatch, .protocolRevisionMismatch): return true
    case (.authRequired, .authRequired): return true
    case (.clientNotInitialized, .clientNotInitialized): return true
    case (.invalidResponse, .invalidResponse): return true
    case (.missingLikeUri, .missingLikeUri): return true
    case (.networkError(let l), .networkError(let r)): return l == r
    case (.spaceWriteRejected(let l), .spaceWriteRejected(let r)): return l == r
    case (.notAuthorized, .notAuthorized): return true
    case (.invalidParameter(let l), .invalidParameter(let r)): return l == r
    case (.keyVersionConflict, .keyVersionConflict): return true
    case (.encryptionUnavailable, .encryptionUnavailable): return true
    case (.ineligibleMember(let l), .ineligibleMember(let r)): return l == r
    case (.ownerMismatch, .ownerMismatch): return true
    case (.keysTemporarilyUnavailable, .keysTemporarilyUnavailable): return true
    case (.keyStoreUnavailable, .keyStoreUnavailable): return true
    default: return false
    }
  }

  public var errorDescription: String? {
    switch self {
    case .upstreamUnavailable:
      return "The Circle service is temporarily unavailable."
    case .accessRemoved:
      return "Your access to this Circle was removed."
    case .accessExpired:
      return "Your access to this Circle has expired. Reauthorize to continue."
    case .unsupportedPDS:
      return "This server does not support Spaces."
    case .protocolRevisionMismatch:
      return "The server's Circle protocol revision is incompatible with this client."
    case .authRequired:
      return "Authentication is required to access this Circle."
    case .clientNotInitialized:
      return "The network client is not initialized."
    case .invalidResponse:
      return "The Circle service returned an invalid response."
    case .missingLikeUri:
      return "Cannot unlike: missing like URI."
    case .networkError(let message):
      return "Network error: \(message)"
    case .spaceWriteRejected(let message):
      return "Circle write rejected: \(message)"
    case .notAuthorized:
      return "You are not authorized to perform this operation."
    case .invalidParameter(let message):
      return message
    case .keyVersionConflict:
      return "This Circle's key changed on another device. Try again."
    case .encryptionUnavailable:
      return "Can't post to this Circle right now. Your draft was kept."
    case .ineligibleMember(let reason):
      return reason
    case .ownerMismatch:
      return "This Circle's data looks inconsistent. Try again later."
    case .keysTemporarilyUnavailable:
      return "Waiting to reach this Circle's keys. Your draft was kept; try again in a moment."
    case .keyStoreUnavailable:
      return "This Circle's keys are unavailable on this device right now. Your draft was kept."
    }
  }
}

/// Keys an encrypted-post report discloses to moderators (spec §8): the
/// post key and, per attachment, the media key and IV.
struct CircleReportDisclosure: Equatable, Sendable {
  struct Media: Equatable, Sendable {
    let cid: String
    let key: Data
    let iv: Data
  }

  /// Lexicon bound on `disclosedMedia`.
  static let maxMedia = 32

  let postKey: Data
  let media: [Media]
}

/// The outcome of a Circle publish. `repostedAfterKeyRefresh` is set when the
/// post was re-sealed under a newer key and the stale copy removed (§4.4).
///
/// `keyCheckFailed`: the post was written, but the post-publish key check
/// (§4.4 backstop) could not run, so a stale-key repost may be needed. The
/// composer says so instead of reporting a silent success.
struct CirclePublishResult: Equatable, Sendable {
  let uri: ATProtocolURI
  let repostedAfterKeyRefresh: Bool
  var keyCheckFailed: Bool = false
}

enum CircleReportCopy {
  /// Spec §8 consent, shown before an encrypted post is reported.
  static let disclosureConsent = "Reporting shares this post's decryption key with Catbird moderators."
  /// The post was never opened on this device, so there is no key to share.
  static let notOpened = "Open this post before reporting it."
}

enum CirclePostCopy {
  /// §4.4: one non-blocking line after a repost under a newer key.
  static let repostedAfterKeyRefresh = "Reposted after key refresh"
  static let keyCheckFailed = "Posted, but the Circle's key check didn't finish. If members can't read it, post again."
}

/// The narrow network seam used by `CircleService`. Production uses
/// `GatewayCircleTransport`; tests use a recording double. Public writes and
/// reads never appear on this seam, so a Circle failure cannot fall back to
/// the public repo.
protocol CircleTransport: Sendable {
  var publicEndpointCallCount: Int { get async }

  // MARK: AppView reads, proxied via `CircleConfiguration.serviceDID`
  func capabilities() async throws -> CircleCapability
  func listCircles(cursor: String?) async throws -> CircleListPage
  func getFeed(space: SpaceRef?, cursor: String?) async throws -> CircleFeedPage
  func getPostThread(uri: ATProtocolURI, space: SpaceRef) async throws -> CircleThreadPage
  func listNotifications(cursor: String?) async throws -> CircleNotificationPage
  func media(space: SpaceRef, authorDID: DID, cid: CID) async throws -> Data
  func updatePreferences(space: SpaceRef, muted: Bool) async throws -> Bool
  func report(post: ATProtocolURI, circle: CircleSummary, reason: CircleReportReason, details: String?) async throws -> UUID
  func activateCircle(space: SpaceRef) async throws -> CircleSummary

  // MARK: Permissioned writes into the Space
  func publishPost(destination: CircleSummary, draft: CirclePostDraft) async throws -> ATProtocolURI
  func like(post: AppBskyFeedDefs.PostView, circle: CircleSummary) async throws -> ATProtocolURI
  func deletePost(uri: ATProtocolURI, circle: CircleSummary) async throws
  func deleteLike(uri: ATProtocolURI, circle: CircleSummary) async throws

  // MARK: Space administration, direct to the owner's own PDS
  func createSpace(skey: String, circleId: String, name: String, memberDIDs: [DID]) async throws -> CircleSummary
  func deleteSpace(space: SpaceRef) async throws
  func addMember(space: SpaceRef, did: DID) async throws
  func removeMember(space: SpaceRef, did: DID) async throws
  func listMembers(space: SpaceRef) async throws -> [CircleMember]

  // MARK: Encrypted Circles (spec §4.2, §6)
  /// Creates a `blue.catbird.circle.encrypted` Space and its metadata, with no members.
  func createEncryptedSpace(skey: String, circleId: String, name: String) async throws -> CircleSummary
  /// Key records newer than `sinceVersion`, delivered by the AppView (D12),
  /// each with its record's exact server JSON for the FFI.
  func getKeys(space: SpaceRef, sinceVersion: Int?) async throws -> CircleKeysResponse
  /// Creates or replaces the owner's `blue.catbird.circle.key` record at `rkey`.
  func putKeyRecord(space: SpaceRef, rkey: String, recordJSON: String) async throws -> ATProtocolURI
  /// Creates the author's sealed `blue.catbird.circle.post` record at the
  /// canonical `postURI` bound into the post's AAD: its rkey, and its author,
  /// which must be the repo being written (else `encryptionUnavailable`). The
  /// record's `attachments` are the Space attachment manifest for the
  /// encrypted blobs.
  func publishEncryptedPost(destination: CircleSummary, postURI: ATProtocolURI, recordJSON: String) async throws -> ATProtocolURI
  /// Deletes the author's own `blue.catbird.circle.post` record at `uri`
  /// (spec §4.4: the stale copy after a repost under a newer key).
  func deleteEncryptedPost(uri: ATProtocolURI, circle: CircleSummary) async throws
  /// Reports a post; for an encrypted post `disclosure` carries the post key
  /// and media keys the reporter consented to share (spec §8).
  func report(
    post: ATProtocolURI, circle: CircleSummary, reason: CircleReportReason, details: String?,
    disclosure: CircleReportDisclosure?
  ) async throws -> UUID
  /// Creates a `blue.catbird.circle.encrypted` Space whose metadata carries the
  /// owner's history policy and, for a migration (D17), `migratedFrom`.
  func createEncryptedSpace(
    skey: String, circleId: String, name: String, historyForNewMembers: Bool, migratedFrom: SpaceRef?
  ) async throws -> CircleSummary
  /// The owner's `blue.catbird.circle.metadata` record (rkey `self`) in
  /// `space`, or nil when the Space has none.
  func getMetadata(space: SpaceRef) async throws -> BlueCatbirdCircleMetadata?
  /// Creates or replaces the owner's metadata record in `space`.
  func putMetadata(space: SpaceRef, metadata: BlueCatbirdCircleMetadata) async throws
}

/// Transports that predate encrypted Circles (test doubles, the E2E harness)
/// refuse the encrypted surface loudly instead of silently succeeding.
extension CircleTransport {
  func createEncryptedSpace(skey: String, circleId: String, name: String) async throws -> CircleSummary {
    throw CircleError.invalidParameter("Encrypted Circles are not supported by this transport.")
  }

  func getKeys(space: SpaceRef, sinceVersion: Int?) async throws -> CircleKeysResponse {
    throw CircleError.invalidParameter("Encrypted Circles are not supported by this transport.")
  }

  func putKeyRecord(space: SpaceRef, rkey: String, recordJSON: String) async throws -> ATProtocolURI {
    throw CircleError.invalidParameter("Encrypted Circles are not supported by this transport.")
  }

  func publishEncryptedPost(destination: CircleSummary, postURI: ATProtocolURI, recordJSON: String) async throws -> ATProtocolURI {
    throw CircleError.encryptionUnavailable
  }

  func deleteEncryptedPost(uri: ATProtocolURI, circle: CircleSummary) async throws {
    throw CircleError.encryptionUnavailable
  }

  /// A plain report goes through the original entry point; a disclosure is
  /// never silently dropped by a transport that cannot carry it.
  func report(
    post: ATProtocolURI, circle: CircleSummary, reason: CircleReportReason, details: String?,
    disclosure: CircleReportDisclosure?
  ) async throws -> UUID {
    guard disclosure == nil else { throw CircleError.encryptionUnavailable }
    return try await report(post: post, circle: circle, reason: reason, details: details)
  }

  /// The default policy with no migration is the plain encrypted create; any
  /// other request is refused rather than silently dropping its metadata.
  func createEncryptedSpace(
    skey: String, circleId: String, name: String, historyForNewMembers: Bool, migratedFrom: SpaceRef?
  ) async throws -> CircleSummary {
    guard historyForNewMembers, migratedFrom == nil else {
      throw CircleError.invalidParameter("Encrypted Circles are not supported by this transport.")
    }
    return try await createEncryptedSpace(skey: skey, circleId: circleId, name: name)
  }

  func getMetadata(space: SpaceRef) async throws -> BlueCatbirdCircleMetadata? {
    throw CircleError.invalidParameter("Circle metadata is not supported by this transport.")
  }

  func putMetadata(space: SpaceRef, metadata: BlueCatbirdCircleMetadata) async throws {
    throw CircleError.invalidParameter("Circle metadata is not supported by this transport.")
  }
}

/// Maps a generated `BlueCatbirdCircle*` error (or gateway/network error) to a
/// typed `CircleError`. Unknown or non-Circle errors are wrapped as a network
/// error so the boundary stays `CircleError`-shaped.
func circleError(from error: any Error) -> CircleError {
  if let circleError = error as? CircleError {
    return circleError
  }

  if let atprotoError = error as? any ATProtoErrorType {
    switch atprotoError.errorName {
    case "AuthRequired": return .authRequired
    case "AccessRemoved": return .accessRemoved
    case "UnsupportedPDS": return .unsupportedPDS
    case "ProtocolRevisionMismatch": return .protocolRevisionMismatch
    case "UpstreamUnavailable", "UpstreamFailure": return .upstreamUnavailable
    case "NotAuthorized", "AccountNotAuthorized", "SpaceNotFound": return .notAuthorized
    default: break
    }
  }

  if let xrpc = error as? ATProtoXRPCError {
    switch xrpc.error {
    case "AuthRequired": return .authRequired
    case "AccessRemoved": return .accessRemoved
    case "UnsupportedPDS": return .unsupportedPDS
    case "ProtocolRevisionMismatch": return .protocolRevisionMismatch
    case "UpstreamUnavailable", "UpstreamFailure": return .upstreamUnavailable
    case "NotAuthorized", "AccountNotAuthorized", "SpaceNotFound": return .notAuthorized
    default: break
    }
  }

  return .networkError(error.localizedDescription)
}

public extension Notification.Name {
  /// Posted when a Circle's mute state is updated.
  /// `userInfo` contains `accountDID` (String) and `spaceURI` (String).
  static let circleMuteStateChanged = Notification.Name("CircleMuteStateChanged")

  /// Posted when a Circle Space is deleted and confirmed `.complete` by the server.
  /// `userInfo` contains `accountDID` (String) and `spaceURI` (String).
  static let circleDeleted = Notification.Name("CircleDeleted")

  /// Posted when an account is logged out, switched away from, or removed.
  /// Synchronously invalidates loaded Circle models for the departing DID and increments their generation.
  /// `userInfo` contains `accountDID` (String).
  static let circleAccountInvalidated = Notification.Name("CircleAccountInvalidated")

  /// Posted when a Circle post or reply is published.
  /// `userInfo` contains `accountDID` (String) and `spaceURI` (String).
  static let circlePostPublished = Notification.Name("CirclePostPublished")
}

/// A `blue.catbird.circle.getKeys` response: typed entries for Swift's own use,
/// and each entry's `record` as the exact JSON the AppView served, which is
/// what `CircleCrypto.openCircleKey` receives (never a Petrel re-encoding).
struct CircleKeysResponse: Sendable {
  struct Entry: Sendable {
    let typed: BlueCatbirdCircleGetKeys.KeyEntry
    let recordJSON: String

    var keyVersion: Int { typed.keyVersion }
    var cid: CIDString { typed.cid }
    var record: BlueCatbirdCircleKey { typed.record }
  }

  let entries: [Entry]
  let latestKeyVersion: Int
  /// Rows the AppView left out of this page (malformed or over its size cap):
  /// the page is incomplete and the missing versions are retried later.
  let skipped: Int

  init(entries: [Entry], latestKeyVersion: Int, skipped: Int = 0) {
    self.entries = entries
    self.latestKeyVersion = latestKeyVersion
    self.skipped = skipped
  }

  /// Decodes a getKeys response body. Throws `invalidResponse` when the body
  /// does not decode or its raw `keys[i].record` slices do not line up with
  /// the typed entries.
  init(responseBody data: Data) throws {
    guard
      let output = try? JSONDecoder().decode(BlueCatbirdCircleGetKeys.Output.self, from: data),
      let keys = RawJSON.member("keys", in: data),
      let rawEntries = RawJSON.elements(in: keys),
      rawEntries.count == output.keys.count
    else { throw CircleError.invalidResponse }
    var entries: [Entry] = []
    for (typed, raw) in zip(output.keys, rawEntries) {
      guard let record = RawJSON.memberString("record", in: raw) else { throw CircleError.invalidResponse }
      entries.append(Entry(typed: typed, recordJSON: record))
    }
    self.init(entries: entries, latestKeyVersion: output.latestKeyVersion, skipped: output.skipped ?? 0)
  }
}
