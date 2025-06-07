import Foundation
import SwiftData
import Petrel
import OSLog
import CryptoKit

/// Manages local backup operations for user data
@Observable
final class BackupManager {
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "blue.catbird", category: "BackupManager")
    private var modelContext: ModelContext?
    private var backupActor: BackupModelActor?
    private var automaticBackupTimer: Timer?
    private weak var repositoryParsingService: RepositoryParsingService?
    
    /// Current backup operation status
    var isBackingUp = false
    
    /// Progress of current backup (0.0 - 1.0)
    var backupProgress: Double = 0.0
    
    /// Current backup status message
    var backupStatusMessage: String = ""
    
    /// Error from last backup attempt
    var lastBackupError: String?
    
    // MARK: - Initialization
    
    init() {
        logger.debug("BackupManager initialized")
    }
    
    func configure(with modelContext: ModelContext, repositoryParsingService: RepositoryParsingService? = nil) {
        self.modelContext = modelContext
        self.repositoryParsingService = repositoryParsingService
        
        // Create actor with the same container for consistent access
        self.backupActor = BackupModelActor(modelContainer: modelContext.container)
        
        setupAutomaticBackupTimer()
        logger.info("BackupManager configured with ModelContext: \(String(describing: modelContext))")
        logger.info("ModelContext container: \(String(describing: modelContext.container))")
        logger.info("BackupModelActor created for consistent SwiftData access")
        
        // Test that we can fetch records
        do {
            let testFetch = try modelContext.fetch(FetchDescriptor<BackupRecord>())
            logger.info("BackupManager configuration test: can fetch records (found \(testFetch.count) existing records)")
        } catch {
            logger.error("BackupManager configuration test failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Public API
    
    /// Creates a manual backup for the current user
    @MainActor
    func createManualBackup(for userDID: String, userHandle: String, client: ATProtoClient) async throws -> BackupRecord {
        logger.info("Creating manual backup for user: \(userHandle)")
        
        guard !isBackingUp else {
            throw BackupError.backupInProgress
        }
        
        // Check if we can create a new backup (rate limiting)
        let config = try await getBackupConfiguration(for: userDID)
        if !config.canCreateNewBackup {
            throw BackupError.tooSoonForNewBackup
        }
        
        return try await performBackup(
            userDID: userDID,
            userHandle: userHandle,
            client: client,
            isAutomatic: false
        )
    }
    
    /// Creates an automatic backup if needed
    @MainActor
    func createAutomaticBackupIfNeeded(for userDID: String, userHandle: String, client: ATProtoClient) async {
        guard let config = try? await getBackupConfiguration(for: userDID),
              config.needsAutomaticBackup else {
            return
        }
        
        logger.info("Creating automatic backup for user: \(userHandle)")
        
        do {
            _ = try await performBackup(
                userDID: userDID,
                userHandle: userHandle,
                client: client,
                isAutomatic: true
            )
        } catch {
            logger.error("Automatic backup failed: \(error.localizedDescription)")
        }
    }
    
    /// Gets all backup records for a user
    func getBackupRecords(for userDID: String) async throws -> [BackupRecord] {
        guard let backupActor = backupActor else {
            logger.error("BackupActor not available when fetching backup records")
            throw BackupError.modelContextNotAvailable
        }
        
        logger.info("QUERY: Fetching backup records for user: \(userDID) using BackupModelActor")
        
        // Use actor for consistent access
        let records = try await backupActor.fetchBackupRecords(for: userDID)
        logger.info("QUERY: BackupModelActor returned \(records.count) records for user: \(userDID)")
        
        // Also fetch all records for debugging
        let allRecords = try await backupActor.fetchAllBackupRecords()
        logger.info("QUERY: Total backup records in database: \(allRecords.count)")
        
        if records.isEmpty && !allRecords.isEmpty {
            logger.warning("QUERY: No records found for userDID '\(userDID)', but database has \(allRecords.count) total records")
            for (index, record) in allRecords.enumerated() {
                logger.warning("QUERY: Record \(index) - userDID: '\(record.userDID)'")
            }
        }
        
        return records
    }
    
    /// Gets backup configuration for a user
    func getBackupConfiguration(for userDID: String) async throws -> BackupConfiguration {
        guard let backupActor = backupActor else {
            throw BackupError.modelContextNotAvailable
        }
        
        return try await backupActor.getBackupConfiguration(for: userDID)
    }
    
    /// Updates backup configuration
    func updateBackupConfiguration(_ config: BackupConfiguration) async throws {
        guard let backupActor = backupActor else {
            throw BackupError.modelContextNotAvailable
        }
        
        try await backupActor.updateBackupConfiguration(config)
        
        // Restart timer with new configuration
        setupAutomaticBackupTimer()
        
        logger.info("Backup configuration updated for user: \(config.userDID)")
    }
    
    /// Deletes a backup record and its file
    func deleteBackup(_ record: BackupRecord) throws {
        guard let modelContext = modelContext else {
            throw BackupError.modelContextNotAvailable
        }
        
        // Delete the physical file
        let fileURL = record.fullFileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
            logger.debug("Deleted backup file: \(fileURL.path)")
        }
        
        // Delete the record
        modelContext.delete(record)
        try modelContext.save()
        
        logger.info("Deleted backup record: \(record.id)")
    }
    
    /// Verifies the integrity of a backup
    @MainActor
    func verifyBackupIntegrity(_ record: BackupRecord) async throws {
        logger.info("Verifying backup integrity: \(record.id)")
        
        record.status = .verifying
        try modelContext?.save()
        
        // Read the backup file
        let fileURL = record.fullFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            record.status = .corrupted
            record.errorMessage = "Backup file not found"
            try modelContext?.save()
            throw BackupError.backupFileNotFound
        }
        
        let data = try Data(contentsOf: fileURL)
        
        // Verify file size matches
        guard data.count == record.fileSize else {
            record.status = .corrupted
            record.errorMessage = "File size mismatch"
            try modelContext?.save()
            throw BackupError.integrityCheckFailed
        }
        
        // Verify hash matches
        let hash = SHA256.hash(data: data)
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
        
        guard hashString == record.carDataHash else {
            record.status = .corrupted
            record.errorMessage = "Hash verification failed"
            try modelContext?.save()
            throw BackupError.integrityCheckFailed
        }
        
        // Update record as verified
        record.status = .verified
        record.lastVerifiedDate = Date()
        record.isIntegrityValid = true
        record.errorMessage = nil
        try modelContext?.save()
        
        logger.info("Backup integrity verified successfully: \(record.id)")
    }
    
    /// Cleans up old backups based on configuration
    func cleanupOldBackups(for userDID: String) async throws {
        let config = try await getBackupConfiguration(for: userDID)
        let records = try await getBackupRecords(for: userDID)
        
        // Keep only the most recent backups
        let recordsToDelete = Array(records.dropFirst(config.maxBackupsToKeep))
        
        for record in recordsToDelete {
            try deleteBackup(record)
        }
        
        if !recordsToDelete.isEmpty {
            logger.info("Cleaned up \(recordsToDelete.count) old backups for user: \(userDID)")
        }
    }
    
    // MARK: - Private Methods
    
    @MainActor
    private func performBackup(
        userDID: String,
        userHandle: String,
        client: ATProtoClient,
        isAutomatic: Bool
    ) async throws -> BackupRecord {
        logger.info("🔵 performBackup started for user: \(userHandle) (\(userDID))")
        
        isBackingUp = true
        backupProgress = 0.0
        backupStatusMessage = "Starting backup..."
        lastBackupError = nil
        
        defer {
            isBackingUp = false
            backupProgress = 0.0
            backupStatusMessage = ""
        }
        
        do {
            // Create backup directory if needed
            let backupsDir = getBackupsDirectory()
            try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
            
            backupProgress = 0.1
            backupStatusMessage = "Fetching repository data..."
            
            // Fetch repository data
            let (responseCode, repoData) = try await client.com.atproto.sync.getRepo(
                input: .init(did: DID(didString: userDID), since: nil)
            )
            
            guard responseCode == 200, let data = repoData else {
                throw BackupError.repositoryFetchFailed
            }
            
            backupProgress = 0.5
            backupStatusMessage = "Processing backup data..."
            
            // Generate filename
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let filename = "backup-\(userHandle)-\(timestamp).car"
            let backupURL = backupsDir.appendingPathComponent(filename)
            
            // Write CAR data to file
            let carData = data.data
            try carData.write(to: backupURL)
            
            backupProgress = 0.8
            backupStatusMessage = "Creating backup record..."
            
            // Calculate hash
            let hash = SHA256.hash(data: carData)
            let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
            
            // Create backup record
            let record = BackupRecord(
                userDID: userDID,
                userHandle: userHandle,
                filePath: "Backups/\(filename)",
                fileSize: Int64(carData.count),
                carDataHash: hashString,
                status: .completed,
                repositorySize: Int64(carData.count)
            )
            
            guard let backupActor = backupActor else {
                logger.error("❌ CRITICAL: BackupActor is nil when trying to save BackupRecord!")
                logger.error("❌ ModelContext: \(String(describing: self.modelContext))")
                logger.error("❌ BackupManager.configure was called: \(self.modelContext != nil)")
                throw BackupError.modelContextNotAvailable
            }
            
            logger.info("SAVE: About to save BackupRecord with ID: \(record.id) for user: \(userDID) using BackupModelActor")
            logger.info("SAVE: Record userDID: '\(record.userDID)'")
            logger.info("SAVE: Parameter userDID: '\(userDID)'")
            
            // Use actor for consistent saving
            do {
                logger.info("🔵 SAVE: Calling backupActor.saveBackupRecord...")
                logger.info("🔵 SAVE: BackupActor instance: \(String(describing: backupActor))")
                
                // Force a simple test to see if actor is working
                let testFetch = try await backupActor.fetchAllBackupRecords()
                logger.info("🔵 SAVE: Test fetch before save found \(testFetch.count) records")
                
                try await backupActor.saveBackupRecord(record)
                logger.info("✅ BackupModelActor saved record successfully")
                
                // Immediate test fetch to verify
                let testFetch2 = try await backupActor.fetchAllBackupRecords()
                logger.info("✅ SAVE: Test fetch after save found \(testFetch2.count) records")
            } catch {
                logger.error("❌ SAVE ERROR: BackupModelActor.saveBackupRecord failed: \(error)")
                logger.error("❌ SAVE ERROR Details: \(error.localizedDescription)")
                throw error
            }
            
            // Verify the record was saved by fetching through actor
            logger.info("Verifying save by fetching records through actor...")
            let verifyRecords = try await backupActor.fetchBackupRecords(for: userDID)
            logger.info("After save, BackupModelActor found \(verifyRecords.count) backup records for user \(userDID)")
            if let latestRecord = verifyRecords.first {
                logger.info("Latest record ID: \(latestRecord.id.uuidString), status: \(String(describing: latestRecord.status))")
            }
            
            // Double-check all records
            let allRecordsCheck = try await backupActor.fetchAllBackupRecords()
            logger.info("🔍 DEBUG: Total records in DB after save: \(allRecordsCheck.count)")
            
            backupProgress = 0.9
            backupStatusMessage = "Finalizing backup..."
            
            // Update configuration if automatic backup
            if isAutomatic {
                let config = try await getBackupConfiguration(for: userDID)
                config.lastAutoBackupDate = Date()
                try await backupActor.updateBackupConfiguration(config)
            }
            
            // Verify integrity if configured
            let config = try await getBackupConfiguration(for: userDID)
            if config.verifyIntegrityAfterBackup {
                try await verifyBackupIntegrity(record)
            }
            
            // Clean up old backups
            try await cleanupOldBackups(for: userDID)
            
            // Auto-parse repository if enabled (EXPERIMENTAL)
            if config.autoParseAfterBackup ?? true { // Default to true if nil (for existing configs)
                await triggerRepositoryParsing(for: record)
            }
            
            backupProgress = 1.0
            backupStatusMessage = "Backup completed successfully"
            
            logger.info("Backup completed successfully: \(record.id)")
            
            // Post notification that backup was created
            NotificationCenter.default.post(
                name: NSNotification.Name("BackupCreated"),
                object: nil,
                userInfo: ["backupID": record.id, "userDID": userDID]
            )
            
            return record
            
        } catch {
            lastBackupError = error.localizedDescription
            logger.error("Backup failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    private func getBackupsDirectory() -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsPath.appendingPathComponent("Backups")
    }
    
    private func setupAutomaticBackupTimer() {
        automaticBackupTimer?.invalidate()
        
        // Check for automatic backups every hour
        automaticBackupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.checkForAutomaticBackups()
            }
        }
        
        logger.debug("Automatic backup timer configured")
    }
    
    @MainActor
    private func checkForAutomaticBackups() async {
        // This would be called by AppState with current user information
        // For now, we just log that the timer fired
        logger.debug("Automatic backup timer fired")
    }
    
    /// Triggers automatic backup check for a specific user (called by AppState)
    @MainActor
    func triggerAutomaticBackupCheck(for userDID: String, userHandle: String, client: ATProtoClient) async {
        do {
            let config = try await getBackupConfiguration(for: userDID)
            if config.autoBackupEnabled && config.needsAutomaticBackup && config.canCreateNewBackup {
                logger.info("Triggering automatic backup for user: \(userHandle)")
                _ = try await performBackup(
                    userDID: userDID,
                    userHandle: userHandle,
                    client: client,
                    isAutomatic: true
                )
            }
        } catch {
            logger.error("Failed to trigger automatic backup: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Repository Parsing Integration
    
    /// Triggers repository parsing for a backup record (EXPERIMENTAL)
    @MainActor
    private func triggerRepositoryParsing(for backupRecord: BackupRecord) async {
        guard let repositoryParsingService = repositoryParsingService else {
            logger.warning("🧪 Repository parsing service not available - skipping auto-parse")
            return
        }
        
        logger.info("🧪 EXPERIMENTAL: Auto-triggering repository parsing for backup \(backupRecord.id)")
        
        do {
            // Enable experimental parsing if not already enabled
            if !repositoryParsingService.experimentalParsingEnabled {
                repositoryParsingService.experimentalParsingEnabled = true
                logger.info("🧪 Enabled experimental repository parsing")
            }
            
            // Start repository parsing in background
            let repositoryRecord = try await repositoryParsingService.startRepositoryParsing(for: backupRecord)
            logger.info("🧪 Repository parsing completed successfully: \(repositoryRecord.id)")
            
        } catch {
            logger.error("🧪 Repository parsing failed: \(error.localizedDescription)")
            // Don't propagate the error - backup was successful even if parsing failed
        }
    }
}

// MARK: - Backup Errors

enum BackupError: LocalizedError {
    case modelContextNotAvailable
    case backupInProgress
    case tooSoonForNewBackup
    case repositoryFetchFailed
    case backupFileNotFound
    case integrityCheckFailed
    case invalidUserDID
    case invalidCarData
    
    var errorDescription: String? {
        switch self {
        case .modelContextNotAvailable:
            return "Database not available for backup operations"
        case .backupInProgress:
            return "A backup is already in progress"
        case .tooSoonForNewBackup:
            return "Please wait before creating another backup"
        case .repositoryFetchFailed:
            return "Failed to fetch repository data from server"
        case .backupFileNotFound:
            return "Backup file not found on disk"
        case .integrityCheckFailed:
            return "Backup integrity verification failed"
        case .invalidUserDID:
            return "Invalid user identifier"
        case .invalidCarData:
            return "Invalid CAR file data"
        }
    }
}
