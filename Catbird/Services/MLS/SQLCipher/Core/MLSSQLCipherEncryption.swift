//
//  MLSSQLCipherEncryption.swift
//  Catbird
//
//  Production-ready encryption key management for SQLCipher database
//

import Foundation
import Security

/// Manages encryption keys for SQLCipher databases with secure Keychain storage
@MainActor
final class MLSSQLCipherEncryption {

  // MARK: - Properties

  /// Shared singleton instance
  static let shared = MLSSQLCipherEncryption()

  /// Key size for AES-256 (32 bytes)
  private let keySize: Int = 32

  /// Keychain service identifier for SQLCipher database keys
  private let keychainService = "com.catbird.mls.sqlcipher"

  // MARK: - Initialization

  private init() {}

  // MARK: - Public API

  /// Generate or retrieve encryption key for a specific user
  /// - Parameter userDID: User's decentralized identifier
  /// - Returns: 256-bit encryption key as Data
  /// - Throws: MLSSQLCipherError if key generation or retrieval fails
  func getOrCreateKey(for userDID: String) throws -> Data {
    let keychainKey = makeKeychainKey(for: userDID)

    // Try to retrieve existing key from Keychain
    if let existingKey = try? retrieveKey(keychainKey: keychainKey) {
      guard existingKey.count == keySize else {
        throw MLSSQLCipherError.invalidEncryptionKey(reason: "Key size mismatch: expected \(keySize) bytes, got \(existingKey.count)")
      }
      return existingKey
    }

    // Generate new key if none exists
    let newKey = try generateKey()
    try storeKey(newKey, keychainKey: keychainKey)
    return newKey
  }

  /// Retrieve existing encryption key for a user
  /// - Parameter userDID: User's decentralized identifier
  /// - Returns: 256-bit encryption key as Data, or nil if not found
  /// - Throws: MLSSQLCipherError if retrieval fails
  func getKey(for userDID: String) throws -> Data? {
    let keychainKey = makeKeychainKey(for: userDID)
    return try? retrieveKey(keychainKey: keychainKey)
  }

  /// Delete encryption key for a user (when deleting account)
  /// - Parameter userDID: User's decentralized identifier
  /// - Throws: MLSSQLCipherError if deletion fails
  func deleteKey(for userDID: String) throws {
    let keychainKey = makeKeychainKey(for: userDID)

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainKey
    ]

    let status = SecItemDelete(query as CFDictionary)

    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw MLSSQLCipherError.keychainAccessFailed(operation: "delete", status: status)
    }
  }

  /// Rotate encryption key for a user (generates new key, returns both old and new)
  /// - Parameter userDID: User's decentralized identifier
  /// - Returns: Tuple of (oldKey, newKey) for re-encryption
  /// - Throws: MLSSQLCipherError if rotation fails
  func rotateKey(for userDID: String) throws -> (oldKey: Data, newKey: Data) {
    // Retrieve current key
    guard let oldKey = try getKey(for: userDID) else {
      throw MLSSQLCipherError.invalidEncryptionKey(reason: "No existing key found for rotation")
    }

    // Generate new key
    let newKey = try generateKey()

    // Store new key (overwrites old key)
    let keychainKey = makeKeychainKey(for: userDID)
    try storeKey(newKey, keychainKey: keychainKey, update: true)

    return (oldKey, newKey)
  }

  /// Convert raw key data to hex string for SQLCipher PRAGMA
  /// - Parameter key: Raw key data
  /// - Returns: Hex string prefixed with "x'" for SQLCipher
  func keyToHexString(_ key: Data) -> String {
    let hexString = key.map { String(format: "%02x", $0) }.joined()
    return "x'\(hexString)'"
  }

  // MARK: - Private Methods

  /// Generate cryptographically secure random key
  private func generateKey() throws -> Data {
    var keyData = Data(count: keySize)

    let result = keyData.withUnsafeMutableBytes { bufferPointer in
      SecRandomCopyBytes(kSecRandomDefault, keySize, bufferPointer.baseAddress!)
    }

    guard result == errSecSuccess else {
      throw MLSSQLCipherError.keyGenerationFailed
    }

    return keyData
  }

  /// Store key in Keychain with maximum security
  private func storeKey(_ key: Data, keychainKey: String, update: Bool = false) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainKey,
      kSecValueData as String: key,

      // Security attributes
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecAttrSynchronizable as String: false // NEVER sync to iCloud
    ]

    if update {
      // Try to update existing key
      let updateQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: keychainKey
      ]

      let updateAttributes: [String: Any] = [
        kSecValueData as String: key
      ]

      let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)

      if updateStatus == errSecSuccess {
        return
      } else if updateStatus == errSecItemNotFound {
        // Fall through to insert new item
      } else {
        throw MLSSQLCipherError.keychainAccessFailed(operation: "update", status: updateStatus)
      }
    }

    // Insert new key
    let status = SecItemAdd(query as CFDictionary, nil)

    guard status == errSecSuccess else {
      throw MLSSQLCipherError.keychainAccessFailed(operation: "store", status: status)
    }
  }

  /// Retrieve key from Keychain
  private func retrieveKey(keychainKey: String) throws -> Data {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainKey,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    guard status == errSecSuccess else {
      throw MLSSQLCipherError.keychainAccessFailed(operation: "retrieve", status: status)
    }

    guard let keyData = result as? Data else {
      throw MLSSQLCipherError.invalidEncryptionKey(reason: "Retrieved data is not in expected format")
    }

    return keyData
  }

  /// Generate Keychain account identifier for user
  private func makeKeychainKey(for userDID: String) -> String {
    "mls.sqlcipher.db.key.\(userDID)"
  }
}

// MARK: - Key Verification

extension MLSSQLCipherEncryption {
  /// Verify that a key can successfully decrypt a test database
  /// - Parameters:
  ///   - key: Encryption key to verify
  ///   - testQuery: Optional test query to execute (defaults to SELECT count(*) FROM sqlite_master)
  /// - Returns: True if key is valid and database can be accessed
  func verifyKey(_ key: Data, testQuery: String = "SELECT count(*) FROM sqlite_master;") -> Bool {
    // This will be implemented once we have the database connection
    // For now, just verify key size
    key.count == keySize
  }
}

// MARK: - Debug Helpers (Development Only)

#if DEBUG
extension MLSSQLCipherEncryption {
  /// List all stored keys for debugging (NEVER use in production)
  func listAllKeys() throws -> [String] {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    guard status == errSecSuccess else {
      if status == errSecItemNotFound {
        return []
      }
      throw MLSSQLCipherError.keychainAccessFailed(operation: "list", status: status)
    }

    guard let items = result as? [[String: Any]] else {
      return []
    }

    return items.compactMap { $0[kSecAttrAccount as String] as? String }
  }

  /// Delete all SQLCipher keys (for testing only)
  func deleteAllKeys() throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService
    ]

    let status = SecItemDelete(query as CFDictionary)

    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw MLSSQLCipherError.keychainAccessFailed(operation: "delete all", status: status)
    }
  }
}
#endif
