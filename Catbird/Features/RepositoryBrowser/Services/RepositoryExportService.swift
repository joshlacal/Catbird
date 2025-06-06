import Foundation
import SwiftData
import OSLog

// MARK: - ⚠️ EXPERIMENTAL REPOSITORY EXPORT SERVICE ⚠️

/// 🧪 EXPERIMENTAL: Service for exporting repository data in various formats
/// ⚠️ This exports experimental parsing results with privacy safeguards
@MainActor
final class RepositoryExportService {
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "Catbird", category: "RepositoryExport")
    
    // MARK: - Export Methods
    
    /// Export complete repository data
    func exportRepository(
        _ repository: RepositoryRecord,
        format: ExportFormat,
        modelContext: ModelContext,
        progressHandler: @escaping (Double) -> Void = { _ in }
    ) async throws -> URL {
        logger.info("Starting repository export for \(repository.userHandle) in \(format.rawValue) format")
        
        progressHandler(0.1)
        
        // Fetch all data types
        let posts = try await fetchPosts(for: repository, context: modelContext)
        progressHandler(0.3)
        
        let connections = try await fetchConnections(for: repository, context: modelContext)
        progressHandler(0.5)
        
        let media = try await fetchMedia(for: repository, context: modelContext)
        progressHandler(0.6)
        
        let profiles = try await fetchProfiles(for: repository, context: modelContext)
        progressHandler(0.7)
        
        // Generate export
        let exportData = RepositoryExportData(
            repository: repository,
            posts: posts,
            profiles: profiles,
            connections: connections,
            media: media
        )
        
        progressHandler(0.8)
        
        // Create export file
        let fileURL = try await createExportFile(exportData, format: format)
        progressHandler(1.0)
        
        logger.info("Repository export completed: \(fileURL.path)")
        return fileURL
    }
    
    /// Export filtered data based on criteria
    func exportFiltered(
        repository: RepositoryRecord,
        criteria: ExportCriteria,
        format: ExportFormat,
        modelContext: ModelContext,
        progressHandler: @escaping (Double) -> Void = { _ in }
    ) async throws -> URL {
        logger.info("Starting filtered export for \(repository.userHandle)")
        
        progressHandler(0.1)
        
        var posts: [ParsedPost] = []
        var connections: [ParsedConnection] = []
        var media: [ParsedMedia] = []
        var profiles: [ParsedProfile] = []
        
        // Fetch based on criteria
        if criteria.includePosts {
            posts = try await fetchFilteredPosts(for: repository, criteria: criteria, context: modelContext)
            progressHandler(0.3)
        }
        
        if criteria.includeConnections {
            connections = try await fetchFilteredConnections(for: repository, criteria: criteria, context: modelContext)
            progressHandler(0.5)
        }
        
        if criteria.includeMedia {
            media = try await fetchFilteredMedia(for: repository, criteria: criteria, context: modelContext)
            progressHandler(0.7)
        }
        
        if criteria.includeProfiles {
            profiles = try await fetchFilteredProfiles(for: repository, criteria: criteria, context: modelContext)
            progressHandler(0.8)
        }
        
        let exportData = RepositoryExportData(
            repository: repository,
            posts: posts,
            profiles: profiles,
            connections: connections,
            media: media
        )
        
        let fileURL = try await createExportFile(exportData, format: format)
        progressHandler(1.0)
        
        return fileURL
    }
    
    // MARK: - Data Fetching
    
    private func fetchPosts(for repository: RepositoryRecord, context: ModelContext) async throws -> [ParsedPost] {
        let descriptor = FetchDescriptor<ParsedPost>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let allPosts = try context.fetch(descriptor)
        return allPosts.filter { $0.repositoryRecordID == repository.id }
    }
    
    private func fetchConnections(for repository: RepositoryRecord, context: ModelContext) async throws -> [ParsedConnection] {
        let descriptor = FetchDescriptor<ParsedConnection>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let allConnections = try context.fetch(descriptor)
        return allConnections.filter { $0.repositoryRecordID == repository.id }
    }
    
    private func fetchMedia(for repository: RepositoryRecord, context: ModelContext) async throws -> [ParsedMedia] {
        let descriptor = FetchDescriptor<ParsedMedia>()
        let allMedia = try context.fetch(descriptor)
        return allMedia.filter { $0.repositoryRecordID == repository.id }
    }
    
    private func fetchProfiles(for repository: RepositoryRecord, context: ModelContext) async throws -> [ParsedProfile] {
        let descriptor = FetchDescriptor<ParsedProfile>()
        let allProfiles = try context.fetch(descriptor)
        return allProfiles.filter { $0.repositoryRecordID == repository.id }
    }
    
    // MARK: - Filtered Fetching
    
    private func fetchFilteredPosts(
        for repository: RepositoryRecord,
        criteria: ExportCriteria,
        context: ModelContext
    ) async throws -> [ParsedPost] {
        let descriptor = FetchDescriptor<ParsedPost>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        
        let allPosts = try context.fetch(descriptor)
        
        return allPosts.filter { post in
            // Repository filter
            guard post.repositoryRecordID == repository.id else { return false }
            
            // Date range filter
            if let startDate = criteria.dateRange?.lowerBound {
                guard post.createdAt >= startDate else { return false }
            }
            
            if let endDate = criteria.dateRange?.upperBound {
                guard post.createdAt <= endDate else { return false }
            }
            
            // Confidence filter
            if criteria.minimumConfidence > 0 {
                guard post.parseConfidence >= criteria.minimumConfidence else { return false }
            }
            
            // Parse success filter
            if !criteria.includeParseErrors {
                guard post.parseSuccessful == true else { return false }
            }
            
            return true
        }
    }
    
    private func fetchFilteredConnections(
        for repository: RepositoryRecord,
        criteria: ExportCriteria,
        context: ModelContext
    ) async throws -> [ParsedConnection] {
        let descriptor = FetchDescriptor<ParsedConnection>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        
        let allConnections = try context.fetch(descriptor)
        
        return allConnections.filter { connection in
            // Repository filter
            guard connection.repositoryRecordID == repository.id else { return false }
            
            // Date range filter
            if let startDate = criteria.dateRange?.lowerBound {
                guard connection.createdAt >= startDate else { return false }
            }
            
            if let endDate = criteria.dateRange?.upperBound {
                guard connection.createdAt <= endDate else { return false }
            }
            
            // Confidence filter
            if criteria.minimumConfidence > 0 {
                guard connection.parseConfidence >= criteria.minimumConfidence else { return false }
            }
            
            // Parse success filter
            if !criteria.includeParseErrors {
                guard connection.parseSuccessful == true else { return false }
            }
            
            return true
        }
    }
    
    private func fetchFilteredMedia(
        for repository: RepositoryRecord,
        criteria: ExportCriteria,
        context: ModelContext
    ) async throws -> [ParsedMedia] {
        let descriptor = FetchDescriptor<ParsedMedia>()
        let allMedia = try context.fetch(descriptor)
        
        return allMedia.filter { media in
            // Repository filter
            guard media.repositoryRecordID == repository.id else { return false }
            
            // Date range filter
            if let startDate = criteria.dateRange?.lowerBound {
                guard media.discoveredAt >= startDate else { return false }
            }
            
            if let endDate = criteria.dateRange?.upperBound {
                guard media.discoveredAt <= endDate else { return false }
            }
            
            // Confidence filter
            if criteria.minimumConfidence > 0 {
                guard media.parseConfidence >= criteria.minimumConfidence else { return false }
            }
            
            // Parse success filter
            if !criteria.includeParseErrors {
                guard media.parseSuccessful == true else { return false }
            }
            
            return true
        }
    }
    
    private func fetchFilteredProfiles(
        for repository: RepositoryRecord,
        criteria: ExportCriteria,
        context: ModelContext
    ) async throws -> [ParsedProfile] {
        let descriptor = FetchDescriptor<ParsedProfile>()
        let allProfiles = try context.fetch(descriptor)
        
        return allProfiles.filter { profile in
            // Repository filter
            guard profile.repositoryRecordID == repository.id else { return false }
            
            // Date range filter
            if let startDate = criteria.dateRange?.lowerBound {
                guard profile.updatedAt >= startDate else { return false }
            }
            
            if let endDate = criteria.dateRange?.upperBound {
                guard profile.updatedAt <= endDate else { return false }
            }
            
            // Confidence filter
            if criteria.minimumConfidence > 0 {
                guard profile.parseConfidence >= criteria.minimumConfidence else { return false }
            }
            
            // Parse success filter
            if !criteria.includeParseErrors {
                guard profile.parseSuccessful == true else { return false }
            }
            
            return true
        }
    }
    
    // MARK: - File Creation
    
    private func createExportFile(
        _ exportData: RepositoryExportData,
        format: ExportFormat
    ) async throws -> URL {
        let tempDirectory = FileManager.default.temporaryDirectory
        let fileName = "catbird_repository_\(exportData.repository.userHandle)_\(Date().timeIntervalSince1970)"
        let fileURL = tempDirectory.appendingPathComponent("\(fileName).\(format.fileExtension)")
        
        switch format {
        case .json:
            try await createJSONFile(exportData, at: fileURL)
        case .csv:
            try await createCSVFile(exportData, at: fileURL)
        case .html:
            try await createHTMLFile(exportData, at: fileURL)
        }
        
        return fileURL
    }
    
    private func createJSONFile(_ exportData: RepositoryExportData, at url: URL) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        let jsonData = try encoder.encode(exportData)
        try jsonData.write(to: url)
    }
    
    private func createCSVFile(_ exportData: RepositoryExportData, at url: URL) async throws {
        var csvContent = ""
        
        // Add header with experimental warning
        csvContent += "# ⚠️ EXPERIMENTAL EXPORT from Catbird Repository Browser\n"
        csvContent += "# Generated: \(Date())\n"
        csvContent += "# Repository: \(exportData.repository.userHandle) (\(exportData.repository.userDID))\n"
        csvContent += "# Warning: This data is from experimental parsing and may be incomplete or inaccurate\n\n"
        
        // Posts section
        if !exportData.posts.isEmpty {
            csvContent += "=== POSTS ===\n"
            csvContent += "Date,Type,Content,Reply To,Quote,Media Count,Confidence,Parse Success\n"
            
            for post in exportData.posts {
                let cleanContent = post.text.replacingOccurrences(of: "\"", with: "\"\"").replacingOccurrences(of: "\n", with: " ")
                csvContent += "\(post.createdAt),\(post.postType),\"\(cleanContent)\",\(post.replyToRecordKey ?? ""),\(post.quotedRecordKey ?? ""),\(post.mediaAttachmentCount),\(post.parseConfidence),\(post.parseSuccessful)\n"
            }
            csvContent += "\n"
        }
        
        // Connections section
        if !exportData.connections.isEmpty {
            csvContent += "=== CONNECTIONS ===\n"
            csvContent += "Date,Type,Target DID,Confidence,Parse Success\n"
            
            for connection in exportData.connections {
                csvContent += "\(connection.createdAt),\(connection.connectionType),\(connection.targetUserDID),\(connection.parseConfidence),\(connection.parseSuccessful)\n"
            }
            csvContent += "\n"
        }
        
        // Media section
        if !exportData.media.isEmpty {
            csvContent += "=== MEDIA ===\n"
            csvContent += "Date,Type,MIME Type,Alt Text,Confidence,Parse Success\n"
            
            for media in exportData.media {
                let cleanAltText = (media.altText ?? "").replacingOccurrences(of: "\"", with: "\"\"")
                csvContent += "\(media.discoveredAt),\(media.mediaType),\(media.mimeType ?? ""),\"\(cleanAltText)\",\(media.parseConfidence),\(media.parseSuccessful)\n"
            }
        }
        
        try csvContent.write(to: url, atomically: true, encoding: .utf8)
    }
    
    private func createHTMLFile(_ exportData: RepositoryExportData, at url: URL) async throws {
        let htmlContent = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Repository Export - \(exportData.repository.userHandle)</title>
            <style>
                body { 
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; 
                    margin: 40px; 
                    line-height: 1.6;
                    color: #333;
                }
                .header {
                    background: #fff3cd;
                    border: 1px solid #ffeaa7;
                    padding: 20px;
                    border-radius: 8px;
                    margin-bottom: 30px;
                }
                .warning {
                    color: #856404;
                    font-weight: bold;
                }
                .section {
                    margin-bottom: 40px;
                }
                .item {
                    border: 1px solid #ddd;
                    padding: 15px;
                    margin: 10px 0;
                    border-radius: 8px;
                    background: #f8f9fa;
                }
                .meta {
                    color: #666;
                    font-size: 0.9em;
                    margin-bottom: 10px;
                }
                .confidence {
                    display: inline-block;
                    padding: 2px 8px;
                    border-radius: 12px;
                    font-size: 0.8em;
                    font-weight: bold;
                }
                .confidence.high { background: #d4edda; color: #155724; }
                .confidence.medium { background: #fff3cd; color: #856404; }
                .confidence.low { background: #f8d7da; color: #721c24; }
                .stats {
                    display: grid;
                    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
                    gap: 20px;
                    margin-bottom: 30px;
                }
                .stat-card {
                    background: #f1f3f4;
                    padding: 20px;
                    border-radius: 8px;
                    text-align: center;
                }
                .stat-value {
                    font-size: 2em;
                    font-weight: bold;
                    color: #1a73e8;
                }
                h1, h2 { color: #1a73e8; }
                h3 { color: #5f6368; }
            </style>
        </head>
        <body>
            <div class="header">
                <div class="warning">⚠️ EXPERIMENTAL DATA EXPORT</div>
                <p>This export contains experimental parsing results from Catbird's Repository Browser. 
                Data accuracy and completeness are not guaranteed. Use for research and backup purposes only.</p>
            </div>
            
            <h1>Repository Export: \(exportData.repository.userHandle)</h1>
            <p><strong>Exported:</strong> \(Date())</p>
            <p><strong>DID:</strong> \(exportData.repository.userDID)</p>
            <p><strong>Parse Date:</strong> \(exportData.repository.parsedDate)</p>
            <p><strong>Success Rate:</strong> \(String(format: "%.1f%%", (Double(exportData.repository.successfullyParsedCount) / Double(exportData.repository.totalRecordCount)) * 100))</p>
            
            <div class="stats">
                <div class="stat-card">
                    <div class="stat-value">\(exportData.posts.count)</div>
                    <div>Posts</div>
                </div>
                <div class="stat-card">
                    <div class="stat-value">\(exportData.connections.count)</div>
                    <div>Connections</div>
                </div>
                <div class="stat-card">
                    <div class="stat-value">\(exportData.media.count)</div>
                    <div>Media Items</div>
                </div>
                <div class="stat-card">
                    <div class="stat-value">\(exportData.profiles.count)</div>
                    <div>Profiles</div>
                </div>
            </div>
            
            \(generatePostsHTML(exportData.posts))
            \(generateConnectionsHTML(exportData.connections))
            \(generateMediaHTML(exportData.media))
            
            <footer style="margin-top: 50px; padding-top: 20px; border-top: 1px solid #ddd; color: #666; font-size: 0.9em;">
                Generated by Catbird Repository Browser (Experimental) - \(Date())
            </footer>
        </body>
        </html>
        """
        
        try htmlContent.write(to: url, atomically: true, encoding: .utf8)
    }
    
    // MARK: - HTML Generation Helpers
    
    private func generatePostsHTML(_ posts: [ParsedPostExport]) -> String {
        guard !posts.isEmpty else { return "" }
        
        var html = """
        <div class="section">
            <h2>Posts (\(posts.count))</h2>
        """
        
        for post in posts.prefix(50) { // Limit to prevent huge files
            let confidenceClass = post.parseConfidence >= 0.8 ? "high" : (post.parseConfidence >= 0.6 ? "medium" : "low")
            
            html += """
            <div class="item">
                <div class="meta">
                    \(post.createdAt) - \(post.postType) 
                    <span class="confidence \(confidenceClass)">
                        \(String(format: "%.0f%%", post.parseConfidence * 100))
                    </span>
                </div>
                <p>\(post.text.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;"))</p>
            </div>
            """
        }
        
        if posts.count > 50 {
            html += "<p><em>Showing first 50 posts of \(posts.count) total.</em></p>"
        }
        
        html += "</div>"
        return html
    }
    
    private func generateConnectionsHTML(_ connections: [ParsedConnectionExport]) -> String {
        guard !connections.isEmpty else { return "" }
        
        var html = """
        <div class="section">
            <h2>Connections (\(connections.count))</h2>
        """
        
        for connection in connections.prefix(100) {
            let confidenceClass = connection.parseConfidence >= 0.8 ? "high" : (connection.parseConfidence >= 0.6 ? "medium" : "low")
            
            html += """
            <div class="item">
                <div class="meta">
                    \(connection.createdAt) - \(connection.connectionType.capitalized) 
                    <span class="confidence \(confidenceClass)">
                        \(String(format: "%.0f%%", connection.parseConfidence * 100))
                    </span>
                </div>
                <p><strong>Target:</strong> \(connection.targetUserDID)</p>
            </div>
            """
        }
        
        if connections.count > 100 {
            html += "<p><em>Showing first 100 connections of \(connections.count) total.</em></p>"
        }
        
        html += "</div>"
        return html
    }
    
    private func generateMediaHTML(_ media: [ParsedMediaExport]) -> String {
        guard !media.isEmpty else { return "" }
        
        var html = """
        <div class="section">
            <h2>Media (\(media.count))</h2>
        """
        
        for mediaItem in media.prefix(50) {
            let confidenceClass = mediaItem.parseConfidence >= 0.8 ? "high" : (mediaItem.parseConfidence >= 0.6 ? "medium" : "low")
            
            html += """
            <div class="item">
                <div class="meta">
                    \(mediaItem.discoveredAt) - \(mediaItem.mediaType) 
                    <span class="confidence \(confidenceClass)">
                        \(String(format: "%.0f%%", mediaItem.parseConfidence * 100))
                    </span>
                </div>
                <p><strong>Type:</strong> \(mediaItem.mimeType ?? "Unknown")</p>
                \(mediaItem.altText.map { "<p><strong>Alt Text:</strong> \($0.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;"))</p>" } ?? "")
            </div>
            """
        }
        
        if media.count > 50 {
            html += "<p><em>Showing first 50 media items of \(media.count) total.</em></p>"
        }
        
        html += "</div>"
        return html
    }
}

// MARK: - Export Configuration

struct ExportCriteria {
    let includePosts: Bool
    let includeConnections: Bool
    let includeMedia: Bool
    let includeProfiles: Bool
    let dateRange: ClosedRange<Date>?
    let minimumConfidence: Double
    let includeParseErrors: Bool
    
    static let `default` = ExportCriteria(
        includePosts: true,
        includeConnections: true,
        includeMedia: true,
        includeProfiles: true,
        dateRange: nil,
        minimumConfidence: 0.0,
        includeParseErrors: false
    )
}

