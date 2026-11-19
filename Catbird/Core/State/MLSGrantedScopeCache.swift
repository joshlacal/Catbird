import Foundation
import OSLog

/// The OAuth scopes the gateway last reported for an account's session, kept so encrypted
/// chat can still be checked when the gateway cannot be reached.
///
/// Only a real gateway answer is ever stored here. The key differs from the retired
/// `blue.catbird.oauth.scopes.<did>`, which held the scopes chat needs rather than the scopes
/// the session holds, so a value left under the old key is never read as a grant.
enum MLSGrantedScopeCache {
  static func key(for did: String) -> String {
    "blue.catbird.oauth.grantedScopes.\(did.lowercased())"
  }

  /// The last gateway answer for `did`, or `nil` when the gateway has never answered.
  static func load(for did: String, defaults: UserDefaults) -> [String]? {
    guard let stored = defaults.stringArray(forKey: key(for: did)), !stored.isEmpty else {
      return nil
    }
    return stored
  }

  static func store(_ scopes: Set<String>, for did: String, defaults: UserDefaults) {
    defaults.set(scopes.sorted(), forKey: key(for: did))
  }
}

/// Answers "which scopes does this session hold" without asking the gateway every time.
///
/// Encrypted chat re-checks its eligibility often, in bursts of about one check a second,
/// and the gateway's session endpoint sits behind its sign-in rate limit. Asking on every
/// check exhausts that limit within seconds and then blocks the permission request itself.
/// So one answer is kept for `freshness`, concurrent checks share one request, and after a
/// failed request the gateway is left alone for `retryAfterFailure`.
@MainActor
final class MLSGrantedScopeResolver {
  /// How long a gateway answer is reused. A session's scopes change only through a
  /// permission upgrade, which records its result here, or a new sign-in.
  static let freshness: TimeInterval = 5 * 60
  /// How long to wait after a failed request before asking again.
  static let retryAfterFailure: TimeInterval = 30

  private var answer: (scopes: [String], at: Date)?
  private var lastFailure: Date?
  private var inFlight: Task<[String]?, Never>?
  private let logger = Logger(subsystem: "blue.catbird", category: "MLSGrantedScopes")

  nonisolated init() {}

  /// The gateway's answer: the kept one while it is fresh, otherwise a new one. When the
  /// gateway cannot be asked or does not answer, the last answer it gave, or `nil` if it
  /// has never answered.
  func gatewayScopes(
    now: Date = Date(),
    fetch: @escaping @MainActor () async throws -> Set<String>
  ) async -> [String]? {
    if let answer, now.timeIntervalSince(answer.at) < Self.freshness {
      return answer.scopes
    }
    if let lastFailure, now.timeIntervalSince(lastFailure) < Self.retryAfterFailure {
      return answer?.scopes
    }
    if let inFlight {
      return await inFlight.value ?? answer?.scopes
    }
    let logger = self.logger
    let task = Task { @MainActor () -> [String]? in
      do {
        return try await fetch().sorted()
      } catch {
        logger.warning("Could not read granted OAuth scopes from the gateway: \(error.localizedDescription)")
        return nil
      }
    }
    inFlight = task
    let fetched = await task.value
    inFlight = nil
    guard let fetched else {
      lastFailure = now
      return answer?.scopes
    }
    answer = (fetched, now)
    lastFailure = nil
    return fetched
  }

  /// Records an answer obtained another way: a completed permission upgrade returns the
  /// session's new scopes.
  func record(_ scopes: Set<String>, now: Date = Date()) {
    answer = (scopes.sorted(), now)
    lastFailure = nil
  }
}
