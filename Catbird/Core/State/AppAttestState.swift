import Foundation

/// Stores the most recently issued server challenge for App Attest assertions.
struct AppAttestChallenge: Codable, Equatable {
  /// Raw challenge string as supplied by the push service backend.
  let challenge: String

  /// Expiration timestamp provided by the backend, if any.
  let expiresAt: Date?

  /// Indicates whether the stored challenge is expired relative to the current date.
  var isExpired: Bool {
    guard let expiresAt else {
      return false
    }
    // Tolerate a short grace period to avoid race conditions near expiry.
    return Date() >= expiresAt.addingTimeInterval(-30)
  }

  enum CodingKeys: String, CodingKey {
    case challenge
    case expiresAt = "expires_at"
  }
}

/// Persisted App Attest metadata that accompanies push registration calls.
struct AppAttestInfo: Codable, Equatable {
  /// Identifier returned by `DCAppAttestService.generateKey()` for this device.
  let keyIdentifier: String

  /// Latest server-provided challenge, reused until rotation.
  var latestChallenge: AppAttestChallenge?
}
