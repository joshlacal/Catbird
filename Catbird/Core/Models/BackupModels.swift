import Foundation
import SwiftData
import CryptoKit

/// Represents a single backup record with metadata
@Model
final class BackupRecord: @unchecked Sendable {
    /// Unique identifier for this backup
    @Attribute(.unique) var id: UUID
    
    /// Date when the backup was created
    var createdDate: Date
    
    /// User DID who owns this backup
    var userDID: String
    
    /// File path where the CAR backup is stored (relative to Documents)
    var filePath: String
    
    /// Size of the backup file in bytes
    var fileSize: Int64
    
    /// SHA-256 hash of the CAR data for integrity verification
    var carDataHash: String
    
    /// Current status of the backup
    var status: BackupStatus
    
    /// Error message if backup failed
    var errorMessage: String?
    
    /// Handle of the user for display purposes
    var userHandle: String
    
    /// Size of the original repository data
    var repositorySize: Int64?
    
    /// Number of records in the backup
    var recordCount: Int?
    
    /// Last verification date
    var lastVerifiedDate: Date?
    
    /// Whether this backup passed integrity verification
    var isIntegrityValid: Bool
    
    init(
        id: UUID = UUID(),
        createdDate: Date = Date(),
        userDID: String,
        userHandle: String,
        filePath: String,
        fileSize: Int64,
        carDataHash: String,
        status: BackupStatus = .inProgress,
        errorMessage: String? = nil,
        repositorySize: Int64? = nil,
        recordCount: Int? = nil,
        isIntegrityValid: Bool = false
    ) {
        self.id = id
        self.createdDate = createdDate
        self.userDID = userDID
        self.userHandle = userHandle
        self.filePath = filePath
        self.fileSize = fileSize
        self.carDataHash = carDataHash
        self.status = status
        self.errorMessage = errorMessage
        self.repositorySize = repositorySize
        self.recordCount = recordCount
        self.isIntegrityValid = isIntegrityValid
    }
    
    /// Full file URL for the backup file
    var fullFileURL: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsPath.appendingPathComponent(filePath)
    }
    
    /// Human-readable file size
    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
    
    /// Age of the backup as a formatted string
    var ageDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: createdDate, relativeTo: Date())
    }
}

/// Configuration settings for automatic backups
@Model
final class BackupConfiguration: @unchecked Sendable {
    /// Unique identifier
    @Attribute(.unique) var id: UUID
    
    /// User DID this configuration belongs to
    var userDID: String
    
    /// Whether automatic backups are enabled
    var autoBackupEnabled: Bool
    
    /// Backup frequency in hours (24 = daily, 168 = weekly)
    var backupFrequencyHours: Int
    
    /// Maximum number of backups to keep (older ones are deleted)
    var maxBackupsToKeep: Int
    
    /// Last automatic backup date
    var lastAutoBackupDate: Date?
    
    /// Whether to backup on app launch (if enough time has passed)
    var backupOnLaunch: Bool
    
    /// Whether to verify backup integrity after creation
    var verifyIntegrityAfterBackup: Bool
    
    /// Whether to show notifications for backup status
    var showBackupNotifications: Bool
    
    /// Minimum time between backups in seconds (prevents spam)
    var minimumBackupInterval: TimeInterval
    
    /// Whether to automatically parse repository after backup creation (EXPERIMENTAL)
    var autoParseAfterBackup: Bool?
    
    init(
        id: UUID = UUID(),
        userDID: String,
        autoBackupEnabled: Bool = false,
        backupFrequencyHours: Int = 168, // Weekly by default
        maxBackupsToKeep: Int = 5,
        lastAutoBackupDate: Date? = nil,
        backupOnLaunch: Bool = false,
        verifyIntegrityAfterBackup: Bool = true,
        showBackupNotifications: Bool = true,
        minimumBackupInterval: TimeInterval = 3600, // 1 hour minimum
        autoParseAfterBackup: Bool? = true // Enable by default for experimental feature
    ) {
        self.id = id
        self.userDID = userDID
        self.autoBackupEnabled = autoBackupEnabled
        self.backupFrequencyHours = backupFrequencyHours
        self.maxBackupsToKeep = maxBackupsToKeep
        self.lastAutoBackupDate = lastAutoBackupDate
        self.backupOnLaunch = backupOnLaunch
        self.verifyIntegrityAfterBackup = verifyIntegrityAfterBackup
        self.showBackupNotifications = showBackupNotifications
        self.minimumBackupInterval = minimumBackupInterval
        self.autoParseAfterBackup = autoParseAfterBackup
    }
    
    /// Whether it's time for an automatic backup
    var needsAutomaticBackup: Bool {
        guard autoBackupEnabled else { return false }
        
        guard let lastBackup = lastAutoBackupDate else {
            return true // Never backed up
        }
        
        let hoursSinceLastBackup = Date().timeIntervalSince(lastBackup) / 3600
        return hoursSinceLastBackup >= Double(backupFrequencyHours)
    }
    
    /// Whether enough time has passed since last backup (to prevent spam)
    var canCreateNewBackup: Bool {
        guard let lastBackup = lastAutoBackupDate else {
            return true // Never backed up
        }
        
        return Date().timeIntervalSince(lastBackup) >= minimumBackupInterval
    }
}

/// Status of a backup operation
enum BackupStatus: String, CaseIterable, Codable {
    case inProgress = "in_progress"
    case completed = "completed"
    case failed = "failed"
    case verifying = "verifying"
    case verified = "verified"
    case corrupted = "corrupted"
    
    var displayName: String {
        switch self {
        case .inProgress:
            return "In Progress"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .verifying:
            return "Verifying"
        case .verified:
            return "Verified"
        case .corrupted:
            return "Corrupted"
        }
    }
    
    var systemImage: String {
        switch self {
        case .inProgress:
            return "arrow.clockwise"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .verifying:
            return "magnifyingglass"
        case .verified:
            return "checkmark.seal.fill"
        case .corrupted:
            return "exclamationmark.triangle.fill"
        }
    }
    
    var color: String {
        switch self {
        case .inProgress, .verifying:
            return "blue"
        case .completed, .verified:
            return "green"
        case .failed, .corrupted:
            return "red"
        }
    }
}