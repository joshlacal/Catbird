//
//  KeyPackageBatchResult.swift
//  Catbird
//
//  Created by Claude Code
//

import Foundation

/// Result from batch key package upload operation
struct KeyPackageBatchResult: Codable, Sendable {
  /// Number of packages successfully uploaded
  let succeeded: Int

  /// Number of packages that failed to upload
  let failed: Int

  /// Individual error details (if any)
  let errors: [BatchUploadError]?

  init(succeeded: Int, failed: Int, errors: [BatchUploadError]? = nil) {
    self.succeeded = succeeded
    self.failed = failed
    self.errors = errors
  }

  /// Total number of packages in the batch
  var total: Int {
    succeeded + failed
  }

  /// Whether the batch was completely successful
  var isFullSuccess: Bool {
    failed == 0
  }

  /// Whether the batch was completely failed
  var isFullFailure: Bool {
    succeeded == 0
  }

  /// Success rate as percentage
  var successRate: Double {
    guard total > 0 else { return 0.0 }
    return Double(succeeded) / Double(total)
  }
}

/// Error details for individual package upload in batch
struct BatchUploadError: Codable, Sendable {
  /// Index of the package in the batch that failed
  let index: Int

  /// Error message
  let error: String

  /// Optional error code
  let code: String?

  init(index: Int, error: String, code: String? = nil) {
    self.index = index
    self.error = error
    self.code = code
  }
}

/// Data structure for individual key package in batch upload
/// Note: Renamed from KeyPackageData to avoid conflict with uniffi-generated type in MLSFFI.swift
struct MLSKeyPackageUploadData: Codable, Sendable {
  /// Base64-encoded key package bytes (TLS serialized)
  let keyPackage: String

  /// Cipher suite identifier
  let cipherSuite: String

  /// Expiration timestamp
  let expires: Date?

  /// Idempotency key for deduplication
  let idempotencyKey: String

  /// Device ID for multi-device support
  let deviceId: String?

  /// Credential DID (did:plc:user#device-uuid) for multi-device support
  let credentialDid: String?

  init(
    keyPackage: String,
    cipherSuite: String = "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
    expires: Date? = nil,
    idempotencyKey: String = UUID().uuidString,
    deviceId: String? = nil,
    credentialDid: String? = nil
  ) {
    self.keyPackage = keyPackage
    self.cipherSuite = cipherSuite
    self.expires = expires
    self.idempotencyKey = idempotencyKey
    self.deviceId = deviceId
    self.credentialDid = credentialDid
  }
}

/// Request payload for batch key package upload
struct KeyPackageBatchUploadRequest: Codable, Sendable {
  /// Array of key packages to upload
  let keyPackages: [MLSKeyPackageUploadData]

  init(keyPackages: [MLSKeyPackageUploadData]) {
    self.keyPackages = keyPackages
  }
}
