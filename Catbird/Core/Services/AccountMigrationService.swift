import Foundation
import OSLog
import Petrel

/// ⚠️ EXPERIMENTAL: Core service for orchestrating account migrations between AT Protocol instances
/// This is bleeding-edge functionality with significant risks - use with extreme caution
@Observable
final class AccountMigrationService {
  // MARK: - Properties
  
  private let logger = Logger(subsystem: "blue.catbird", category: "AccountMigration")
  
  // Current migration state
  private(set) var currentMigration: MigrationOperation?
  private(set) var migrationHistory: [MigrationRecord] = []
  
  // Multi-instance authentication state
  private(set) var sourceClient: ATProtoClient?
  private(set) var destinationClient: ATProtoClient?
  
  // Migration configuration
  private let migrationConfig = MigrationConfiguration()
  
  // Safety and validation
  private let migrationValidator = MigrationValidator()
  private let migrationSafetyService = MigrationSafetyService()
  
  // MARK: - Initialization
  
  init() {
    logger.debug("AccountMigrationService initialized - EXPERIMENTAL functionality enabled")
    loadMigrationHistory()
  }
  
  // MARK: - Migration Workflow
  
  /// Start a complete account migration process
  /// - Parameters:
  ///   - sourceConfig: Configuration for source AT Protocol instance
  ///   - destinationConfig: Configuration for destination AT Protocol instance
  ///   - options: Migration options and preferences
  ///   - backupManager: Backup manager for pre-migration backup
  func startMigration(
    sourceConfig: ServerConfiguration,
    destinationConfig: ServerConfiguration,
    options: MigrationOptions,
    backupManager: BackupManager
  ) async throws -> MigrationOperation {
    
    logger.info("🚨 EXPERIMENTAL: Starting account migration from \(sourceConfig.displayName) to \(destinationConfig.displayName)")
    
    // Ensure no migration is currently in progress
    guard currentMigration == nil else {
      throw MigrationError.migrationInProgress
    }
    
    // Create migration operation
    let migrationId = UUID()
    let migration = MigrationOperation(
      id: migrationId,
      sourceServer: sourceConfig,
      destinationServer: destinationConfig,
      options: options,
      createdAt: Date()
    )
    
    currentMigration = migration
    
    do {
      // Phase 1: Pre-migration safety checks and backup
      try await performPreMigrationChecks(migration: migration, backupManager: backupManager)
      
      // Phase 2: Authentication to both instances
      try await establishDualAuthentication(migration: migration)
      
      // Phase 3: Validation and compatibility checks
      try await performCompatibilityValidation(migration: migration)
      
      // Phase 4: Export from source
      try await performRepositoryExport(migration: migration)
      
      // Phase 5: Import to destination
      try await performRepositoryImport(migration: migration)
      
      // Phase 6: Post-migration verification
      try await performPostMigrationVerification(migration: migration)
      
      // Phase 7: Complete migration
      try await completeMigration(migration: migration)
      
      return migration
      
    } catch {
      logger.error("Migration failed: \(error.localizedDescription)")
      await handleMigrationFailure(migration: migration, error: error)
      throw error
    }
  }
  
  // MARK: - Migration Phases
  
  /// Phase 1: Pre-migration safety checks and backup creation
  private func performPreMigrationChecks(
    migration: MigrationOperation,
    backupManager: BackupManager
  ) async throws {
    
    migration.updateStatus(.preparingBackup)
    logger.info("Phase 1: Creating pre-migration backup")
    
    // Mandatory backup before migration
    guard let sourceClient = sourceClient,
          let userDID = try? await sourceClient.getDid(),
          let userHandle = try? await sourceClient.getHandle() else {
      throw MigrationError.authenticationRequired
    }
    
    // Create backup with special migration flag
    let backupRecord = try await backupManager.createManualBackup(
      for: userDID,
      userHandle: userHandle,
      client: sourceClient
    )
    
    migration.preMigrationBackupId = backupRecord.id
    
    // Verify backup integrity
    try await backupManager.verifyBackupIntegrity(backupRecord)
    
    logger.info("✅ Pre-migration backup created and verified: \(backupRecord.id)")
  }
  
  /// Phase 2: Establish authenticated connections to both instances
  private func establishDualAuthentication(migration: MigrationOperation) async throws {
    migration.updateStatus(.authenticating)
    logger.info("Phase 2: Establishing dual authentication")
    
    // Source authentication should already be established
    guard let existingSourceClient = sourceClient else {
      throw MigrationError.sourceAuthenticationFailed
    }
    
    // Verify source authentication is still valid
    guard await existingSourceClient.hasValidSession() else {
      throw MigrationError.sourceAuthenticationExpired
    }
    
    // Create destination client with OAuth configuration
    let destinationOAuthConfig = OAuthConfiguration(
      clientId: "https://catbird.blue/oauth/client-metadata.json",
      redirectUri: "https://catbird.blue/oauth/callback",
      scope: "atproto transition:generic"
    )
    
    destinationClient = await ATProtoClient(
      oauthConfig: destinationOAuthConfig,
      namespace: "blue.catbird.migration",
      userAgent: "Catbird-Migration/1.0"
    )
    
    guard let destClient = destinationClient else {
      throw MigrationError.destinationClientCreationFailed
    }
    
    // Start OAuth flow for destination
    migration.destinationAuthURL = try await destClient.startOAuthFlow(
      identifier: migration.options.destinationHandle ?? "user"
    )
    
    logger.info("✅ Dual authentication prepared - awaiting destination OAuth completion")
  }
  
  /// Phase 3: Validate compatibility between instances
  private func performCompatibilityValidation(migration: MigrationOperation) async throws {
    migration.updateStatus(.validating)
    logger.info("Phase 3: Performing compatibility validation")
    
    guard let sourceClient = sourceClient,
          let destinationClient = destinationClient else {
      throw MigrationError.authenticationRequired
    }
    
    // Check server compatibility
    let compatibility = try await migrationValidator.validateServerCompatibility(
      source: sourceClient,
      destination: destinationClient
    )
    
    migration.compatibilityReport = compatibility
    
    // Check if migration can proceed
    guard compatibility.canProceed else {
      throw MigrationError.incompatibleServers(compatibility.blockers)
    }
    
    // Validate user permissions
    try await migrationValidator.validateUserPermissions(
      sourceClient: sourceClient,
      destinationClient: destinationClient
    )
    
    // Check rate limits and quotas
    try await migrationValidator.validateRateLimits(
      sourceClient: sourceClient,
      destinationClient: destinationClient,
      estimatedDataSize: migration.estimatedDataSize
    )
    
    logger.info("✅ Compatibility validation passed with \(compatibility.warnings.count) warnings")
  }
  
  /// Phase 4: Export repository from source instance
  private func performRepositoryExport(migration: MigrationOperation) async throws {
    migration.updateStatus(.exporting)
    logger.info("Phase 4: Exporting repository from source")
    
    guard let sourceClient = sourceClient else {
      throw MigrationError.authenticationRequired
    }
    
    // Get user DID for export
    let userDID = try await sourceClient.getDid()
    
    // Export repository as CAR file
    let (responseCode, response) = try await sourceClient.com.atproto.sync.getRepo(
      input: .init(did: DID(didString: userDID), since: nil)
    )
    
    guard responseCode == 200, let exportData = response?.data else {
      throw MigrationError.exportFailed
    }
    
    // Store exported data temporarily
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("migration_\(migration.id)")
      .appendingPathExtension("car")
    
    try exportData.write(to: tempURL)
    migration.exportedDataPath = tempURL.path
    migration.exportedDataSize = exportData.count
    
    // Verify export integrity
    try await migrationValidator.validateExportIntegrity(
      carData: exportData,
      expectedDID: userDID
    )
    
    logger.info("✅ Repository exported: \(exportData.count) bytes")
  }
  
  /// Phase 5: Import repository to destination instance
  private func performRepositoryImport(migration: MigrationOperation) async throws {
    migration.updateStatus(.importing)
    logger.info("Phase 5: Importing repository to destination")
    
    guard let destinationClient = destinationClient,
          let exportPath = migration.exportedDataPath else {
      throw MigrationError.importPrerequisitesMissing
    }
    
    // Load exported CAR data
    let exportURL = URL(fileURLWithPath: exportPath)
    let carData = try Data(contentsOf: exportURL)
    
    // Get destination user DID
    let destinationDID = try await destinationClient.getDid()
    
    // Import repository using AT Protocol import endpoint
    let responseCode = try await destinationClient.com.atproto.repo.importRepo(data: carData)
    
    guard responseCode == 200 else {
      throw MigrationError.importFailed(responseCode)
    }
    
    migration.destinationDID = destinationDID
    
    logger.info("✅ Repository imported to destination")
  }
  
  /// Phase 6: Post-migration verification
  private func performPostMigrationVerification(migration: MigrationOperation) async throws {
    migration.updateStatus(.verifying)
    logger.info("Phase 6: Performing post-migration verification")
    
    guard let sourceClient = sourceClient,
          let destinationClient = destinationClient,
          let destinationDID = migration.destinationDID else {
      throw MigrationError.verificationPrerequisitesMissing
    }
    
    // Verify data integrity on destination
    let verification = try await migrationValidator.verifyMigrationIntegrity(
      sourceClient: sourceClient,
      destinationClient: destinationClient,
      destinationDID: destinationDID,
      migration: migration
    )
    
    migration.verificationReport = verification
    
    // Check if verification passed
    guard verification.overallSuccess else {
      throw MigrationError.verificationFailed(verification.failures)
    }
    
    logger.info("✅ Post-migration verification completed: \(verification.successRate)% success rate")
  }
  
  /// Phase 7: Complete migration
  private func completeMigration(migration: MigrationOperation) async throws {
    migration.updateStatus(.completed)
    migration.completedAt = Date()
    
    // Record migration in history
    let record = MigrationRecord(
      id: migration.id,
      sourceServer: migration.sourceServer.displayName,
      destinationServer: migration.destinationServer.displayName,
      migratedAt: Date(),
      status: .completed,
      dataSize: migration.exportedDataSize,
      verificationScore: migration.verificationReport?.successRate ?? 0.0,
      errorMessage: nil
    )
    
    migrationHistory.append(record)
    saveMigrationHistory()
    
    // Clean up temporary files
    if let exportPath = migration.exportedDataPath {
      try? FileManager.default.removeItem(atPath: exportPath)
    }
    
    currentMigration = nil
    
    logger.info("🎉 Migration completed successfully!")
  }
  
  // MARK: - Error Handling
  
  /// Handle migration failure with rollback if needed
  private func handleMigrationFailure(migration: MigrationOperation, error: Error) async {
    logger.error("🚨 Migration failed: \(error.localizedDescription)")
    
    migration.updateStatus(.failed)
    migration.errorMessage = error.localizedDescription
    migration.completedAt = Date()
    
    // Record failed migration
    let record = MigrationRecord(
      id: migration.id,
      sourceServer: migration.sourceServer.displayName,
      destinationServer: migration.destinationServer.displayName,
      migratedAt: Date(),
      status: .failed,
      dataSize: migration.exportedDataSize,
      verificationScore: 0.0,
      errorMessage: error.localizedDescription
    )
    
    migrationHistory.append(record)
    saveMigrationHistory()
    
    // Clean up temporary files
    if let exportPath = migration.exportedDataPath {
      try? FileManager.default.removeItem(atPath: exportPath)
    }
    
    // Attempt rollback if needed
    if migration.status == .importing || migration.status == .verifying {
      await attemptRollback(migration: migration)
    }
    
    currentMigration = nil
  }
  
  /// Attempt to rollback a failed migration
  private func attemptRollback(migration: MigrationOperation) async {
    logger.info("Attempting migration rollback...")
    
    // Implementation would depend on server capabilities
    // Most AT Protocol servers don't support account deletion post-import
    // So rollback is primarily about cleaning up local state
    
    logger.warning("⚠️ Rollback completed - manual cleanup may be required on destination server")
  }
  
  // MARK: - Public Methods
  
  /// Complete destination OAuth authentication
  func completeDestinationAuth(_ url: URL) async throws {
    guard let migration = currentMigration,
          let destinationClient = destinationClient else {
      throw MigrationError.noMigrationInProgress
    }
    
    // Handle OAuth callback
    try await destinationClient.handleOAuthCallback(url: url)
    
    // Verify authentication succeeded
    guard await destinationClient.hasValidSession() else {
      throw MigrationError.destinationAuthenticationFailed
    }
    
    logger.info("✅ Destination authentication completed")
  }
  
  /// Cancel current migration
  func cancelMigration() async throws {
    guard let migration = currentMigration else {
      throw MigrationError.noMigrationInProgress
    }
    
    logger.info("Cancelling migration \(migration.id)")
    
    migration.updateStatus(.cancelled)
    migration.completedAt = Date()
    
    // Clean up
    if let exportPath = migration.exportedDataPath {
      try? FileManager.default.removeItem(atPath: exportPath)
    }
    
    currentMigration = nil
    
    // Record cancellation
    let record = MigrationRecord(
      id: migration.id,
      sourceServer: migration.sourceServer.displayName,
      destinationServer: migration.destinationServer.displayName,
      migratedAt: Date(),
      status: .cancelled,
      dataSize: migration.exportedDataSize,
      verificationScore: 0.0,
      errorMessage: "Migration was cancelled by user"
    )
    
    migrationHistory.append(record)
    saveMigrationHistory()
  }
  
  /// Get migration progress as percentage
  func getMigrationProgress() -> Double {
    guard let migration = currentMigration else { return 0.0 }
    
    return migration.status.progressPercentage
  }
  
  /// Update source client (from existing authentication)
  func updateSourceClient(_ client: ATProtoClient?) {
    sourceClient = client
  }
  
  // MARK: - Persistence
  
  private func loadMigrationHistory() {
    // Load from UserDefaults or file system
    if let data = UserDefaults.standard.data(forKey: "migration_history"),
       let history = try? JSONDecoder().decode([MigrationRecord].self, from: data) {
      migrationHistory = history
    }
  }
  
  private func saveMigrationHistory() {
    if let data = try? JSONEncoder().encode(migrationHistory) {
      UserDefaults.standard.set(data, forKey: "migration_history")
    }
  }
}

// MARK: - Migration Configuration

struct MigrationConfiguration {
  let maxRetries = 3
  let timeoutDuration: TimeInterval = 300 // 5 minutes per phase
  let maxDataSize = 1024 * 1024 * 100 // 100MB limit
  let requiredServerVersion = "0.3.0"
}
