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
    lhs.name == rhs.name &&
    lhs.owner == rhs.owner &&
    lhs.accessState == rhs.accessState &&
    lhs.muted == rhs.muted &&
    lhs.members == rhs.members
  }
}

extension BlueCatbirdCircleDefs.Operation: @retroactive Equatable {
  public static func == (lhs: BlueCatbirdCircleDefs.Operation, rhs: BlueCatbirdCircleDefs.Operation) -> Bool {
    lhs.id == rhs.id &&
    lhs.status == rhs.status &&
    lhs.space == rhs.space &&
    lhs.error == rhs.error
  }
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

/// Server-advertised Circle capability metadata.
struct CircleCapability: Sendable, Equatable {
  let enabled: Bool
  let protocolRevision: String
  let supportsImages: Bool
}

/// Outcome of a Circle management operation (create/update member/delete).
typealias CircleOperation = BlueCatbirdCircleDefs.Operation

/// Add or remove a member from a Circle.
enum CircleMemberAction: String, Sendable {
  case add
  case remove

  var generated: BlueCatbirdCircleUpdateMember.InputAction {
    switch self {
    case .add: return .value_add
    case .remove: return .value_remove
    }
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

  init(
    text: String,
    facets: [AppBskyRichtextFacet]? = nil,
    reply: AppBskyFeedPost.ReplyRef? = nil,
    langs: [LanguageCodeContainer] = [],
    labels: AppBskyFeedPost.AppBskyFeedPostLabelsUnion? = nil,
    embed: AppBskyFeedPost.AppBskyFeedPostEmbedUnion? = nil,
    createdAt: ATProtocolDate = ATProtocolDate(date: Date())
  ) {
    self.text = text
    self.facets = facets
    self.reply = reply
    self.langs = langs
    self.labels = labels
    self.embed = embed
    self.createdAt = createdAt
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
    }
  }
}

/// The narrow network seam used by `CircleService`. Production uses
/// `GatewayCircleTransport`; tests use a recording double. Public writes and
/// reads never appear on this seam, so a Circle failure cannot fall back to
/// the public repo.
protocol CircleTransport: Sendable {
  var publicEndpointCallCount: Int { get async }

  func capabilities() async throws -> CircleCapability
  func listCircles(cursor: String?) async throws -> CircleListPage
  func getFeed(space: SpaceRef?, cursor: String?) async throws -> CircleFeedPage
  func getPostThread(uri: ATProtocolURI, space: SpaceRef) async throws -> CircleThreadPage
  func listNotifications(cursor: String?) async throws -> CircleNotificationPage
  func media(space: SpaceRef, authorDID: DID, cid: CID) async throws -> Data
  func createCircle(name: String, memberDIDs: [DID]) async throws -> CircleOperation
  func updateMember(space: SpaceRef, memberDID: DID, action: CircleMemberAction) async throws -> CircleOperation
  func updatePreferences(space: SpaceRef, muted: Bool) async throws -> Bool
  func report(post: ATProtocolURI, circle: CircleSummary, reason: CircleReportReason, details: String?) async throws -> UUID
  func activate(space: SpaceRef) async throws -> CircleAccessState
  func publishPost(destination: CircleSummary, draft: CirclePostDraft) async throws -> ATProtocolURI
  func like(post: AppBskyFeedDefs.PostView, circle: CircleSummary) async throws -> ATProtocolURI
  func deletePost(uri: ATProtocolURI, circle: CircleSummary) async throws
  func deleteLike(uri: ATProtocolURI, circle: CircleSummary) async throws
  func deleteCircle(space: SpaceRef) async throws -> CircleOperation
  func getOperation(id: String) async throws -> CircleOperation
  func retryOperation(id: String) async throws -> CircleOperation
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
    case "UpstreamUnavailable": return .upstreamUnavailable
    default: break
    }
  }

  if let xrpc = error as? ATProtoXRPCError {
    switch xrpc.error {
    case "AuthRequired": return .authRequired
    case "AccessRemoved": return .accessRemoved
    case "UnsupportedPDS": return .unsupportedPDS
    case "ProtocolRevisionMismatch": return .protocolRevisionMismatch
    case "UpstreamUnavailable": return .upstreamUnavailable
    default: break
    }
  }

  return .networkError(error.localizedDescription)
}

extension Notification.Name {
  /// Posted when a Circle's mute state is updated.
  /// `userInfo` contains `accountDID` (String) and `spaceURI` (String).
  static let circleMuteStateChanged = Notification.Name("CircleMuteStateChanged")
}
