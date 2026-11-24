import Foundation
import OSLog
import Petrel

/// What account deletion needs from the account's PDS to remove its Circles.
protocol CircleAccountErasureTransport: Sendable {
  /// The Circle space types this session was granted scopes for, or `nil`
  /// when the session cannot say (every type is then attempted).
  func grantedSpaceTypes() async throws -> Set<String>?
  /// One page of the spaces this account has written to or is the authority
  /// for, of one space type.
  func listSpaces(spaceType: String, cursor: String?) async throws -> (spaces: [SpaceRef], cursor: String?)
  /// Deletes a space this account is the authority for, with its repo.
  /// A space that is already gone counts as deleted.
  func deleteSpace(_ space: SpaceRef) async throws
  /// Deletes every record this account wrote into someone else's space.
  func clearRecords(space: SpaceRef, repo: String) async throws
}

/// What one Circles erasure pass did. Used for logging and tests; account
/// deletion never fails because of it.
struct CircleAccountErasureReport: Equatable, Sendable {
  /// Circles the account owned, deleted for every member.
  var deletedSpaces: [String] = []
  /// Other owners' Circles the account's own posts and likes were cleared from.
  var clearedSpaces: [String] = []
  /// Space types skipped because the session has no scope for them.
  var skippedSpaceTypes: [String] = []
  /// The PDS does not offer Spaces at all, so there was nothing to remove.
  var unsupported = false
  /// Space URIs or space types where a step failed.
  var failures: [String] = []
}

/// Removes an account's Circles data from its PDS before the account itself
/// is deleted, while the session is still live.
///
/// - Circles the account owns are deleted (`com.atproto.space.deleteSpace`),
///   which removes them for every member. There is no ownership transfer.
/// - In other owners' Circles, the account's own records are cleared
///   (`com.atproto.space.clearRecords`). Its entry on the owner's member list
///   stays: only the owner can change that list.
///
/// Best effort by design. Deleting the PDS account destroys the same data a
/// moment later, and the Circle AppView purges its copy when it confirms the
/// deletion, so a failure here is logged and never blocks account deletion.
/// Doing it first only makes the removal reach other members promptly.
enum CircleAccountErasure {
  static let spaceTypes = [CircleConfiguration.spaceType, CircleConfiguration.encryptedSpaceType]
  /// Upper bound on listSpaces pages per space type (100 spaces each).
  static let maximumPages = 50

  private static let logger = Logger(subsystem: "blue.catbird", category: "CircleAccountErasure")

  @discardableResult
  static func run(
    accountDID: String,
    transport: any CircleAccountErasureTransport
  ) async -> CircleAccountErasureReport {
    var report = CircleAccountErasureReport()
    // A scope lookup that fails says nothing about the grant; try every type.
    let granted: Set<String>? = (try? await transport.grantedSpaceTypes()) ?? nil

    for spaceType in spaceTypes {
      if let granted, !granted.contains(spaceType) {
        report.skippedSpaceTypes.append(spaceType)
        continue
      }
      var cursor: String?
      var pages = 0
      repeat {
        let page: (spaces: [SpaceRef], cursor: String?)
        do {
          page = try await transport.listSpaces(spaceType: spaceType, cursor: cursor)
        } catch {
          if GatewayCircleTransport.isUnsupportedSpacesError(error) {
            report.unsupported = true
            logger.info("PDS has no Spaces support; no Circles data to remove")
            return report
          }
          logger.error("Listing \(spaceType, privacy: .public) Circles failed: \(error.localizedDescription, privacy: .public)")
          report.failures.append(spaceType)
          break
        }
        for space in page.spaces where space.spaceType == spaceType {
          let uri = space.uriString()
          do {
            if space.spaceDID == accountDID {
              try await transport.deleteSpace(space)
              report.deletedSpaces.append(uri)
            } else {
              try await transport.clearRecords(space: space, repo: accountDID)
              report.clearedSpaces.append(uri)
            }
          } catch {
            logger.error("Removing Circles data failed for one space: \(error.localizedDescription, privacy: .public)")
            report.failures.append(uri)
          }
        }
        cursor = page.cursor
        pages += 1
      } while cursor != nil && pages < maximumPages
    }

    logger.info(
      "Circles erasure: \(report.deletedSpaces.count) owned deleted, \(report.clearedSpaces.count) cleared, \(report.failures.count) failed"
    )
    return report
  }

  /// Whether a granted OAuth scope covers `spaceType`. Scopes look like
  /// `space:<type>?action=…`; the gateway normalizes the parameters, so only
  /// the resource part is compared.
  static func grantedSpaceTypes(fromScopes scopes: Set<String>) -> Set<String> {
    Set(spaceTypes.filter { spaceType in
      scopes.contains { scope in
        scope.split(separator: "?", maxSplits: 1).first.map(String.init) == "space:\(spaceType)"
      }
    })
  }
}

/// `CircleAccountErasureTransport` over the account's own Petrel client.
struct PetrelCircleAccountErasureTransport: CircleAccountErasureTransport {
  let client: ATProtoClient
  let accountDID: String

  func grantedSpaceTypes() async throws -> Set<String>? {
    // Only the confidential gateway session reports its grant; other auth
    // strategies throw, which means "unknown", not "none".
    guard let scopes = try? await client.fetchGrantedScopes(for: accountDID) else { return nil }
    return CircleAccountErasure.grantedSpaceTypes(fromScopes: scopes)
  }

  func listSpaces(spaceType: String, cursor: String?) async throws -> (spaces: [SpaceRef], cursor: String?) {
    let (status, output) = try await client.com.atproto.space.listSpaces(
      input: ComAtprotoSpaceListSpaces.Parameters(
        spaceType: try NSID(nsidString: spaceType),
        limit: 100,
        cursor: cursor
      )
    )
    guard status == 200, let output else { throw CircleError.invalidResponse }
    return (output.spaces.map(\.space), output.cursor)
  }

  func deleteSpace(_ space: SpaceRef) async throws {
    do {
      _ = try await client.com.atproto.space.deleteSpace(
        input: ComAtprotoSpaceDeleteSpace.Input(space: space)
      )
    } catch let error as ATProtoError<ComAtprotoSpaceDeleteSpace.Error> where error.error == .spaceNotFound {
      return
    }
  }

  func clearRecords(space: SpaceRef, repo: String) async throws {
    let (status, _) = try await client.com.atproto.space.clearRecords(
      input: ComAtprotoSpaceClearRecords.Input(space: space, repo: try DID(didString: repo))
    )
    guard (200...299).contains(status) else { throw CircleError.invalidResponse }
  }
}
