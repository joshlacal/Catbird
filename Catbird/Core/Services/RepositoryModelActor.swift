import Foundation
import SwiftData
import OSLog
import Petrel

/// Actor responsible for all repository-related database operations
/// This ensures thread-safe access to SwiftData models in Swift 6
@ModelActor
actor RepositoryModelActor {
    
    private let logger = Logger(subsystem: "Catbird", category: "RepositoryModelActor")
    
    // MARK: - Repository Record Operations
    
    /// Save a repository record to the database
    func saveRepositoryRecord(_ record: RepositoryRecord) throws {
        modelContext.insert(record)
        try modelContext.save()
        logger.info("Saved repository record: \(record.userHandle)")
    }
    
    /// Find repository record by backup ID
    func findRepositoryRecord(for backupID: UUID) throws -> RepositoryRecord? {
        let descriptor = FetchDescriptor<RepositoryRecord>(
            predicate: #Predicate { $0.backupRecordID == backupID }
        )
        return try modelContext.fetch(descriptor).first
    }
    
    /// Load all repository records
    func loadAllRepositoryRecords() throws -> [RepositoryRecord] {
        let descriptor = FetchDescriptor<RepositoryRecord>(
            sortBy: [SortDescriptor(\.parsedDate, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }
    
    // MARK: - Backup Record Operations
    
    /// Load all backup records
    func loadAllBackupRecords() throws -> [BackupRecord] {
        let descriptor = FetchDescriptor<BackupRecord>(
            sortBy: [SortDescriptor(\.createdDate, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }
    
    /// Save a backup record
    func saveBackupRecord(_ record: BackupRecord) throws {
        modelContext.insert(record)
        try modelContext.save()
        logger.info("Saved backup record: \(record.userHandle)")
    }
    
    // MARK: - Parsed Record Operations
    
    /// Save parsed AT Protocol records in batches
    func saveParsedRecords(
        _ parsedRecords: [CARParser.ParsedRecord],
        to repositoryRecord: RepositoryRecord
    ) throws {
        logger.info("Saving \(parsedRecords.count) parsed records to database")
        
        var batchCount = 0
        let batchSize = 5  // Smaller batches to reduce memory pressure
        
        for record in parsedRecords {
            try saveIndividualParsedRecord(record, to: repositoryRecord)
            batchCount += 1
            
            // Save periodically to avoid memory issues
            if batchCount % batchSize == 0 {
                try modelContext.save()
                logger.debug("Saved batch of \(batchSize) records, total: \(batchCount)")
            }
        }
        
        // Final save
        try modelContext.save()
        logger.info("Successfully saved all \(parsedRecords.count) parsed records")
    }
    
    private func saveIndividualParsedRecord(
        _ record: CARParser.ParsedRecord,
        to repositoryRecord: RepositoryRecord
    ) throws {
        // Create ATProtocolValueContainer from the parsed data
        let container: ATProtocolValueContainer
        if let parsedData = record.parsedData {
            container = try createATProtocolContainer(from: parsedData, recordType: record.recordType)
        } else {
            container = .decodeError(record.parseError ?? "Unknown parsing error")
        }
        
        // Serialize the container to Data for storage
        let recordData: Data
        
        // Check if container is a decode error - handle it specially
        if case .decodeError(let errorMessage) = container {
            // For decode errors, store a simplified JSON representation
            let errorData: [String: Any] = [
                "recordType": record.recordType,
                "recordKey": record.recordKey,
                "parseSuccessful": false,
                "parseError": errorMessage,
                "rawData": record.rawCBORData.base64EncodedString()
            ]
            recordData = try JSONSerialization.data(withJSONObject: errorData)
        } else {
            // For successful containers, try to encode normally
            do {
                let jsonEncoder = JSONEncoder()
                jsonEncoder.dateEncodingStrategy = .iso8601
                recordData = try jsonEncoder.encode(container)
            } catch {
                // Fallback to simplified representation
                logger.warning("Failed to encode ATProtocolValueContainer: \(error). Using simplified representation.")
                let simplifiedData: [String: Any] = [
                    "recordType": record.recordType,
                    "recordKey": record.recordKey,
                    "parseSuccessful": record.parseSuccessful,
                    "parseError": record.parseError ?? "",
                    "rawData": record.rawCBORData.base64EncodedString()
                ]
                recordData = try JSONSerialization.data(withJSONObject: simplifiedData)
            }
        }
        
        // Extract createdAt date if available
        var createdAt: Date?
        if let parsedData = record.parsedData as? [String: Any],
           let createdAtString = parsedData["createdAt"] as? String {
            createdAt = ISO8601DateFormatter().date(from: createdAtString)
        } else if let parsedData = record.parsedData as? [String: Any],
                  let createdAtDate = parsedData["createdAt"] as? Date {
            createdAt = createdAtDate
        }
        
        // Create the AT Protocol record URI
        let recordURI = "at://\(repositoryRecord.userDID)/\(record.recordType)/\(record.recordKey)"
        
        // Create and save ParsedATProtocolRecord
        let atProtoRecord = ParsedATProtocolRecord(
            repositoryRecordID: repositoryRecord.id,
            recordURI: recordURI,
            recordKey: record.recordKey,
            collectionType: record.recordType,
            recordData: recordData,
            recordCID: record.cid.string,
            createdAt: createdAt,
            parseSuccessful: record.parseSuccessful,
            parseConfidence: record.parseConfidence,
            parseError: record.parseError,
            rawCBORData: record.rawCBORData
        )
        
        modelContext.insert(atProtoRecord)
        
        // Also save legacy models for backward compatibility
        switch record.recordType {
        case "app.bsky.feed.post":
            if let parsedPost = try? createParsedPost(from: record, repositoryID: repositoryRecord.id) {
                modelContext.insert(parsedPost)
            }
        case "app.bsky.actor.profile":
            if let parsedProfile = try? createParsedProfile(from: record, repositoryID: repositoryRecord.id) {
                modelContext.insert(parsedProfile)
            }
        case "app.bsky.graph.follow":
            if let parsedConnection = try? createParsedConnection(from: record, repositoryID: repositoryRecord.id) {
                modelContext.insert(parsedConnection)
            }
        default:
            // Save as unknown record for debugging
            let unknownRecord = ParsedUnknownRecord(
                repositoryRecordID: repositoryRecord.id,
                recordKey: record.recordKey,
                recordType: record.recordType,
                rawCBORData: record.rawCBORData,
                recordCID: record.cid.string,
                parseAttemptError: record.parseError
            )
            modelContext.insert(unknownRecord)
        }
    }
    
    // MARK: - Helper Methods
    
    private func createATProtocolContainer(from data: Any, recordType: String) throws -> ATProtocolValueContainer {
        // Convert the parsed data into an ATProtocolValueContainer
        if let dict = data as? [String: Any] {
            // Add the $type field if not present
            var mutableDict = dict
            if mutableDict["$type"] == nil {
                mutableDict["$type"] = recordType
            }
            
            // Convert to ATProtocolValueContainer object
            var containerDict: [String: ATProtocolValueContainer] = [:]
            for (key, value) in mutableDict {
                containerDict[key] = try convertToATProtocolContainer(value)
            }
            return .object(containerDict)
        } else {
            // For non-dictionary data, wrap it appropriately
            return try convertToATProtocolContainer(data)
        }
    }
    
    private func convertToATProtocolContainer(_ value: Any) throws -> ATProtocolValueContainer {
        switch value {
        case let string as String:
            return .string(string)
        case let number as Int:
            return .number(number)
        case let bool as Bool:
            return .bool(bool)
        case let array as [Any]:
            let containers = try array.map { try convertToATProtocolContainer($0) }
            return .array(containers)
        case let dict as [String: Any]:
            var containerDict: [String: ATProtocolValueContainer] = [:]
            for (key, val) in dict {
                containerDict[key] = try convertToATProtocolContainer(val)
            }
            return .object(containerDict)
        case is NSNull:
            return .null
        default:
            // For unknown types, convert to string representation
            return .string(String(describing: value))
        }
    }
    
    private func createParsedPost(from record: CARParser.ParsedRecord, repositoryID: UUID) throws -> ParsedPost {
        guard let parsedData = record.parsedData as? [String: Any] else {
            throw RepositoryParsingError.invalidRecordData("Missing parsed data for post")
        }
        
        let text = parsedData["text"] as? String ?? ""
        let createdAtString = parsedData["createdAt"] as? String ?? ""
        let createdAt = ISO8601DateFormatter().date(from: createdAtString) ?? Date()
        
        return ParsedPost(
            repositoryRecordID: repositoryID,
            recordKey: record.recordKey,
            text: text,
            createdAt: createdAt,
            rawCBORData: record.rawCBORData,
            recordCID: record.cid.string,
            parseSuccessful: record.parseSuccessful,
            parseErrorMessage: record.parseError,
            parseConfidence: record.parseConfidence
        )
    }
    
    private func createParsedProfile(from record: CARParser.ParsedRecord, repositoryID: UUID) throws -> ParsedProfile {
        guard let parsedData = record.parsedData as? [String: Any] else {
            throw RepositoryParsingError.invalidRecordData("Missing parsed data for profile")
        }
        
        let displayName = parsedData["displayName"] as? String
        let description = parsedData["description"] as? String
        
        return ParsedProfile(
            repositoryRecordID: repositoryID,
            recordKey: record.recordKey,
            displayName: displayName,
            description: description,
            rawCBORData: record.rawCBORData,
            recordCID: record.cid.string,
            parseSuccessful: record.parseSuccessful,
            parseErrorMessage: record.parseError,
            parseConfidence: record.parseConfidence
        )
    }
    
    private func createParsedConnection(from record: CARParser.ParsedRecord, repositoryID: UUID) throws -> ParsedConnection {
        guard let parsedData = record.parsedData as? [String: Any] else {
            throw RepositoryParsingError.invalidRecordData("Missing parsed data for connection")
        }
        
        let targetUserDID = parsedData["subject"] as? String ?? ""
        let createdAtString = parsedData["createdAt"] as? String ?? ""
        let createdAt = ISO8601DateFormatter().date(from: createdAtString) ?? Date()
        
        return ParsedConnection(
            repositoryRecordID: repositoryID,
            recordKey: record.recordKey,
            targetUserDID: targetUserDID,
            connectionType: "follow",
            createdAt: createdAt,
            rawCBORData: record.rawCBORData,
            recordCID: record.cid.string,
            parseSuccessful: record.parseSuccessful,
            parseErrorMessage: record.parseError,
            parseConfidence: record.parseConfidence
        )
    }
    
    // MARK: - Enhanced Batch Operations
    
    /// Save all parsed records in a single transaction
    func saveParsedRecords(
        repositoryRecordID: UUID,
        atProtocolRecords: [ParsedATProtocolRecord],
        posts: [ParsedPost],
        profiles: [ParsedProfile],
        connections: [ParsedConnection],
        media: [ParsedMedia],
        unknownRecords: [ParsedUnknownRecord]
    ) throws {
        logger.info("Batch saving parsed records for repository \(repositoryRecordID)")
        
        var totalRecords = 0
        
        // Insert AT Protocol records
        for record in atProtocolRecords {
            modelContext.insert(record)
            totalRecords += 1
        }
        
        // Insert posts
        for post in posts {
            modelContext.insert(post)
            totalRecords += 1
        }
        
        // Insert profiles
        for profile in profiles {
            modelContext.insert(profile)
            totalRecords += 1
        }
        
        // Insert connections
        for connection in connections {
            modelContext.insert(connection)
            totalRecords += 1
        }
        
        // Insert media
        for mediaItem in media {
            modelContext.insert(mediaItem)
            totalRecords += 1
        }
        
        // Insert unknown records
        for unknownRecord in unknownRecords {
            modelContext.insert(unknownRecord)
            totalRecords += 1
        }
        
        // Save all at once
        try modelContext.save()
        
        logger.info("Successfully saved \(totalRecords) parsed records to database")
    }
    
    /// Delete all parsed records for a repository
    func deleteAllParsedRecords(for repositoryRecordID: UUID) throws {
        logger.info("Deleting all parsed records for repository \(repositoryRecordID)")
        
        // Delete AT Protocol records
        let atProtoDescriptor = FetchDescriptor<ParsedATProtocolRecord>(
            predicate: #Predicate { $0.repositoryRecordID == repositoryRecordID }
        )
        let atProtoRecords = try modelContext.fetch(atProtoDescriptor)
        for record in atProtoRecords {
            modelContext.delete(record)
        }
        
        // Delete posts
        let postDescriptor = FetchDescriptor<ParsedPost>(
            predicate: #Predicate { $0.repositoryRecordID == repositoryRecordID }
        )
        let posts = try modelContext.fetch(postDescriptor)
        for post in posts {
            modelContext.delete(post)
        }
        
        // Delete profiles
        let profileDescriptor = FetchDescriptor<ParsedProfile>(
            predicate: #Predicate { $0.repositoryRecordID == repositoryRecordID }
        )
        let profiles = try modelContext.fetch(profileDescriptor)
        for profile in profiles {
            modelContext.delete(profile)
        }
        
        // Delete connections
        let connectionDescriptor = FetchDescriptor<ParsedConnection>(
            predicate: #Predicate { $0.repositoryRecordID == repositoryRecordID }
        )
        let connections = try modelContext.fetch(connectionDescriptor)
        for connection in connections {
            modelContext.delete(connection)
        }
        
        // Delete media
        let mediaDescriptor = FetchDescriptor<ParsedMedia>(
            predicate: #Predicate { $0.repositoryRecordID == repositoryRecordID }
        )
        let mediaItems = try modelContext.fetch(mediaDescriptor)
        for mediaItem in mediaItems {
            modelContext.delete(mediaItem)
        }
        
        // Delete unknown records
        let unknownDescriptor = FetchDescriptor<ParsedUnknownRecord>(
            predicate: #Predicate { $0.repositoryRecordID == repositoryRecordID }
        )
        let unknownRecords = try modelContext.fetch(unknownDescriptor)
        for unknownRecord in unknownRecords {
            modelContext.delete(unknownRecord)
        }
        
        // Save all deletions
        try modelContext.save()
        
        logger.info("Successfully deleted all parsed records for repository \(repositoryRecordID)")
    }
}
