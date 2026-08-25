import Foundation
import Petrel
import PetrelCatbird

/// The single immutable audience for a Circle-capable post.
///
/// A post targets exactly one destination: Public or one named Circle. No
/// failure may retry against the public repo, so the destination is decided
/// once and carried unchanged through submission.
enum CircleDestination: Equatable, Sendable {
  case `public`
  case circle(CircleSummary)
}

/// Access state of a Circle Space, surfaced as an explicit transition rather
/// than being inferred from URI shape in rendering code.
enum CircleAccessState: String, Sendable {
  case active
  case expired
  case removed
  case unsupported
}

/// A single page of hydrated Circle feed items. Circle identity lives beside
/// every hydrated post; consumers never infer privacy from URI shape.
struct CircleFeedPage: Sendable {
  let items: [BlueCatbirdCircleDefs.FeedItem]
  let cursor: String?
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
  let langs: [LanguageCodeContainer]
  let labels: AppBskyFeedPost.AppBskyFeedPostLabelsUnion?
  let embed: AppBskyFeedPost.AppBskyFeedPostEmbedUnion?
  let createdAt: ATProtocolDate

  init(
    text: String,
    facets: [AppBskyRichtextFacet]? = nil,
    langs: [LanguageCodeContainer] = [],
    labels: AppBskyFeedPost.AppBskyFeedPostLabelsUnion? = nil,
    embed: AppBskyFeedPost.AppBskyFeedPostEmbedUnion? = nil,
    createdAt: ATProtocolDate = ATProtocolDate(date: Date())
  ) {
    self.text = text
    self.facets = facets
    self.langs = langs
    self.labels = labels
    self.embed = embed
    self.createdAt = createdAt
  }
}

/// Errors raised by the Circle transport. These remain Circle-scoped and are
/// never swallowed or redirected to the public path.
enum CircleError: Error, LocalizedError {
  case upstreamUnavailable
  case accessRemoved
  case accessExpired
  case unsupportedPDS
  case protocolRevisionMismatch
  case authRequired
  case clientNotInitialized
  case invalidResponse
  case networkError(Error)
  case spaceWriteRejected(String)

  var errorDescription: String? {
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
    case .networkError(let error):
      return "Network error: \(error.localizedDescription)"
    case .spaceWriteRejected(let message):
      return "Circle write rejected: \(message)"
    }
  }
}

/// The narrow network seam used by `CircleService`. Production uses
/// `GatewayCircleTransport`; tests use a recording double. Public writes and
/// reads never appear on this seam, so a Circle failure cannot fall back to
/// the public repo.
protocol CircleTransport: Sendable {
  var publicEndpointCallCount: Int { get }

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

  return .networkError(error)
}
