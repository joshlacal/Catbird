import Foundation
import SwiftData
import OSLog

// MARK: - Value Types for UI Safety

/// Value type representation of RepositoryRecord to avoid ModelContext issues
struct RepositoryData: Identifiable {
    let id: UUID
    let backupRecordID: UUID
    let parsedDate: Date
    let userDID: String
    let userHandle: String
    let totalRecordCount: Int
    let successfullyParsedCount: Int
    let parsingConfidenceScore: Double
    let parsingStatus: RepositoryParsingStatus
    let hasMediaReferences: Bool
    let postCount: Int
    let profileCount: Int
    let connectionCount: Int
    let mediaCount: Int
    
    init(from record: RepositoryRecord) {
        self.id = record.id
        self.backupRecordID = record.backupRecordID
        self.parsedDate = record.parsedDate
        self.userDID = record.userDID
        self.userHandle = record.userHandle
        self.totalRecordCount = record.totalRecordCount
        self.successfullyParsedCount = record.successfullyParsedCount
        self.parsingConfidenceScore = record.parsingConfidenceScore
        self.parsingStatus = record.parsingStatus
        self.hasMediaReferences = record.hasMediaReferences
        self.postCount = record.postCount
        self.profileCount = record.profileCount
        self.connectionCount = record.connectionCount
        self.mediaCount = record.mediaCount
    }
    
    var successRate: String {
        guard totalRecordCount > 0 else { return "0%" }
        let percentage = Double(successfullyParsedCount) / Double(totalRecordCount) * 100
        return String(format: "%.1f%%", percentage)
    }
    
    var parsingAgeDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: parsedDate, relativeTo: Date())
    }
}

/// Value type representation of BackupRecord to avoid ModelContext issues
struct BackupData: Identifiable {
    let id: UUID
    let createdDate: Date
    let userDID: String
    let userHandle: String
    let fileSize: Int64
    let status: BackupStatus?
    
    init(from record: BackupRecord) {
        self.id = record.id
        self.createdDate = record.createdDate
        self.userDID = record.userDID
        self.userHandle = record.userHandle
        self.fileSize = record.fileSize
        self.status = record.status
    }
}

// MARK: - ⚠️ EXPERIMENTAL REPOSITORY BROWSER VIEW MODEL ⚠️

/// 🧪 EXPERIMENTAL: ViewModel for browsing parsed repository data
/// ⚠️ This is experimental functionality for exploring backup CAR data
@MainActor
@Observable
final class RepositoryBrowserViewModel {
    
    // MARK: - Properties
    
    /// Model context for SwiftData operations
    private let modelContext: ModelContext
    
    /// Logger for debugging
    private let logger = Logger(subsystem: "Catbird", category: "RepositoryBrowser")
    
    /// Available repository records (stored as value types to avoid ModelContext issues)
    var repositoryData: [RepositoryData] = []
    
    /// Available backup records (stored as value types to avoid ModelContext issues)  
    var backupData: [BackupData] = []
    
    /// Loading state
    var isLoading = false
    
    /// Error state
    var errorMessage: String?
    
    /// Search query across all data
    var searchQuery: String = ""
    
    /// Selected repository for browsing
    var selectedRepository: RepositoryData?
    
    /// Current tab selection
    var selectedTab: BrowserTab = .overview
    
    /// Date filter range
    var dateFilterStart: Date?
    var dateFilterEnd: Date?
    
    /// Data type filter
    var dataTypeFilter: DataTypeFilter = .all
    
    /// Sort order
    var sortOrder: SortOrder = .dateDescending
    
    /// Export settings
    var isExporting = false
    var exportProgress: Double = 0.0
    
    // MARK: - Initialization
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        loadRepositories()
    }
    
    // MARK: - Repository Management
    
    /// Load all available repository records and backup records
    func loadRepositories() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                // Create BackupModelActor for consistent access to backup records
                let backupActor = BackupModelActor(modelContainer: modelContext.container)
                
                // Load backup records through actor to ensure consistency
                let loadedBackupRecords = try await backupActor.fetchAllBackupRecords()
                self.logger.info("BackupModelActor found \(loadedBackupRecords.count) backup records")
                
                // Create actor for repository record operations only
                let repositoryActor = RepositoryModelActor(modelContainer: modelContext.container)
                
                // Load parsed repository records
                let loadedRepositories = try await repositoryActor.loadAllRepositoryRecords()
                
                await MainActor.run {
                    // Convert to value types to avoid ModelContext issues
                    self.repositoryData = loadedRepositories.map { RepositoryData(from: $0) }
                    self.logger.info("Loaded \(self.repositoryData.count) repository records")
                    
                    // Filter out backup records that already have corresponding repository records
                    let parsedBackupIDs = Set(loadedRepositories.map { $0.backupRecordID })
                    let filteredBackups = loadedBackupRecords.filter { !parsedBackupIDs.contains($0.id) }
                    self.backupData = filteredBackups.map { BackupData(from: $0) }
                    self.logger.info("Loaded \(loadedBackupRecords.count) backup records total, \(self.backupData.count) unparsed")
                    
                    // Log details about the backup records for debugging
                    for (index, backup) in loadedBackupRecords.enumerated() {
                        self.logger.debug("Backup \(index): ID=\(backup.id), userDID=\(backup.userDID), handle=\(backup.userHandle)")
                    }
                    
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.logger.error("Failed to load repositories and backups: \(error.localizedDescription)")
                    self.errorMessage = "Failed to load repository data: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }
    
    /// Refresh repository data
    func refresh() {
        Task {
            await MainActor.run {
                loadRepositories()
            }
        }
    }
    
    /// Select a repository for detailed browsing
    func selectRepository(_ repository: RepositoryData) {
        selectedRepository = repository
        selectedTab = .overview
        logger.info("Selected repository: \(repository.userHandle) (\(repository.id))")
    }
    
    // MARK: - Search and Filtering
    
    /// Apply search filter to repositories
    var filteredRepositories: [RepositoryData] {
        var filtered = repositoryData
        
        // Apply search query
        if !searchQuery.isEmpty {
            filtered = filtered.filter { repository in
                repository.userHandle.localizedCaseInsensitiveContains(searchQuery) ||
                repository.userDID.localizedCaseInsensitiveContains(searchQuery)
            }
        }
        
        // Apply date filter
        if let startDate = dateFilterStart {
            filtered = filtered.filter { $0.parsedDate >= startDate }
        }
        
        if let endDate = dateFilterEnd {
            filtered = filtered.filter { $0.parsedDate <= endDate }
        }
        
        return filtered
    }
    
    /// Apply search filter to backup records
    var filteredBackupRecords: [BackupData] {
        var filtered = backupData
        
        // Apply search query
        if !searchQuery.isEmpty {
            filtered = filtered.filter { backup in
                backup.userHandle.localizedCaseInsensitiveContains(searchQuery) ||
                backup.userDID.localizedCaseInsensitiveContains(searchQuery)
            }
        }
        
        // Apply date filter
        if let startDate = dateFilterStart {
            filtered = filtered.filter { $0.createdDate >= startDate }
        }
        
        if let endDate = dateFilterEnd {
            filtered = filtered.filter { $0.createdDate <= endDate }
        }
        
        return filtered
    }
    
    /// Clear all filters
    func clearFilters() {
        searchQuery = ""
        dateFilterStart = nil
        dateFilterEnd = nil
        dataTypeFilter = .all
    }
    
    // MARK: - Data Export
    
    /// Export repository data
    func exportRepositoryData(_ repository: RepositoryData, format: ExportFormat) async throws -> URL {
        isExporting = true
        exportProgress = 0.0
        
        defer {
            isExporting = false
            exportProgress = 0.0
        }
        
        let tempDirectory = FileManager.default.temporaryDirectory
        let fileName = "catbird_repository_\(repository.userHandle)_\(Date().timeIntervalSince1970)"
        let fileURL = tempDirectory.appendingPathComponent("\(fileName).\(format.fileExtension)")
        
        // Use ModelActor to fetch fresh data for export
        let repositoryActor = RepositoryModelActor(modelContainer: modelContext.container)
        
        switch format {
        case .json:
            try await exportAsJSON(repository: repository, to: fileURL, using: repositoryActor)
        case .csv:
            try await exportAsCSV(repository: repository, to: fileURL, using: repositoryActor)
        case .html:
            try await exportAsHTML(repository: repository, to: fileURL, using: repositoryActor)
        }
        
        logger.info("Exported repository data to: \(fileURL.path)")
        return fileURL
    }
    
    private func exportAsJSON(repository: RepositoryData, to fileURL: URL, using repositoryActor: RepositoryModelActor) async throws {
        // Implementation for JSON export
        exportProgress = 0.3
        
        // Fetch fresh data from the database using the actor
        let repositoryRecord = try await repositoryActor.findRepositoryRecord(for: repository.backupRecordID)
        guard let repositoryRecord = repositoryRecord else {
            throw RepositoryParsingError.backupRecordNotFound
        }
        
        let posts = try await fetchPosts(for: repositoryRecord, using: repositoryActor)
        let profiles = try await fetchProfiles(for: repositoryRecord, using: repositoryActor)
        let connections = try await fetchConnections(for: repositoryRecord, using: repositoryActor)
        let media = try await fetchMedia(for: repositoryRecord, using: repositoryActor)
        
        let exportData = RepositoryExportData(
            repository: repositoryRecord,
            posts: posts,
            profiles: profiles,
            connections: connections,
            media: media
        )
        
        exportProgress = 0.8
        
        let jsonData = try JSONEncoder().encode(exportData)
        try jsonData.write(to: fileURL)
        
        exportProgress = 1.0
    }
    
    private func exportAsCSV(repository: RepositoryData, to fileURL: URL, using repositoryActor: RepositoryModelActor) async throws {
        // Implementation for CSV export
        exportProgress = 0.3
        
        // Fetch fresh data from the database using the actor
        let repositoryRecord = try await repositoryActor.findRepositoryRecord(for: repository.backupRecordID)
        guard let repositoryRecord = repositoryRecord else {
            throw RepositoryParsingError.backupRecordNotFound
        }
        
        let posts = try await fetchPosts(for: repositoryRecord, using: repositoryActor)
        var csvContent = "Date,Type,Content,Reply To,Quote,Media Count\n"
        
        for post in posts {
            let line = "\(post.createdAt),\(post.postType),\"\(post.text.replacingOccurrences(of: "\"", with: "\"\""))\",\(post.replyToRecordKey ?? ""),\(post.quotedRecordKey ?? ""),\(post.mediaAttachmentCount)\n"
            csvContent += line
        }
        
        exportProgress = 0.8
        
        try csvContent.write(to: fileURL, atomically: true, encoding: .utf8)
        
        exportProgress = 1.0
    }
    
    private func exportAsHTML(repository: RepositoryData, to fileURL: URL, using repositoryActor: RepositoryModelActor) async throws {
        // Implementation for HTML export
        exportProgress = 0.3
        
        // Fetch fresh data from the database using the actor
        let repositoryRecord = try await repositoryActor.findRepositoryRecord(for: repository.backupRecordID)
        guard let repositoryRecord = repositoryRecord else {
            throw RepositoryParsingError.backupRecordNotFound
        }
        
        let posts = try await fetchPosts(for: repositoryRecord, using: repositoryActor)
        _ = try await fetchProfiles(for: repositoryRecord, using: repositoryActor)
        
        var htmlContent = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>Repository Export - \(repository.userHandle)</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 40px; }
                .post { border: 1px solid #ddd; padding: 15px; margin: 10px 0; border-radius: 8px; }
                .date { color: #666; font-size: 0.9em; }
                .experimental { background: #fff3cd; padding: 10px; border-radius: 4px; margin-bottom: 20px; }
            </style>
        </head>
        <body>
            <div class="experimental">
                ⚠️ <strong>EXPERIMENTAL DATA:</strong> This export contains experimental parsing results. 
                Accuracy and completeness are not guaranteed.
            </div>
            <h1>Repository Export: \(repository.userHandle)</h1>
            <p>Exported on \(Date())</p>
            <h2>Posts (\(posts.count))</h2>
        """
        
        exportProgress = 0.5
        
        for post in posts.prefix(100) { // Limit to prevent huge files
            htmlContent += """
            <div class="post">
                <div class="date">\(post.createdAt) - \(post.postType)</div>
                <p>\(post.text)</p>
            </div>
            """
        }
        
        htmlContent += """
        </body>
        </html>
        """
        
        exportProgress = 0.8
        
        try htmlContent.write(to: fileURL, atomically: true, encoding: .utf8)
        
        exportProgress = 1.0
    }
    
    // MARK: - Data Fetching Helpers (Direct ModelContext access for UI consistency)
    
    private func fetchPosts(for repository: RepositoryRecord, using repositoryActor: RepositoryModelActor) async throws -> [ParsedPost] {
        // Use direct ModelContext access to ensure UI consistency
        let repositoryID = repository.id
        let descriptor = FetchDescriptor<ParsedPost>(
            predicate: #Predicate { post in
                post.repositoryRecordID == repositoryID
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }
    
    private func fetchProfiles(for repository: RepositoryRecord, using repositoryActor: RepositoryModelActor) async throws -> [ParsedProfile] {
        let repositoryID = repository.id
        let descriptor = FetchDescriptor<ParsedProfile>(
            predicate: #Predicate { profile in
                profile.repositoryRecordID == repositoryID
            }
        )
        return try modelContext.fetch(descriptor)
    }
    
    private func fetchConnections(for repository: RepositoryRecord, using repositoryActor: RepositoryModelActor) async throws -> [ParsedConnection] {
        let repositoryID = repository.id
        let descriptor = FetchDescriptor<ParsedConnection>(
            predicate: #Predicate { connection in
                connection.repositoryRecordID == repositoryID
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }
    
    private func fetchMedia(for repository: RepositoryRecord, using repositoryActor: RepositoryModelActor) async throws -> [ParsedMedia] {
        let repositoryID = repository.id
        let descriptor = FetchDescriptor<ParsedMedia>(
            predicate: #Predicate { media in
                media.repositoryRecordID == repositoryID
            },
            sortBy: [SortDescriptor(\.discoveredAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }
}

// MARK: - Supporting Types

enum BrowserTab: String, CaseIterable {
    case overview = "Overview"
    case timeline = "Timeline"
    case connections = "Connections"
    case media = "Media"
    case search = "Search"
    case export = "Export"
    
    var systemImage: String {
        switch self {
        case .overview:
            return "info.circle"
        case .timeline:
            return "calendar"
        case .connections:
            return "person.2"
        case .media:
            return "photo.stack"
        case .search:
            return "magnifyingglass"
        case .export:
            return "square.and.arrow.up"
        }
    }
}

enum DataTypeFilter: String, CaseIterable {
    case all = "All"
    case posts = "Posts"
    case profiles = "Profiles"
    case connections = "Connections"
    case media = "Media"
    case unknown = "Unknown"
}

enum SortOrder: String, CaseIterable {
    case dateAscending = "Date (Oldest First)"
    case dateDescending = "Date (Newest First)"
    case alphabetical = "Alphabetical"
    case confidence = "Parse Confidence"
    
    var systemImage: String {
        switch self {
        case .dateAscending:
            return "arrow.up"
        case .dateDescending:
            return "arrow.down"
        case .alphabetical:
            return "textformat"
        case .confidence:
            return "checkmark.circle"
        }
    }
}

// MARK: - Export Data Structure

struct RepositoryExportData: Codable {
    let repository: RepositoryExportInfo
    let posts: [ParsedPostExport]
    let profiles: [ParsedProfileExport]
    let connections: [ParsedConnectionExport]
    let media: [ParsedMediaExport]
    let exportedAt: Date
    let warning: String
    
    init(repository: RepositoryRecord, posts: [ParsedPost], profiles: [ParsedProfile], connections: [ParsedConnection], media: [ParsedMedia]) {
        self.repository = RepositoryExportInfo(repository)
        self.posts = posts.map(ParsedPostExport.init)
        self.profiles = profiles.map(ParsedProfileExport.init)
        self.connections = connections.map(ParsedConnectionExport.init)
        self.media = media.map(ParsedMediaExport.init)
        self.exportedAt = Date()
        self.warning = "⚠️ EXPERIMENTAL DATA: This export contains experimental parsing results. Accuracy and completeness are not guaranteed."
    }
}

struct RepositoryExportInfo: Codable {
    let userDID: String
    let userHandle: String
    let parsedDate: Date
    let totalRecordCount: Int
    let successfullyParsedCount: Int
    let parsingConfidenceScore: Double
    
    init(_ repository: RepositoryRecord) {
        self.userDID = repository.userDID
        self.userHandle = repository.userHandle
        self.parsedDate = repository.parsedDate
        self.totalRecordCount = repository.totalRecordCount
        self.successfullyParsedCount = repository.successfullyParsedCount
        self.parsingConfidenceScore = repository.parsingConfidenceScore
    }
}

struct ParsedPostExport: Codable {
    let recordKey: String
    let text: String
    let createdAt: Date
    let postType: String
    let replyToRecordKey: String?
    let quotedRecordKey: String?
    let mediaAttachmentCount: Int
    let parseConfidence: Double
    let parseSuccessful: Bool
    
    init(_ post: ParsedPost) {
        self.recordKey = post.recordKey
        self.text = post.text
        self.createdAt = post.createdAt
        self.postType = post.postType
        self.replyToRecordKey = post.replyToRecordKey
        self.quotedRecordKey = post.quotedRecordKey
        self.mediaAttachmentCount = post.mediaAttachmentCount
        self.parseConfidence = post.parseConfidence
        self.parseSuccessful = post.parseSuccessful
    }
}

struct ParsedProfileExport: Codable {
    let displayName: String?
    let description: String?
    let updatedAt: Date
    let parseConfidence: Double
    
    init(_ profile: ParsedProfile) {
        self.displayName = profile.displayName
        self.description = profile.profileDescription
        self.updatedAt = profile.updatedAt
        self.parseConfidence = profile.parseConfidence
    }
}

struct ParsedConnectionExport: Codable {
    let targetUserDID: String
    let connectionType: String
    let createdAt: Date
    let parseConfidence: Double
    let parseSuccessful: Bool
    
    init(_ connection: ParsedConnection) {
        self.targetUserDID = connection.targetUserDID
        self.connectionType = connection.connectionType
        self.createdAt = connection.createdAt
        self.parseConfidence = connection.parseConfidence
        self.parseSuccessful = connection.parseSuccessful
    }
}

struct ParsedMediaExport: Codable {
    let mediaType: String
    let mimeType: String?
    let altText: String?
    let discoveredAt: Date
    let parseConfidence: Double
    let parseSuccessful: Bool
    
    init(_ media: ParsedMedia) {
        self.mediaType = media.mediaType
        self.mimeType = media.mimeType
        self.altText = media.altText
        self.discoveredAt = media.discoveredAt
        self.parseConfidence = media.parseConfidence
        self.parseSuccessful = media.parseSuccessful
    }
}
