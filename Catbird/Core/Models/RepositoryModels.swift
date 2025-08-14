import Foundation
import SwiftData
import CryptoKit
import Petrel

// MARK: - ⚠️ EXPERIMENTAL REPOSITORY PARSING MODELS ⚠️

/// 🧪 EXPERIMENTAL: Represents a parsed repository from a CAR backup
/// ⚠️ This is experimental functionality for parsing CAR files into structured data
@Model
final class RepositoryRecord: @unchecked Sendable {
    /// Unique identifier for this parsed repository
    @Attribute(.unique) var id: UUID
    
    /// Reference to the original backup record
    var backupRecordID: UUID
    
    /// Date when parsing was completed
    var parsedDate: Date
    
    /// User DID who owns this repository
    var userDID: String
    
    /// User handle at time of parsing
    var userHandle: String
    
    /// Total number of records found in the repository
    var totalRecordCount: Int
    
    /// Number of successfully parsed records
    var successfullyParsedCount: Int
    
    /// Number of records that failed to parse
    var failedParseCount: Int
    
    /// Number of unknown record types encountered
    var unknownRecordTypeCount: Int
    
    /// Current parsing status
    var parsingStatus: RepositoryParsingStatus
    
    /// Error message if parsing failed
    var parsingErrorMessage: String?
    
    /// Parsing confidence score (0.0 - 1.0)
    var parsingConfidenceScore: Double
    
    /// Raw parsing logs for debugging
    var parsingLogs: String
    
    /// Optional path to parsing log file (for large log files)
    var parsingLogFileURL: URL?
    
    /// Size of original CAR data in bytes
    var originalCarSize: Int64
    
    /// Repository commit information if available
    var repositoryCommit: String?
    
    /// Last modification time of the repository
    var repositoryLastModified: Date?
    
    /// Parsing statistics as JSON
    var parsingStatistics: String
    
    /// Whether this repository has media references
    var hasMediaReferences: Bool
    
    /// Number of parsed posts
    var postCount: Int
    
    /// Number of parsed profiles
    var profileCount: Int
    
    /// Number of parsed connections (follows/followers)
    var connectionCount: Int
    
    /// Number of parsed media items
    var mediaCount: Int
    
    init(
        id: UUID = UUID(),
        backupRecordID: UUID,
        parsedDate: Date = Date(),
        userDID: String,
        userHandle: String,
        totalRecordCount: Int = 0,
        successfullyParsedCount: Int = 0,
        failedParseCount: Int = 0,
        unknownRecordTypeCount: Int = 0,
        parsingStatus: RepositoryParsingStatus = .notStarted,
        parsingErrorMessage: String? = nil,
        parsingConfidenceScore: Double = 0.0,
        parsingLogs: String = "",
        parsingLogFileURL: URL? = nil,
        originalCarSize: Int64,
        repositoryCommit: String? = nil,
        repositoryLastModified: Date? = nil,
        parsingStatistics: String = "{}",
        hasMediaReferences: Bool = false,
        postCount: Int = 0,
        profileCount: Int = 0,
        connectionCount: Int = 0,
        mediaCount: Int = 0
    ) {
        self.id = id
        self.backupRecordID = backupRecordID
        self.parsedDate = parsedDate
        self.userDID = userDID
        self.userHandle = userHandle
        self.totalRecordCount = totalRecordCount
        self.successfullyParsedCount = successfullyParsedCount
        self.failedParseCount = failedParseCount
        self.unknownRecordTypeCount = unknownRecordTypeCount
        self.parsingStatus = parsingStatus
        self.parsingErrorMessage = parsingErrorMessage
        self.parsingConfidenceScore = parsingConfidenceScore
        self.parsingLogs = parsingLogs
        self.parsingLogFileURL = parsingLogFileURL
        self.originalCarSize = originalCarSize
        self.repositoryCommit = repositoryCommit
        self.repositoryLastModified = repositoryLastModified
        self.parsingStatistics = parsingStatistics
        self.hasMediaReferences = hasMediaReferences
        self.postCount = postCount
        self.profileCount = profileCount
        self.connectionCount = connectionCount
        self.mediaCount = mediaCount
    }
    
    /// Human-readable parsing success rate
    var successRate: String {
        guard totalRecordCount > 0 else { return "N/A" }
        let percentage = (Double(successfullyParsedCount) / Double(totalRecordCount)) * 100
        return String(format: "%.1f%%", percentage)
    }
    
    /// Age of parsing as a formatted string
    var parsingAgeDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: parsedDate, relativeTo: Date())
    }
    
    /// Whether this parsing is considered reliable
    var isParsingReliable: Bool {
        return parsingConfidenceScore >= 0.8 && parsingStatus == .completed
    }
}

/// 🧪 EXPERIMENTAL: Represents a parsed AT Protocol record using Petrel data structures
/// This stores the actual AT Protocol records as ATProtocolValueContainer instances
@Model
final class ParsedATProtocolRecord: @unchecked Sendable {
    /// Unique identifier
    @Attribute(.unique) var id: UUID
    
    /// Reference to the repository record this belongs to
    var repositoryRecordID: UUID
    
    /// AT Protocol record URI (e.g., at://did:plc:abc/app.bsky.feed.post/123)
    var recordURI: String
    
    /// Record key (rkey)
    var recordKey: String
    
    /// AT Protocol collection type (e.g., app.bsky.feed.post)
    var collectionType: String
    
    /// The actual AT Protocol record data as encoded Data
    /// This contains the ATProtocolValueContainer with the parsed record
    var recordData: Data
    
    /// CID of the record
    var recordCID: String
    
    /// Date when record was created (from the record itself)
    var createdAt: Date?
    
    /// Date when this record was parsed from CAR
    var parsedAt: Date
    
    /// Whether parsing was successful
    var parseSuccessful: Bool
    
    /// Parse confidence score (0.0 - 1.0)
    var parseConfidence: Double
    
    /// Error message if parsing failed
    var parseError: String?
    
    /// Raw CBOR data for debugging
    var rawCBORData: Data?
    
    init(
        id: UUID = UUID(),
        repositoryRecordID: UUID,
        recordURI: String,
        recordKey: String,
        collectionType: String,
        recordData: Data,
        recordCID: String,
        createdAt: Date? = nil,
        parsedAt: Date = Date(),
        parseSuccessful: Bool,
        parseConfidence: Double,
        parseError: String? = nil,
        rawCBORData: Data? = nil
    ) {
        self.id = id
        self.repositoryRecordID = repositoryRecordID
        self.recordURI = recordURI
        self.recordKey = recordKey
        self.collectionType = collectionType
        self.recordData = recordData
        self.recordCID = recordCID
        self.createdAt = createdAt
        self.parsedAt = parsedAt
        self.parseSuccessful = parseSuccessful
        self.parseConfidence = parseConfidence
        self.parseError = parseError
        self.rawCBORData = rawCBORData
    }
    
    /// Decode the stored AT Protocol record back to ATProtocolValueContainer
    func getATProtocolRecord() throws -> ATProtocolValueContainer {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ATProtocolValueContainer.self, from: recordData)
    }
    
    /// Helper to get the record as a specific AT Protocol type
    func getRecord<T: ATProtocolCodable>() throws -> T {
        let container = try getATProtocolRecord()
        
        // Use the correct pattern to unwrap ATProtocolValueContainer
        if case .knownType(let value) = container,
           let record = value as? T {
            return record
        }
        
        throw RepositoryParsingError.invalidRecordData("Failed to cast record to \(T.self)")
    }
}

/// 🧪 EXPERIMENTAL: Represents a parsed post from the repository
@Model
final class ParsedPost: @unchecked Sendable {
    /// Unique identifier
    @Attribute(.unique) var id: UUID
    
    /// Reference to repository record
    var repositoryRecordID: UUID
    
    /// AT Protocol record key (rkey)
    var recordKey: String
    
    /// Post content/text
    var text: String
    
    /// Creation date from the record
    var createdAt: Date
    
    /// Reply information if this is a reply
    var replyToRecordKey: String?
    var replyToUserDID: String?
    
    /// Quote post information if applicable
    var quotedRecordKey: String?
    var quotedUserDID: String?
    
    /// Languages detected in the post
    var languages: String // JSON array of language codes
    
    /// Facets/rich text information as JSON
    var facets: String
    
    /// Embed information as JSON
    var embeds: String
    
    /// Self-declared labels as JSON
    var selfLabels: String
    
    /// Raw CBOR data for debugging
    var rawCBORData: Data
    
    /// CID of this record
    var recordCID: String
    
    /// Whether parsing was successful
    var parseSuccessful: Bool
    
    /// Parse error message if any
    var parseErrorMessage: String?
    
    /// Parsing confidence for this record
    var parseConfidence: Double
    
    /// Media attachment count
    var mediaAttachmentCount: Int
    
    /// Whether this post has external links
    var hasExternalLinks: Bool
    
    /// Whether this post mentions other users
    var hasMentions: Bool
    
    /// Whether this post has hashtags
    var hasHashtags: Bool
    
    init(
        id: UUID = UUID(),
        repositoryRecordID: UUID,
        recordKey: String,
        text: String,
        createdAt: Date,
        replyToRecordKey: String? = nil,
        replyToUserDID: String? = nil,
        quotedRecordKey: String? = nil,
        quotedUserDID: String? = nil,
        languages: String = "[]",
        facets: String = "[]",
        embeds: String = "[]",
        selfLabels: String = "[]",
        rawCBORData: Data,
        recordCID: String,
        parseSuccessful: Bool = true,
        parseErrorMessage: String? = nil,
        parseConfidence: Double = 1.0,
        mediaAttachmentCount: Int = 0,
        hasExternalLinks: Bool = false,
        hasMentions: Bool = false,
        hasHashtags: Bool = false
    ) {
        self.id = id
        self.repositoryRecordID = repositoryRecordID
        self.recordKey = recordKey
        self.text = text
        self.createdAt = createdAt
        self.replyToRecordKey = replyToRecordKey
        self.replyToUserDID = replyToUserDID
        self.quotedRecordKey = quotedRecordKey
        self.quotedUserDID = quotedUserDID
        self.languages = languages
        self.facets = facets
        self.embeds = embeds
        self.selfLabels = selfLabels
        self.rawCBORData = rawCBORData
        self.recordCID = recordCID
        self.parseSuccessful = parseSuccessful
        self.parseErrorMessage = parseErrorMessage
        self.parseConfidence = parseConfidence
        self.mediaAttachmentCount = mediaAttachmentCount
        self.hasExternalLinks = hasExternalLinks
        self.hasMentions = hasMentions
        self.hasHashtags = hasHashtags
    }
    
    /// Age of post as a formatted string
    var ageDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: createdAt, relativeTo: Date())
    }
    
    /// Post type based on reply/quote status
    var postType: String {
        if replyToRecordKey != nil {
            return "Reply"
        } else if quotedRecordKey != nil {
            return "Quote Post"
        } else {
            return "Original Post"
        }
    }
}

/// 🧪 EXPERIMENTAL: Represents a parsed profile from the repository
@Model
final class ParsedProfile: @unchecked Sendable {
    /// Unique identifier
    @Attribute(.unique) var id: UUID
    
    /// Reference to repository record
    var repositoryRecordID: UUID
    
    /// AT Protocol record key (should be "self" for profiles)
    var recordKey: String
    
    /// Display name
    var displayName: String?
    
    /// Profile description/bio
    var profileDescription: String?
    
    /// Avatar image reference
    var avatarRef: String?
    
    /// Banner image reference
    var bannerRef: String?
    
    /// Profile labels as JSON
    var labels: String
    
    /// Join date if available
    var joinedViaStarterPack: String?
    
    /// Pinned post reference
    var pinnedPost: String?
    
    /// Raw CBOR data for debugging
    var rawCBORData: Data
    
    /// CID of this record
    var recordCID: String
    
    /// Whether parsing was successful
    var parseSuccessful: Bool
    
    /// Parse error message if any
    var parseErrorMessage: String?
    
    /// Parsing confidence for this record
    var parseConfidence: Double
    
    /// Creation/update date from the record
    var updatedAt: Date
    
    init(
        id: UUID = UUID(),
        repositoryRecordID: UUID,
        recordKey: String,
        displayName: String? = nil,
        description: String? = nil,
        avatarRef: String? = nil,
        bannerRef: String? = nil,
        labels: String = "[]",
        joinedViaStarterPack: String? = nil,
        pinnedPost: String? = nil,
        rawCBORData: Data,
        recordCID: String,
        parseSuccessful: Bool = true,
        parseErrorMessage: String? = nil,
        parseConfidence: Double = 1.0,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.repositoryRecordID = repositoryRecordID
        self.recordKey = recordKey
        self.displayName = displayName
        self.profileDescription = description
        self.avatarRef = avatarRef
        self.bannerRef = bannerRef
        self.labels = labels
        self.joinedViaStarterPack = joinedViaStarterPack
        self.pinnedPost = pinnedPost
        self.rawCBORData = rawCBORData
        self.recordCID = recordCID
        self.parseSuccessful = parseSuccessful
        self.parseErrorMessage = parseErrorMessage
        self.parseConfidence = parseConfidence
        self.updatedAt = updatedAt
    }
}

/// 🧪 EXPERIMENTAL: Represents parsed media references from the repository
@Model
final class ParsedMedia: @unchecked Sendable {
    /// Unique identifier
    @Attribute(.unique) var id: UUID
    
    /// Reference to repository record
    var repositoryRecordID: UUID
    
    /// AT Protocol record key where this media was found
    var recordKey: String
    
    /// Media type (image, video, etc.)
    var mediaType: String
    
    /// MIME type if available
    var mimeType: String?
    
    /// Media size in bytes if available
    var size: Int64?
    
    /// CID reference to the media blob
    var blobCID: String
    
    /// Alt text if provided
    var altText: String?
    
    /// Aspect ratio if available
    var aspectRatio: String?
    
    /// Raw CBOR data for debugging
    var rawCBORData: Data
    
    /// Whether parsing was successful
    var parseSuccessful: Bool
    
    /// Parse error message if any
    var parseErrorMessage: String?
    
    /// Parsing confidence for this record
    var parseConfidence: Double
    
    /// Date when this media reference was found
    var discoveredAt: Date
    
    init(
        id: UUID = UUID(),
        repositoryRecordID: UUID,
        recordKey: String,
        mediaType: String,
        mimeType: String? = nil,
        size: Int64? = nil,
        blobCID: String,
        altText: String? = nil,
        aspectRatio: String? = nil,
        rawCBORData: Data,
        parseSuccessful: Bool = true,
        parseErrorMessage: String? = nil,
        parseConfidence: Double = 1.0,
        discoveredAt: Date = Date()
    ) {
        self.id = id
        self.repositoryRecordID = repositoryRecordID
        self.recordKey = recordKey
        self.mediaType = mediaType
        self.mimeType = mimeType
        self.size = size
        self.blobCID = blobCID
        self.altText = altText
        self.aspectRatio = aspectRatio
        self.rawCBORData = rawCBORData
        self.parseSuccessful = parseSuccessful
        self.parseErrorMessage = parseErrorMessage
        self.parseConfidence = parseConfidence
        self.discoveredAt = discoveredAt
    }
    
    /// Human-readable media size
    var formattedSize: String {
        guard let size = size else { return "Unknown size" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// 🧪 EXPERIMENTAL: Represents parsed social connections (follows/followers)
@Model
final class ParsedConnection: @unchecked Sendable {
    /// Unique identifier
    @Attribute(.unique) var id: UUID
    
    /// Reference to repository record
    var repositoryRecordID: UUID
    
    /// AT Protocol record key
    var recordKey: String
    
    /// Target user DID being followed
    var targetUserDID: String
    
    /// Connection type (follow, block, mute, etc.)
    var connectionType: String
    
    /// Date when connection was created
    var createdAt: Date
    
    /// Raw CBOR data for debugging
    var rawCBORData: Data
    
    /// CID of this record
    var recordCID: String
    
    /// Whether parsing was successful
    var parseSuccessful: Bool
    
    /// Parse error message if any
    var parseErrorMessage: String?
    
    /// Parsing confidence for this record
    var parseConfidence: Double
    
    init(
        id: UUID = UUID(),
        repositoryRecordID: UUID,
        recordKey: String,
        targetUserDID: String,
        connectionType: String,
        createdAt: Date,
        rawCBORData: Data,
        recordCID: String,
        parseSuccessful: Bool = true,
        parseErrorMessage: String? = nil,
        parseConfidence: Double = 1.0
    ) {
        self.id = id
        self.repositoryRecordID = repositoryRecordID
        self.recordKey = recordKey
        self.targetUserDID = targetUserDID
        self.connectionType = connectionType
        self.createdAt = createdAt
        self.rawCBORData = rawCBORData
        self.recordCID = recordCID
        self.parseSuccessful = parseSuccessful
        self.parseErrorMessage = parseErrorMessage
        self.parseConfidence = parseConfidence
    }
    
    /// Age of connection as a formatted string
    var ageDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: createdAt, relativeTo: Date())
    }
}

/// 🧪 EXPERIMENTAL: Represents unknown/unparsed records for debugging
@Model
final class ParsedUnknownRecord: @unchecked Sendable {
    /// Unique identifier
    @Attribute(.unique) var id: UUID
    
    /// Reference to repository record
    var repositoryRecordID: UUID
    
    /// AT Protocol record key
    var recordKey: String
    
    /// Unknown record type/collection
    var recordType: String
    
    /// Raw CBOR data
    var rawCBORData: Data
    
    /// CID of this record
    var recordCID: String
    
    /// Any parsing attempt error message
    var parseAttemptError: String?
    
    /// Date when this record was discovered
    var discoveredAt: Date
    
    /// Size of raw data
    var dataSize: Int64
    
    init(
        id: UUID = UUID(),
        repositoryRecordID: UUID,
        recordKey: String,
        recordType: String,
        rawCBORData: Data,
        recordCID: String,
        parseAttemptError: String? = nil,
        discoveredAt: Date = Date()
    ) {
        self.id = id
        self.repositoryRecordID = repositoryRecordID
        self.recordKey = recordKey
        self.recordType = recordType
        self.rawCBORData = rawCBORData
        self.recordCID = recordCID
        self.parseAttemptError = parseAttemptError
        self.discoveredAt = discoveredAt
        self.dataSize = Int64(rawCBORData.count)
    }
    
    /// Human-readable data size
    var formattedDataSize: String {
        return ByteCountFormatter.string(fromByteCount: dataSize, countStyle: .file)
    }
}

/// Status of repository parsing operation
enum RepositoryParsingStatus: String, CaseIterable, Codable {
    case notStarted = "not_started"
    case inProgress = "in_progress"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
    case partiallyCompleted = "partially_completed"
    
    var displayName: String {
        switch self {
        case .notStarted:
            return "Not Started"
        case .inProgress:
            return "Parsing..."
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        case .partiallyCompleted:
            return "Partially Completed"
        }
    }
    
    var systemImage: String {
        switch self {
        case .notStarted:
            return "clock"
        case .inProgress:
            return "arrow.clockwise"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .cancelled:
            return "stop.circle.fill"
        case .partiallyCompleted:
            return "exclamationmark.triangle.fill"
        }
    }
    
    var color: String {
        switch self {
        case .notStarted:
            return "gray"
        case .inProgress:
            return "blue"
        case .completed:
            return "green"
        case .failed:
            return "red"
        case .cancelled:
            return "orange"
        case .partiallyCompleted:
            return "yellow"
        }
    }
}
