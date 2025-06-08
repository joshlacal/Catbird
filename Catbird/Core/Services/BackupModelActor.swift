import Foundation
import SwiftData
import OSLog

/// Actor for thread-safe backup record operations
/// This ensures consistent access to SwiftData across different contexts
actor BackupModelActor {
    
    // MARK: - Properties
    
    private let modelContainer: ModelContainer
    private let logger = Logger(subsystem: "blue.catbird", category: "BackupModelActor")
    
    // MARK: - Initialization
    
    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        logger.debug("BackupModelActor initialized with container: \(String(describing: modelContainer))")
    }
    
    // MARK: - Backup Record Operations
    
    /// Save a backup record using a fresh ModelContext
    func saveBackupRecord(_ record: BackupRecord) throws {
        logger.info("🔵 SAVE: Starting to save backup record with ID: \(record.id)")
        logger.info("🔵 SAVE: Record userDID: '\(record.userDID)'")
        logger.info("🔵 SAVE: ModelContainer: \(String(describing: self.modelContainer))")
        
        let context = ModelContext(self.modelContainer)
        logger.info("🔵 SAVE: Created ModelContext: \(String(describing: context))")
        
        context.insert(record)
        logger.info("🔵 SAVE: Inserted record into context")
        
        // Define record ID for predicate closure
        let recordID = record.id
        
        // Check if record exists in context before save
        let preSearchDescriptor = FetchDescriptor<BackupRecord>(
            predicate: #Predicate<BackupRecord> { backupRecord in backupRecord.id == recordID }
        )
        let preSearchRecords = try context.fetch(preSearchDescriptor)
        logger.info("🔵 SAVE: Record exists in context before save: \(preSearchRecords.count > 0)")
        
        try context.save()
        logger.info("✅ SAVE: Successfully saved context to database")
        
        // Force context to process pending changes
        context.processPendingChanges()
        logger.info("✅ SAVE: Processed pending changes")
        
        // Verify the save immediately
        let verifyDescriptor = FetchDescriptor<BackupRecord>(
            predicate: #Predicate<BackupRecord> { backupRecord in backupRecord.id == recordID }
        )
        let verifyRecords = try context.fetch(verifyDescriptor)
        logger.info("✅ SAVE VERIFY: Found \(verifyRecords.count) records with ID \(record.id)")
        
        // Also check all records in this context
        let allDescriptor = FetchDescriptor<BackupRecord>()
        let allRecords = try context.fetch(allDescriptor)
        logger.info("✅ SAVE VERIFY: Total records in this context: \(allRecords.count)")
        
        if allRecords.count > 0 {
            logger.info("✅ SAVE VERIFY: Records found:")
            for (index, r) in allRecords.enumerated() {
                logger.info("  Record \(index): ID=\(r.id), userDID='\(r.userDID)', status=\(String(describing: r.status))")
            }
        }
    }
    
    /// Fetch backup records for a user using a fresh ModelContext
    func fetchBackupRecords(for userDID: String) throws -> [BackupRecord] {
        logger.info("🔍 FETCH: Starting to fetch backup records for user: '\(userDID)'")
        logger.info("🔍 FETCH: ModelContainer: \(String(describing: self.modelContainer))")
        
        let context = ModelContext(self.modelContainer)
        logger.info("🔍 FETCH: Created ModelContext: \(String(describing: context))")
        
        // First check all records
        let allDescriptor = FetchDescriptor<BackupRecord>()
        let allRecords = try context.fetch(allDescriptor)
        logger.info("🔍 FETCH: Total records in database: \(allRecords.count)")
        
        if allRecords.count > 0 {
            logger.info("🔍 FETCH: All records in database:")
            for (index, record) in allRecords.enumerated() {
                logger.info("  Record \(index): ID=\(record.id), userDID='\(record.userDID)', status=\(String(describing: record.status))")
            }
        }
        
        // Now fetch specific user records
        let descriptor = FetchDescriptor<BackupRecord>(
            predicate: #Predicate<BackupRecord> { backupRecord in backupRecord.userDID == userDID },
            sortBy: [SortDescriptor(\.createdDate, order: .reverse)]
        )
        
        let records = try context.fetch(descriptor)
        logger.info("🔍 FETCH: Found \(records.count) records for userDID '\(userDID)'")
        
        return records
    }
    
    /// Fetch all backup records
    func fetchAllBackupRecords() throws -> [BackupRecord] {
        let context = ModelContext(self.modelContainer)
        
        let descriptor = FetchDescriptor<BackupRecord>(
            sortBy: [SortDescriptor(\.createdDate, order: .reverse)]
        )
        
        let records = try context.fetch(descriptor)
        logger.info("Fetched \(records.count) total backup records")
        
        return records
    }
    
    /// Delete a backup record
    func deleteBackupRecord(_ recordID: UUID) throws {
        let context = ModelContext(self.modelContainer)
        
        let descriptor = FetchDescriptor<BackupRecord>(
            predicate: #Predicate<BackupRecord> { backupRecord in backupRecord.id == recordID }
        )
        
        if let record = try context.fetch(descriptor).first {
            context.delete(record)
            try context.save()
            logger.info("Deleted backup record: \(recordID)")
        } else {
            logger.warning("Backup record not found for deletion: \(recordID)")
        }
    }
    
    /// Update a backup record
    func updateBackupRecord(_ recordID: UUID, updates: (BackupRecord) -> Void) throws {
        let context = ModelContext(self.modelContainer)
        
        let descriptor = FetchDescriptor<BackupRecord>(
            predicate: #Predicate<BackupRecord> { backupRecord in backupRecord.id == recordID }
        )
        
        if let record = try context.fetch(descriptor).first {
            updates(record)
            try context.save()
            logger.info("Updated backup record: \(recordID)")
        } else {
            logger.warning("Backup record not found for update: \(recordID)")
        }
    }
    
    // MARK: - Backup Configuration Operations
    
    /// Get or create backup configuration for a user
    func getBackupConfiguration(for userDID: String) throws -> BackupConfiguration {
        let context = ModelContext(self.modelContainer)
        
        let descriptor = FetchDescriptor<BackupConfiguration>(
            predicate: #Predicate<BackupConfiguration> { config in config.userDID == userDID }
        )
        
        if let existingConfig = try context.fetch(descriptor).first {
            return existingConfig
        } else {
            // Create default configuration
            let newConfig = BackupConfiguration(userDID: userDID)
            context.insert(newConfig)
            try context.save()
            logger.info("Created new backup configuration for user: \(userDID)")
            return newConfig
        }
    }
    
    /// Update backup configuration
    func updateBackupConfiguration(_ config: BackupConfiguration) throws {
        let context = ModelContext(self.modelContainer)
        
        let configID = config.id
        let descriptor = FetchDescriptor<BackupConfiguration>(
            predicate: #Predicate<BackupConfiguration> { backupConfig in backupConfig.id == configID }
        )
        
        if let existingConfig = try context.fetch(descriptor).first {
            // Update the existing configuration
            existingConfig.autoBackupEnabled = config.autoBackupEnabled
            existingConfig.backupFrequencyHours = config.backupFrequencyHours
            existingConfig.maxBackupsToKeep = config.maxBackupsToKeep
            existingConfig.verifyIntegrityAfterBackup = config.verifyIntegrityAfterBackup
            existingConfig.lastAutoBackupDate = config.lastAutoBackupDate
            existingConfig.autoParseAfterBackup = config.autoParseAfterBackup
            
            try context.save()
            logger.info("Updated backup configuration for user: \(config.userDID)")
        } else {
            // Insert as new if not found
            context.insert(config)
            try context.save()
            logger.info("Inserted new backup configuration for user: \(config.userDID)")
        }
    }
}
