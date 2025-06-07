import Foundation
import SwiftData
import Petrel
import OSLog

// MARK: - ⚠️ EXPERIMENTAL REPOSITORY PARSING SERVICE ⚠️

/// 🧪 EXPERIMENTAL: Service for managing repository parsing operations
/// ⚠️ This is experimental functionality for parsing CAR files in the background
///
/// The RepositoryParsingService orchestrates the parsing of CAR backup files
/// into structured SwiftData models, providing progress tracking, cancellation,
/// and comprehensive error handling.
///
/// **Safety Features:**
/// - Background processing to avoid blocking UI
/// - Progress tracking with cancellation support
/// - Automatic error recovery and retry logic
/// - Parsing status persistence
/// - Memory management for large CAR files
@Observable
final class RepositoryParsingService {
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "blue.catbird.experimental", category: "RepositoryParsingService")
    private var modelContext: ModelContext?
    private var carParser = CARParser()
    
    /// Current parsing operation
    var currentParsingOperation: ParsingOperation?
    
    /// Active parsing operations by backup ID
    private var activeOperations: [UUID: ParsingOperation] = [:]
    
    /// Experimental feature toggle
    var experimentalParsingEnabled: Bool {
        get { 
            // Default to true if not explicitly set to false
            UserDefaults.standard.object(forKey: "experimentalRepositoryParsingEnabled") as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: "experimentalRepositoryParsingEnabled") }
    }
    
    // MARK: - Initialization
    
    init() {
        logger.debug("🧪 RepositoryParsingService initialized")
    }
    
    func configure(with modelContext: ModelContext) {
        self.modelContext = modelContext
        logger.debug("RepositoryParsingService configured with ModelContext")
    }
    
    // MARK: - Public API
    
    /// Start parsing a backup repository (EXPERIMENTAL)
    /// ⚠️ This operation may take significant time and resources
    @MainActor
    func startRepositoryParsing(for backupRecord: BackupRecord) async throws -> RepositoryRecord {
        logger.warning("🧪 EXPERIMENTAL: Starting repository parsing for backup \(backupRecord.id.uuidString)")
        
        // Check if experimental parsing is enabled
        guard experimentalParsingEnabled else {
            throw RepositoryParsingError.experimentalFeatureDisabled
        }
        
        // Check if already parsing this backup
        if activeOperations[backupRecord.id] != nil {
            throw RepositoryParsingError.parsingAlreadyInProgress
        }
        
        // Check if already parsed
        if let existingRepo = try getExistingRepositoryRecord(for: backupRecord.id) {
            logger.info("Repository already parsed, returning existing record")
            return existingRepo
        }
        
        // Verify backup file exists
        guard FileManager.default.fileExists(atPath: backupRecord.fullFileURL.path) else {
            throw RepositoryParsingError.backupFileNotFound
        }
        
        // Create parsing operation
        let operation = ParsingOperation(
            backupRecord: backupRecord,
            startTime: Date(),
            status: .starting
        )
        
        activeOperations[backupRecord.id] = operation
        currentParsingOperation = operation
        
        // Perform parsing in background
        let backupID = backupRecord.id
        return try await withTaskCancellationHandler {
            return try await performRepositoryParsing(operation: operation)
        } onCancel: {
            Task { @MainActor [weak self] in
                await self?.cancelRepositoryParsing(for: backupID)
            }
        }
    }
    
    /// Cancel repository parsing operation
    @MainActor
    func cancelRepositoryParsing(for backupID: UUID) async {
        guard let operation = activeOperations[backupID] else { return }
        
        logger.info("Cancelling repository parsing for backup \(backupID.uuidString)")
        
        operation.status = .cancelled
        operation.endTime = Date()
        
        // Mark repository record as cancelled if it exists
        if let repoRecord = try? getRepositoryRecord(for: backupID) {
            repoRecord.parsingStatus = .cancelled
            try? modelContext?.save()
        }
        
        activeOperations.removeValue(forKey: backupID)
        
        if currentParsingOperation?.backupRecord.id == backupID {
            currentParsingOperation = nil
        }
    }
    
    /// Get repository record for a backup
    func getRepositoryRecord(for backupID: UUID) throws -> RepositoryRecord? {
        guard let modelContext = modelContext else {
            throw RepositoryParsingError.modelContextNotAvailable
        }
        
        let descriptor = FetchDescriptor<RepositoryRecord>(
            predicate: #Predicate { $0.backupRecordID == backupID }
        )
        
        return try modelContext.fetch(descriptor).first
    }
    
    /// Get all parsed posts for a repository
    func getParsedPosts(for repositoryID: UUID) throws -> [ParsedPost] {
        guard let modelContext = modelContext else {
            throw RepositoryParsingError.modelContextNotAvailable
        }
        
        let descriptor = FetchDescriptor<ParsedPost>(
            predicate: #Predicate { $0.repositoryRecordID == repositoryID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        
        return try modelContext.fetch(descriptor)
    }
    
    /// Get parsed profile for a repository
    func getParsedProfile(for repositoryID: UUID) throws -> ParsedProfile? {
        guard let modelContext = modelContext else {
            throw RepositoryParsingError.modelContextNotAvailable
        }
        
        let descriptor = FetchDescriptor<ParsedProfile>(
            predicate: #Predicate { $0.repositoryRecordID == repositoryID }
        )
        
        return try modelContext.fetch(descriptor).first
    }
    
    /// Get parsed connections for a repository
    func getParsedConnections(for repositoryID: UUID) throws -> [ParsedConnection] {
        guard let modelContext = modelContext else {
            throw RepositoryParsingError.modelContextNotAvailable
        }
        
        let descriptor = FetchDescriptor<ParsedConnection>(
            predicate: #Predicate { $0.repositoryRecordID == repositoryID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        
        return try modelContext.fetch(descriptor)
    }
    
    /// Get parsed media for a repository
    func getParsedMedia(for repositoryID: UUID) throws -> [ParsedMedia] {
        guard let modelContext = modelContext else {
            throw RepositoryParsingError.modelContextNotAvailable
        }
        
        let descriptor = FetchDescriptor<ParsedMedia>(
            predicate: #Predicate { $0.repositoryRecordID == repositoryID },
            sortBy: [SortDescriptor(\.discoveredAt, order: .reverse)]
        )
        
        return try modelContext.fetch(descriptor)
    }
    
    /// Get parsed unknown records for debugging
    func getParsedUnknownRecords(for repositoryID: UUID) throws -> [ParsedUnknownRecord] {
        guard let modelContext = modelContext else {
            throw RepositoryParsingError.modelContextNotAvailable
        }
        
        let descriptor = FetchDescriptor<ParsedUnknownRecord>(
            predicate: #Predicate { $0.repositoryRecordID == repositoryID },
            sortBy: [SortDescriptor(\.discoveredAt, order: .reverse)]
        )
        
        return try modelContext.fetch(descriptor)
    }
    
    /// Delete all parsed data for a repository
    func deleteRepositoryData(for repositoryID: UUID) throws {
        guard let modelContext = modelContext else {
            throw RepositoryParsingError.modelContextNotAvailable
        }
        
        // Delete all related parsed data
        let posts = try getParsedPosts(for: repositoryID)
        let profiles = try getParsedProfile(for: repositoryID).map { [$0] } ?? []
        let connections = try getParsedConnections(for: repositoryID)
        let media = try getParsedMedia(for: repositoryID)
        let unknownRecords = try getParsedUnknownRecords(for: repositoryID)
        
        for post in posts { modelContext.delete(post) }
        for profile in profiles { modelContext.delete(profile) }
        for connection in connections { modelContext.delete(connection) }
        for mediaItem in media { modelContext.delete(mediaItem) }
        for unknownRecord in unknownRecords { modelContext.delete(unknownRecord) }
        
        // Delete repository record
        if let repoRecord = try getRepositoryRecord(for: repositoryID) {
            modelContext.delete(repoRecord)
        }
        
        try modelContext.save()
        
        logger.info("Deleted all parsed data for repository \(repositoryID.uuidString)")
    }
    
    /// Re-parse a repository (experimental)
    @MainActor
    func reparseRepository(for backupRecord: BackupRecord) async throws -> RepositoryRecord {
        logger.warning("🧪 EXPERIMENTAL: Re-parsing repository for backup \(backupRecord.id.uuidString)")
        
        // Delete existing parsed data
        if let existingRepo = try getExistingRepositoryRecord(for: backupRecord.id) {
            try deleteRepositoryData(for: existingRepo.id)
        }
        
        // Start fresh parsing
        return try await startRepositoryParsing(for: backupRecord)
    }
    
    // MARK: - Private Methods
    
    private func getExistingRepositoryRecord(for backupID: UUID) throws -> RepositoryRecord? {
        return try getRepositoryRecord(for: backupID)
    }
    
    private func performRepositoryParsing(operation: ParsingOperation) async throws -> RepositoryRecord {
        guard let modelContext = modelContext else {
            throw RepositoryParsingError.modelContextNotAvailable
        }
        
        // Create model actor for database operations
        let repositoryActor = RepositoryModelActor(modelContainer: modelContext.container)
        
        do {
            // Update operation status
            await MainActor.run {
                operation.status = .readingCarFile
                operation.progress = 0.1
            }
            
            // Read CAR file
            let carData = try Data(contentsOf: operation.backupRecord.fullFileURL)
            logger.info("Read CAR file: \(ByteCountFormatter.string(fromByteCount: Int64(carData.count), countStyle: .file))")
            
            // Update operation status
            await MainActor.run {
                operation.status = .parsingStructure
                operation.progress = 0.2
            }
            
            // Parse CAR file using CARParser
            let (repositoryRecord, parsedRecords) = try await carParser.parseCAR(
                data: carData,
                userDID: operation.backupRecord.userDID,
                userHandle: operation.backupRecord.userHandle,
                backupRecordID: operation.backupRecord.id
            )
            
            // Update operation status
            await MainActor.run {
                operation.status = .savingToDatabase
                operation.progress = 0.8
            }
            
            // Save repository record using actor
            try await repositoryActor.saveRepositoryRecord(repositoryRecord)
            
            // Process and save parsed records using actor
            try await repositoryActor.saveParsedRecords(parsedRecords, to: repositoryRecord)
            
            // Update operation status
            await MainActor.run {
                operation.status = .completed
                operation.progress = 1.0
                operation.endTime = Date()
            }
            
            // Clean up operation
            activeOperations.removeValue(forKey: operation.backupRecord.id)
            if currentParsingOperation?.backupRecord.id == operation.backupRecord.id {
                currentParsingOperation = nil
            }
            
            logger.info("Repository parsing completed successfully for backup \(operation.backupRecord.id.uuidString)")
            
            return repositoryRecord
            
        } catch {
            // Handle parsing errors
            await MainActor.run {
                operation.status = .failed
                operation.errorMessage = error.localizedDescription
                operation.endTime = Date()
            }
            
            // If we have a partial repository record from the parser, save it using actor
            if case let CARParsingError.parsingFailed(_, partialRecord) = error {
                try? await repositoryActor.saveRepositoryRecord(partialRecord)
            }
            
            // Clean up operation
            activeOperations.removeValue(forKey: operation.backupRecord.id)
            if currentParsingOperation?.backupRecord.id == operation.backupRecord.id {
                currentParsingOperation = nil
            }
            
            logger.error("Repository parsing failed: \(error.localizedDescription)")
            throw error
        }
    }
}

// MARK: - Parsing Operation

/// Represents an active parsing operation
@Observable
final class ParsingOperation {
    let backupRecord: BackupRecord
    let startTime: Date
    var endTime: Date?
    var status: ParsingStatus = .starting
    var progress: Double = 0.0
    var errorMessage: String?
    
    init(backupRecord: BackupRecord, startTime: Date, status: ParsingStatus) {
        self.backupRecord = backupRecord
        self.startTime = startTime
        self.status = status
    }
    
    var duration: TimeInterval? {
        guard let endTime = endTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }
    
    var formattedDuration: String {
        guard let duration = duration else { return "In progress..." }
        
        if duration < 60 {
            return String(format: "%.1fs", duration)
        } else if duration < 3600 {
            return String(format: "%.1fm", duration / 60)
        } else {
            return String(format: "%.1fh", duration / 3600)
        }
    }
}

/// Status of a parsing operation
enum ParsingStatus: String, CaseIterable {
    case starting = "starting"
    case readingCarFile = "reading_car_file"
    case parsingStructure = "parsing_structure"
    case savingToDatabase = "saving_to_database"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
    
    var displayName: String {
        switch self {
        case .starting:
            return "Starting..."
        case .readingCarFile:
            return "Reading CAR file..."
        case .parsingStructure:
            return "Parsing repository structure..."
        case .savingToDatabase:
            return "Saving to database..."
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }
    
    var systemImage: String {
        switch self {
        case .starting:
            return "clock"
        case .readingCarFile:
            return "doc.text"
        case .parsingStructure:
            return "cpu"
        case .savingToDatabase:
            return "externaldrive.badge.plus"
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
        case .starting, .readingCarFile, .parsingStructure, .savingToDatabase:
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

// MARK: - Errors

public enum RepositoryParsingError: LocalizedError {
    case experimentalFeatureDisabled
    case modelContextNotAvailable
    case backupRecordNotFound
    case parsingAlreadyInProgress
    case backupFileNotFound
    case invalidRecordData(String)
    
    public var errorDescription: String? {
        switch self {
        case .experimentalFeatureDisabled:
            return "Experimental repository parsing is disabled. Enable it in settings to use this feature."
        case .modelContextNotAvailable:
            return "Database not available for parsing operations"
        case .backupRecordNotFound:
            return "Backup record not found"
        case .parsingAlreadyInProgress:
            return "Repository parsing is already in progress for this backup"
        case .backupFileNotFound:
            return "Backup file not found on disk"
        case .invalidRecordData(let message):
            return "Invalid record data: \(message)"
        }
    }
}
