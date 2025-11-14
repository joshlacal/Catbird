//
//  MLSSQLCipherError.swift
//  Catbird
//
//  Production-ready error types for SQLCipher MLS storage
//

import Foundation

/// Comprehensive error types for SQLCipher operations
enum MLSSQLCipherError: Error, LocalizedError, CustomStringConvertible {
  // MARK: - Database Errors

  /// Database file could not be created or opened
  case databaseCreationFailed(underlying: Error)

  /// Database is corrupted and cannot be recovered
  case databaseCorrupted(details: String)

  /// Database encryption key is invalid or missing
  case invalidEncryptionKey(reason: String)

  /// Database is locked by another process
  case databaseLocked

  /// Database schema version mismatch
  case schemaVersionMismatch(expected: Int, found: Int)

  // MARK: - Query Errors

  /// SQL query execution failed
  case queryExecutionFailed(query: String, underlying: Error)

  /// SQL query returned unexpected result
  case unexpectedQueryResult(details: String)

  /// Required record not found
  case recordNotFound(entityType: String, id: String)

  /// Duplicate record violation
  case duplicateRecord(entityType: String, id: String)

  /// Foreign key constraint violation
  case foreignKeyViolation(details: String)

  // MARK: - Transaction Errors

  /// Transaction could not be started
  case transactionBeginFailed(underlying: Error)

  /// Transaction commit failed
  case transactionCommitFailed(underlying: Error)

  /// Transaction rollback failed
  case transactionRollbackFailed(underlying: Error)

  // MARK: - Encryption Errors

  /// Keychain access failed
  case keychainAccessFailed(operation: String, status: OSStatus)

  /// Encryption key generation failed
  case keyGenerationFailed

  /// Database re-encryption failed
  case reEncryptionFailed(underlying: Error)

  /// Encryption verification failed
  case encryptionVerificationFailed

  // MARK: - Data Errors

  /// Data serialization failed
  case serializationFailed(type: String, underlying: Error?)

  /// Data deserialization failed
  case deserializationFailed(type: String, underlying: Error?)

  /// Invalid data format
  case invalidDataFormat(field: String, expected: String)

  // MARK: - File System Errors

  /// Database directory creation failed
  case directoryCreationFailed(path: String, underlying: Error)

  /// File protection could not be set
  case fileProtectionFailed(underlying: Error)

  /// Database file could not be excluded from backup
  case backupExclusionFailed(underlying: Error)

  // MARK: - Concurrency Errors

  /// Operation was cancelled
  case operationCancelled

  /// Concurrent access violation detected
  case concurrentAccessViolation(details: String)

  // MARK: - Validation Errors

  /// Input validation failed
  case validationFailed(field: String, reason: String)

  /// Required parameter missing
  case missingRequiredParameter(name: String)

  // MARK: - LocalizedError Conformance

  var errorDescription: String? {
    description
  }

  var failureReason: String? {
    switch self {
    case .databaseCreationFailed:
      return "Failed to create or open the database"
    case .databaseCorrupted:
      return "Database is corrupted"
    case .invalidEncryptionKey:
      return "Invalid encryption key"
    case .databaseLocked:
      return "Database is locked"
    case .schemaVersionMismatch:
      return "Schema version mismatch"
    case .queryExecutionFailed:
      return "Query execution failed"
    case .unexpectedQueryResult:
      return "Unexpected query result"
    case .recordNotFound:
      return "Record not found"
    case .duplicateRecord:
      return "Duplicate record"
    case .foreignKeyViolation:
      return "Foreign key constraint violated"
    case .transactionBeginFailed:
      return "Transaction begin failed"
    case .transactionCommitFailed:
      return "Transaction commit failed"
    case .transactionRollbackFailed:
      return "Transaction rollback failed"
    case .keychainAccessFailed:
      return "Keychain access failed"
    case .keyGenerationFailed:
      return "Key generation failed"
    case .reEncryptionFailed:
      return "Re-encryption failed"
    case .encryptionVerificationFailed:
      return "Encryption verification failed"
    case .serializationFailed:
      return "Serialization failed"
    case .deserializationFailed:
      return "Deserialization failed"
    case .invalidDataFormat:
      return "Invalid data format"
    case .directoryCreationFailed:
      return "Directory creation failed"
    case .fileProtectionFailed:
      return "File protection failed"
    case .backupExclusionFailed:
      return "Backup exclusion failed"
    case .operationCancelled:
      return "Operation cancelled"
    case .concurrentAccessViolation:
      return "Concurrent access violation"
    case .validationFailed:
      return "Validation failed"
    case .missingRequiredParameter:
      return "Missing required parameter"
    }
  }

  var recoverySuggestion: String? {
    switch self {
    case .databaseCreationFailed, .databaseCorrupted:
      return "Try deleting the database and starting fresh. Your encrypted messages will be lost."
    case .invalidEncryptionKey:
      return "Check that the encryption key is properly stored in Keychain."
    case .databaseLocked:
      return "Close other connections to the database and retry."
    case .schemaVersionMismatch:
      return "Database schema needs migration. Contact support."
    case .queryExecutionFailed:
      return "Check the query syntax and parameters."
    case .recordNotFound:
      return "The requested record may have been deleted."
    case .duplicateRecord:
      return "A record with this identifier already exists."
    case .foreignKeyViolation:
      return "Ensure related records exist before creating this record."
    case .keychainAccessFailed:
      return "Check device is unlocked and Keychain is accessible."
    case .keyGenerationFailed:
      return "Ensure device security settings allow key generation."
    case .encryptionVerificationFailed:
      return "Database encryption may be compromised. Consider re-encrypting."
    case .serializationFailed, .deserializationFailed:
      return "Data format may be incompatible. Check for app updates."
    case .directoryCreationFailed:
      return "Check app permissions and available storage."
    case .fileProtectionFailed:
      return "Ensure device has Data Protection enabled."
    case .backupExclusionFailed:
      return "Check system backup settings."
    case .operationCancelled:
      return "Retry the operation."
    case .concurrentAccessViolation:
      return "Ensure proper synchronization between threads."
    case .validationFailed:
      return "Check input parameters and try again."
    case .missingRequiredParameter:
      return "Provide the required parameter."
    default:
      return nil
    }
  }

  // MARK: - CustomStringConvertible

  var description: String {
    switch self {
    case .databaseCreationFailed(let error):
      return "Database creation failed: \(error.localizedDescription)"
    case .databaseCorrupted(let details):
      return "Database corrupted: \(details)"
    case .invalidEncryptionKey(let reason):
      return "Invalid encryption key: \(reason)"
    case .databaseLocked:
      return "Database is locked by another process"
    case .schemaVersionMismatch(let expected, let found):
      return "Schema version mismatch: expected \(expected), found \(found)"
    case .queryExecutionFailed(let query, let error):
      return "Query execution failed: \(query.prefix(100)) - \(error.localizedDescription)"
    case .unexpectedQueryResult(let details):
      return "Unexpected query result: \(details)"
    case .recordNotFound(let entityType, let id):
      return "Record not found: \(entityType) with id \(id)"
    case .duplicateRecord(let entityType, let id):
      return "Duplicate record: \(entityType) with id \(id)"
    case .foreignKeyViolation(let details):
      return "Foreign key violation: \(details)"
    case .transactionBeginFailed(let error):
      return "Transaction begin failed: \(error.localizedDescription)"
    case .transactionCommitFailed(let error):
      return "Transaction commit failed: \(error.localizedDescription)"
    case .transactionRollbackFailed(let error):
      return "Transaction rollback failed: \(error.localizedDescription)"
    case .keychainAccessFailed(let operation, let status):
      return "Keychain \(operation) failed with status: \(status)"
    case .keyGenerationFailed:
      return "Failed to generate encryption key"
    case .reEncryptionFailed(let error):
      return "Database re-encryption failed: \(error.localizedDescription)"
    case .encryptionVerificationFailed:
      return "Failed to verify database encryption"
    case .serializationFailed(let type, let error):
      return "Serialization failed for \(type): \(error?.localizedDescription ?? "unknown error")"
    case .deserializationFailed(let type, let error):
      return "Deserialization failed for \(type): \(error?.localizedDescription ?? "unknown error")"
    case .invalidDataFormat(let field, let expected):
      return "Invalid data format for \(field): expected \(expected)"
    case .directoryCreationFailed(let path, let error):
      return "Directory creation failed at \(path): \(error.localizedDescription)"
    case .fileProtectionFailed(let error):
      return "File protection failed: \(error.localizedDescription)"
    case .backupExclusionFailed(let error):
      return "Backup exclusion failed: \(error.localizedDescription)"
    case .operationCancelled:
      return "Operation was cancelled"
    case .concurrentAccessViolation(let details):
      return "Concurrent access violation: \(details)"
    case .validationFailed(let field, let reason):
      return "Validation failed for \(field): \(reason)"
    case .missingRequiredParameter(let name):
      return "Missing required parameter: \(name)"
    }
  }
}

// MARK: - Error Conversion Helpers

extension MLSSQLCipherError {
  /// Convert SQLite.swift Result error to MLSSQLCipherError
  static func from(sqliteError: Error, query: String? = nil) -> MLSSQLCipherError {
    let errorString = sqliteError.localizedDescription

    // Parse common SQLite error messages
    if errorString.contains("locked") {
      return .databaseLocked
    } else if errorString.contains("corrupt") {
      return .databaseCorrupted(details: errorString)
    } else if errorString.contains("UNIQUE constraint") {
      return .duplicateRecord(entityType: "Unknown", id: "Unknown")
    } else if errorString.contains("FOREIGN KEY constraint") {
      return .foreignKeyViolation(details: errorString)
    } else if let query = query {
      return .queryExecutionFailed(query: query, underlying: sqliteError)
    } else {
      return .queryExecutionFailed(query: "Unknown query", underlying: sqliteError)
    }
  }
}
