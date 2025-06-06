import Foundation
import Petrel

// Forward declaration removed - SafetyMonitor is defined in MigrationSafetyService.swift

// MARK: - Migration Operation

/// Represents an active migration operation with all its state and progress
@Observable
final class MigrationOperation: Identifiable {
  let id: UUID
  let sourceServer: ServerConfiguration
  let destinationServer: ServerConfiguration
  let options: MigrationOptions
  let createdAt: Date
  
  // Progress tracking
  private(set) var status: MigrationStatus = .preparing
  private(set) var currentPhase: String = "Initializing"
  private(set) var progress: Double = 0.0
  
  // Safety monitoring
  weak var safetyMonitor: AnyObject? // Type-erased reference to SafetyMonitor
  
  // Authentication
  var destinationAuthURL: URL?
  
  // Data tracking
  var preMigrationBackupId: UUID?
  var exportedDataPath: String?
  var exportedDataSize: Int = 0
  var destinationDID: String?
  var estimatedDataSize: Int = 0
  
  // Validation and verification
  var compatibilityReport: CompatibilityReport?
  var verificationReport: VerificationReport?
  
  // Error handling
  var errorMessage: String?
  var completedAt: Date?
  
  init(
    id: UUID = UUID(),
    sourceServer: ServerConfiguration,
    destinationServer: ServerConfiguration,
    options: MigrationOptions,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.sourceServer = sourceServer
    self.destinationServer = destinationServer
    self.options = options
    self.createdAt = createdAt
  }
  
  func updateStatus(_ newStatus: MigrationStatus) {
    status = newStatus
    currentPhase = newStatus.description
    progress = newStatus.progressPercentage
    
    // Notify safety monitor of status change
    // Using performSelector since we have type-erased reference
    _ = safetyMonitor?.perform(NSSelectorFromString("notifyStatusChange"))
  }
  
  func updateProgress(_ newProgress: Double, phase: String) {
    progress = newProgress
    currentPhase = phase
    
    // Notify safety monitor of progress change (which counts as activity)
    // Using performSelector since we have type-erased reference
    _ = safetyMonitor?.perform(NSSelectorFromString("notifyStatusChange"))
  }
}

// MARK: - Migration Status

enum MigrationStatus: String, CaseIterable, Codable {
  case preparing = "preparing"
  case preparingBackup = "preparing_backup"
  case authenticating = "authenticating"
  case validating = "validating"
  case exporting = "exporting"
  case importing = "importing"
  case verifying = "verifying"
  case completed = "completed"
  case failed = "failed"
  case cancelled = "cancelled"
  
  var description: String {
    switch self {
    case .preparing:
      return "Preparing Migration"
    case .preparingBackup:
      return "Creating Backup"
    case .authenticating:
      return "Authenticating"
    case .validating:
      return "Validating Compatibility"
    case .exporting:
      return "Exporting Data"
    case .importing:
      return "Importing Data"
    case .verifying:
      return "Verifying Migration"
    case .completed:
      return "Migration Complete"
    case .failed:
      return "Migration Failed"
    case .cancelled:
      return "Migration Cancelled"
    }
  }
  
  var progressPercentage: Double {
    switch self {
    case .preparing:
      return 0.05
    case .preparingBackup:
      return 0.10
    case .authenticating:
      return 0.20
    case .validating:
      return 0.30
    case .exporting:
      return 0.50
    case .importing:
      return 0.80
    case .verifying:
      return 0.95
    case .completed:
      return 1.00
    case .failed, .cancelled:
      return 0.00
    }
  }
  
  var systemImage: String {
    switch self {
    case .preparing, .preparingBackup:
      return "gear"
    case .authenticating:
      return "lock"
    case .validating:
      return "checkmark.shield"
    case .exporting:
      return "square.and.arrow.up"
    case .importing:
      return "square.and.arrow.down"
    case .verifying:
      return "magnifyingglass"
    case .completed:
      return "checkmark.circle.fill"
    case .failed:
      return "xmark.circle.fill"
    case .cancelled:
      return "stop.circle.fill"
    }
  }
  
  var color: String {
    switch self {
    case .preparing, .preparingBackup, .authenticating, .validating, .exporting, .importing, .verifying:
      return "blue"
    case .completed:
      return "green"
    case .failed:
      return "red"
    case .cancelled:
      return "orange"
    }
  }
}

// MARK: - Migration Options

struct MigrationOptions: Codable {
  // Data selection
  var includeFollows: Bool
  var includeFollowers: Bool
  var includePosts: Bool
  var includeMedia: Bool
  var includeLikes: Bool
  var includeReposts: Bool
  var includeBlocks: Bool
  var includeMutes: Bool
  var includeProfile: Bool
  
  // Migration preferences
  var destinationHandle: String?
  var preserveTimestamps: Bool
  var batchSize: Int
  var skipDuplicates: Bool
  
  // Safety options
  var createBackupBeforeMigration: Bool
  var verifyAfterMigration: Bool
  var enableRollbackOnFailure: Bool
  
  static let `default` = MigrationOptions(
    includeFollows: true,
    includeFollowers: false, // Don't migrate followers (they need to re-follow)
    includePosts: true,
    includeMedia: true,
    includeLikes: true,
    includeReposts: true,
    includeBlocks: true,
    includeMutes: true,
    includeProfile: true,
    destinationHandle: nil,
    preserveTimestamps: true,
    batchSize: 100,
    skipDuplicates: true,
    createBackupBeforeMigration: true,
    verifyAfterMigration: true,
    enableRollbackOnFailure: true
  )
  
  static let minimal = MigrationOptions(
    includeFollows: true,
    includeFollowers: false,
    includePosts: true,
    includeMedia: false,
    includeLikes: false,
    includeReposts: false,
    includeBlocks: true,
    includeMutes: true,
    includeProfile: true,
    destinationHandle: nil,
    preserveTimestamps: true,
    batchSize: 50,
    skipDuplicates: true,
    createBackupBeforeMigration: true,
    verifyAfterMigration: true,
    enableRollbackOnFailure: true
  )
}

// MARK: - Server Configuration

struct ServerConfiguration: Codable, Identifiable {
  let id: UUID
  let hostname: String
  let displayName: String
  let description: String?
  let version: String?
  let capabilities: [String]
  let rateLimit: RateLimit?
  let maxAccountSize: Int?
  let supportsMigration: Bool
  
  static let bskyOfficial = ServerConfiguration(
    id: UUID(),
    hostname: "bsky.social",
    displayName: "Bluesky Official",
    description: "Official Bluesky AT Protocol instance",
    version: "0.3.0",
    capabilities: ["posts", "follows", "media", "chat"],
    rateLimit: RateLimit(requestsPerMinute: 3000, dataPerHour: 1024 * 1024 * 100),
    maxAccountSize: 1024 * 1024 * 500, // 500MB
    supportsMigration: true
  )
  
  static let customInstance = ServerConfiguration(
    id: UUID(),
    hostname: "atproto.example.com",
    displayName: "Custom Instance",
    description: "Custom AT Protocol instance",
    version: "0.3.0",
    capabilities: ["posts", "follows"],
    rateLimit: RateLimit(requestsPerMinute: 1000, dataPerHour: 1024 * 1024 * 50),
    maxAccountSize: 1024 * 1024 * 100, // 100MB
    supportsMigration: false
  )
}

struct RateLimit: Codable {
  let requestsPerMinute: Int
  let dataPerHour: Int // bytes
}

// MARK: - Compatibility Report

struct CompatibilityReport: Codable {
  let sourceVersion: String
  let destinationVersion: String
  let canProceed: Bool
  let warnings: [String]
  let blockers: [String]
  let recommendedOptions: MigrationOptions?
  let estimatedDuration: TimeInterval
  let riskLevel: RiskLevel
  
  enum RiskLevel: String, Codable {
    case low = "low"
    case medium = "medium"
    case high = "high"
    case critical = "critical"
    
    var color: String {
      switch self {
      case .low: return "green"
      case .medium: return "yellow"
      case .high: return "orange"
      case .critical: return "red"
      }
    }
    
    var systemImage: String {
      switch self {
      case .low: return "checkmark.shield.fill"
      case .medium: return "exclamationmark.shield"
      case .high: return "exclamationmark.triangle.fill"
      case .critical: return "xmark.shield.fill"
      }
    }
  }
}

// MARK: - Verification Report

struct VerificationReport: Codable {
  let overallSuccess: Bool
  let successRate: Double
  let itemsVerified: Int
  let itemsSuccessful: Int
  let itemsFailed: Int
  let failures: [VerificationFailure]
  let warnings: [String]
  let verifiedAt: Date
  
  struct VerificationFailure: Codable {
    let item: String
    let expected: String
    let actual: String
    let severity: Severity
    
    enum Severity: String, Codable {
      case minor = "minor"
      case major = "major"
      case critical = "critical"
    }
  }
}

// MARK: - Migration Record

struct MigrationRecord: Codable, Identifiable {
  let id: UUID
  let sourceServer: String
  let destinationServer: String
  let migratedAt: Date
  let status: MigrationStatus
  let dataSize: Int
  let verificationScore: Double
  let errorMessage: String?
  
  var formattedDataSize: String {
    ByteCountFormatter().string(fromByteCount: Int64(dataSize))
  }
  
  var ageDescription: String {
    let formatter = RelativeDateTimeFormatter()
    return formatter.localizedString(for: migratedAt, relativeTo: Date())
  }
}

// MARK: - Migration Errors

enum MigrationError: Error, LocalizedError {
  case migrationInProgress
  case noMigrationInProgress
  case authenticationRequired
  case sourceAuthenticationFailed
  case sourceAuthenticationExpired
  case destinationClientCreationFailed
  case destinationAuthenticationFailed
  case incompatibleServers([String])
  case exportFailed
  case importFailed(Int)
  case importPrerequisitesMissing
  case verificationPrerequisitesMissing
  case verificationFailed([VerificationReport.VerificationFailure])
  case backupCreationFailed
  case unsupportedServerVersion(String)
  case rateLimitExceeded
  case dataSizeExceedsLimit(Int, Int) // actual, limit
  case networkTimeout
  case serverUnavailable(String)
  
  var errorDescription: String? {
    switch self {
    case .migrationInProgress:
      return "A migration is already in progress"
    case .noMigrationInProgress:
      return "No migration is currently in progress"
    case .authenticationRequired:
      return "Authentication to both servers is required"
    case .sourceAuthenticationFailed:
      return "Failed to authenticate with source server"
    case .sourceAuthenticationExpired:
      return "Source server authentication has expired"
    case .destinationClientCreationFailed:
      return "Failed to create client for destination server"
    case .destinationAuthenticationFailed:
      return "Failed to authenticate with destination server"
    case .incompatibleServers(let blockers):
      return "Servers are incompatible: \(blockers.joined(separator: ", "))"
    case .exportFailed:
      return "Failed to export repository from source server"
    case .importFailed(let code):
      return "Failed to import repository to destination server (HTTP \(code))"
    case .importPrerequisitesMissing:
      return "Import prerequisites are missing"
    case .verificationPrerequisitesMissing:
      return "Verification prerequisites are missing"
    case .verificationFailed(let failures):
      return "Post-migration verification failed (\(failures.count) issues)"
    case .backupCreationFailed:
      return "Failed to create pre-migration backup"
    case .unsupportedServerVersion(let version):
      return "Server version \(version) is not supported"
    case .rateLimitExceeded:
      return "Rate limit exceeded - please wait before retrying"
    case .dataSizeExceedsLimit(let actual, let limit):
      return "Data size (\(ByteCountFormatter().string(fromByteCount: Int64(actual)))) exceeds server limit (\(ByteCountFormatter().string(fromByteCount: Int64(limit))))"
    case .networkTimeout:
      return "Network request timed out"
    case .serverUnavailable(let server):
      return "Server \(server) is currently unavailable"
    }
  }
}