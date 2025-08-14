import SwiftUI
import SwiftData
import OSLog
import Petrel

// MARK: - ⚠️ EXPERIMENTAL REPOSITORY DIAGNOSTICS ⚠️

/// 🧪 EXPERIMENTAL: Diagnostics view for troubleshooting repository browser issues
/// ⚠️ This provides detailed debugging information about parsed repository data
struct RepositoryDiagnosticsView: View {
    let repository: RepositoryRecord
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var diagnosticsResult: DiagnosticsResult?
    @State private var isRunning = false
    @State private var logs: [String] = []
    @State private var logSource: String = "Unknown"
    
    private let logger = Logger(subsystem: "Catbird", category: "RepositoryDiagnostics")
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "stethoscope")
                                .foregroundColor(.blue)
                            Text("Repository Diagnostics")
                                .font(.title2)
                                .fontWeight(.bold)
                        }
                        
                        Text("Diagnosing parsing and data access for: \(repository.userHandle)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(12)
                    
                    // Repository Info
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Repository Information")
                            .font(.headline)
                        
                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 12) {
                            DiagnosticItem(label: "Repository ID", value: repository.id.uuidString)
                            DiagnosticItem(label: "Backup ID", value: repository.backupRecordID.uuidString)
                            DiagnosticItem(label: "User DID", value: repository.userDID)
                            DiagnosticItem(label: "User Handle", value: repository.userHandle)
                            DiagnosticItem(label: "Parsing Status", value: repository.parsingStatus.displayName)
                            DiagnosticItem(label: "Confidence", value: String(format: "%.1f%%", repository.parsingConfidenceScore * 100))
                            DiagnosticItem(label: "Total Records", value: "\(repository.totalRecordCount)")
                            DiagnosticItem(label: "Successfully Parsed", value: "\(repository.successfullyParsedCount)")
                            DiagnosticItem(label: "Expected Posts", value: "\(repository.postCount)")
                            DiagnosticItem(label: "Expected Connections", value: "\(repository.connectionCount)")
                            DiagnosticItem(label: "Expected Media", value: "\(repository.mediaCount)")
                            DiagnosticItem(label: "Expected Profiles", value: "\(repository.profileCount)")
                        }
                    }
                    
                    // Diagnostics Results
                    if let result = diagnosticsResult {
                        diagnosticsResultsView(result)
                    }
                    
                    // Logs Status 
                    if !logs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Diagnostic Logs")
                                .font(.headline)
                            
                            Text("Logs captured: \(logs.count) entries")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            HStack {
                                Text("Log source:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(logSource)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                            }
                            
                            if repository.parsingLogFileURL != nil {
                                Text("📁 Parsing logs are stored in file to prevent memory issues. Log analysis results shown above.")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                                    .padding()
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(8)
                            } else {
                                Text("⚠️ Parsing logs stored in memory. For large repositories, use file-based logging to prevent crashes.")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                    .padding()
                                    .background(Color.orange.opacity(0.1))
                                    .cornerRadius(8)
                            }
                        }
                    }
                    
                    // Run Diagnostics Button
                    Button(action: runDiagnostics) {
                        HStack {
                            if isRunning {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Running Diagnostics...")
                            } else {
                                Image(systemName: "play.circle.fill")
                                Text("Run Diagnostics")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning)
                }
                .padding()
            }
            .navigationTitle("Diagnostics")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func diagnosticsResultsView(_ result: DiagnosticsResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Diagnostic Results")
                .font(.headline)
            
            // Data Access Results
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                ResultItem(
                    label: "Posts Found",
                    expected: repository.postCount,
                    actual: result.actualPostCount,
                    icon: "text.bubble.fill"
                )
                
                ResultItem(
                    label: "Connections Found",
                    expected: repository.connectionCount,
                    actual: result.actualConnectionCount,
                    icon: "person.2.fill"
                )
                
                ResultItem(
                    label: "Media Found",
                    expected: repository.mediaCount,
                    actual: result.actualMediaCount,
                    icon: "photo.fill"
                )
                
                ResultItem(
                    label: "Profiles Found",
                    expected: repository.profileCount,
                    actual: result.actualProfileCount,
                    icon: "person.crop.circle.fill"
                )
            }
            
            // Context Status
            VStack(alignment: .leading, spacing: 8) {
                Text("ModelContext Status")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                HStack {
                    Image(systemName: result.modelContextWorking ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(result.modelContextWorking ? .green : .red)
                    Text(result.modelContextWorking ? "ModelContext Working" : "ModelContext Issues")
                }
                
                if let contextError = result.contextError {
                    Text("Error: \(contextError)")
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.leading)
                }
            }
            .padding()
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(8)
            
            // Sample Data
            if !result.samplePosts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sample Posts (First 3)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    ForEach(result.samplePosts.prefix(3), id: \.id) { post in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(post.postType)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.2))
                                    .cornerRadius(4)
                                
                                Text(post.createdAt, style: .date)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Spacer()
                                
                                Text("\(String(format: "%.0f%%", post.parseConfidence * 100))")
                                    .font(.caption)
                                    .foregroundColor(post.parseConfidence > 0.8 ? .green : .orange)
                            }
                            
                            // Use model's sanitized text preview
                            Text(post.textPreview)
                                .font(.body)
                                .lineLimit(3)
                        }
                        .padding()
                        .background(Color(UIColor.tertiarySystemGroupedBackground))
                        .cornerRadius(8)
                    }
                }
            }
            
            // Record Type Breakdowns
            if !result.connectionTypeBreakdown.isEmpty || !result.atProtocolTypeBreakdown.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Record Type Breakdown")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    if !result.connectionTypeBreakdown.isEmpty {
                        Text("Connection Types:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        ForEach(result.connectionTypeBreakdown.sorted(by: { $0.key < $1.key }), id: \.key) { type, count in
                            HStack {
                                Text(type.capitalized)
                                    .font(.caption)
                                Spacer()
                                Text("\(count)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 8)
                        }
                    }
                    
                    if !result.atProtocolTypeBreakdown.isEmpty {
                        Text("AT Protocol Record Types:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                        
                        ForEach(result.atProtocolTypeBreakdown.sorted(by: { $0.key < $1.key }), id: \.key) { type, count in
                            HStack {
                                Text(type)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(count)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 8)
                        }
                    }
                }
                .padding()
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(8)
            }
        }
    }
    
    private func runDiagnostics() {
        isRunning = true
        logs.removeAll()
        diagnosticsResult = nil
        
        Task {
            await performDiagnostics()
        }
    }
    
    @MainActor
    private func performDiagnostics() async {
        addLog("🔍 Starting repository diagnostics...")
        addLog("Repository ID: \(repository.id.uuidString)")
        addLog("Expected posts: \(repository.postCount)")
        
        var result = DiagnosticsResult()
        
        do {
            // Test ModelContext
            addLog("🧪 Testing ModelContext access...")
            
            // Test repository record access
            let repositoryIDForRepo = repository.id
            let repoDescriptor = FetchDescriptor<RepositoryRecord>(
                predicate: #Predicate { record in
                    record.id == repositoryIDForRepo
                }
            )
            let repositories = try modelContext.fetch(repoDescriptor)
            
            if repositories.isEmpty {
                addLog("❌ Repository record not found in ModelContext")
                result.modelContextWorking = false
                result.contextError = "Repository record not found"
            } else {
                addLog("✅ Repository record found in ModelContext")
                result.modelContextWorking = true
            }
            
            // Test posts access
            addLog("🧪 Testing posts access...")
            let repositoryID = repository.id
            let postDescriptor = FetchDescriptor<ParsedPost>(
                predicate: #Predicate { post in
                    post.repositoryRecordID == repositoryID
                },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            
            let posts = try modelContext.fetch(postDescriptor)
            result.actualPostCount = posts.count
            result.samplePosts = Array(posts.prefix(5))
            
            addLog("📊 Found \(posts.count) posts (expected \(repository.postCount))")
            
            if posts.count != repository.postCount {
                addLog("⚠️ Post count mismatch! Expected \(repository.postCount), found \(posts.count)")
                
                // Check if posts exist with different repository IDs
                let allPostsDescriptor = FetchDescriptor<ParsedPost>()
                let allPosts = try modelContext.fetch(allPostsDescriptor)
                let groupedByRepo = Dictionary(grouping: allPosts) { $0.repositoryRecordID }
                
                addLog("📋 Posts by repository:")
                for (repoID, repoPosts) in groupedByRepo {
                    addLog("  - \(repoID.uuidString): \(repoPosts.count) posts")
                    if let firstPost = repoPosts.first {
                        addLog("    Example: \(firstPost.text.prefix(50))...")
                    }
                }
            }
            
            // Detailed parsing log analysis (with memory safety limits)
            let logContent = await loadParsingLogs()
            if !logContent.isEmpty {
                addLog("📄 Analyzing parsing logs (\(logContent.count) chars)...")
                
                // Note: logContent is already limited by loadParsingLogs() function
                
                let logLines = logContent.split(separator: "\n")
                
                // Count different types of log messages
                let pathLines = logLines.filter { $0.contains("✅ Found record at path:") }
                let blockLines = logLines.filter { $0.contains("🔍 Parsing block CID:") }
                let cborDecodeLines = logLines.filter { $0.contains("✅ Successfully decoded CBOR") }
                let cborFailLines = logLines.filter { $0.contains("❌ Failed to decode CBOR") }
                let postParseLines = logLines.filter { $0.contains("📝 Parsing post record") }
                let postSuccessLines = logLines.filter { $0.contains("✅ Post parsing successful") }
                let postFailLines = logLines.filter { $0.contains("❌ Post parsing failed") }
                let inferredTypeLines = logLines.filter { $0.contains("✅ Inferred as app.bsky.feed.post") }
                
                addLog("📋 Parsing log analysis:")
                addLog("  - Blocks processed: \(blockLines.count)")
                addLog("  - CBOR decode success: \(cborDecodeLines.count)")
                addLog("  - CBOR decode failures: \(cborFailLines.count)")
                addLog("  - Path-based records: \(pathLines.count)")
                addLog("  - Post parsing attempts: \(postParseLines.count)")
                addLog("  - Post parsing successes: \(postSuccessLines.count)")
                addLog("  - Post parsing failures: \(postFailLines.count)")
                addLog("  - Inferred posts: \(inferredTypeLines.count)")
                
                // Show sample log lines for debugging (limited to prevent memory issues)
                if postFailLines.count > 0 {
                    addLog("⚠️ Sample post parsing failures:")
                    for failLine in postFailLines.prefix(3) {
                        let truncatedLine = String(failLine.prefix(200)) // Limit line length
                        addLog("  \(truncatedLine)")
                    }
                }
                
                if blockLines.count > 0 && pathLines.count == 0 {
                    addLog("⚠️ No path-based records found despite processing \(blockLines.count) blocks")
                    addLog("🔍 Sample block processing logs:")
                    for blockLine in blockLines.prefix(3) {
                        let truncatedLine = String(blockLine.prefix(200)) // Limit line length
                        addLog("  \(truncatedLine)")
                    }
                }
            }
            
            // Test connections access with breakdown by type
            addLog("🧪 Testing connections access...")
            let repositoryID2 = repository.id
            let connectionDescriptor = FetchDescriptor<ParsedConnection>(
                predicate: #Predicate { connection in
                    connection.repositoryRecordID == repositoryID2
                }
            )
            
            let connections = try modelContext.fetch(connectionDescriptor)
            result.actualConnectionCount = connections.count
            addLog("🔗 Found \(connections.count) connections (expected \(repository.connectionCount))")
            
            // Break down connections by type
            let connectionsByType = Dictionary(grouping: connections) { $0.connectionType }
            result.connectionTypeBreakdown = connectionsByType.mapValues { $0.count }
            addLog("📊 Connection breakdown:")
            for (type, typeConnections) in connectionsByType.sorted(by: { $0.key < $1.key }) {
                addLog("  - \(type): \(typeConnections.count)")
                if let firstConnection = typeConnections.first {
                    addLog("    Example: \(firstConnection.targetUserDID.prefix(30))...")
                }
            }
            
            // Test media access
            addLog("🧪 Testing media access...")
            let repositoryID3 = repository.id
            let mediaDescriptor = FetchDescriptor<ParsedMedia>(
                predicate: #Predicate { media in
                    media.repositoryRecordID == repositoryID3
                }
            )
            
            let media = try modelContext.fetch(mediaDescriptor)
            result.actualMediaCount = media.count
            addLog("📷 Found \(media.count) media items (expected \(repository.mediaCount))")
            
            // Test profiles access
            addLog("🧪 Testing profiles access...")
            let repositoryID4 = repository.id
            let profileDescriptor = FetchDescriptor<ParsedProfile>(
                predicate: #Predicate { profile in
                    profile.repositoryRecordID == repositoryID4
                }
            )
            
            let profiles = try modelContext.fetch(profileDescriptor)
            result.actualProfileCount = profiles.count
            addLog("👤 Found \(profiles.count) profiles (expected \(repository.profileCount))")
            
            // Check AT Protocol records for additional insights
            addLog("🧪 Testing AT Protocol records access...")
            let atProtoDescriptor = FetchDescriptor<ParsedATProtocolRecord>(
                predicate: #Predicate { record in
                    record.repositoryRecordID == repositoryID
                }
            )
            
            let atProtoRecords = try modelContext.fetch(atProtoDescriptor)
            result.actualATProtocolRecordCount = atProtoRecords.count
            addLog("📦 Found \(atProtoRecords.count) AT Protocol records")
            
            // Break down by collection type
            let recordsByType = Dictionary(grouping: atProtoRecords) { $0.collectionType }
            result.atProtocolTypeBreakdown = recordsByType.mapValues { $0.count }
            addLog("📊 AT Protocol record breakdown:")
            for (type, typeRecords) in recordsByType.sorted(by: { $0.key < $1.key }) {
                addLog("  - \(type): \(typeRecords.count)")
            }
            
            // Check for parsing statistics
            if !repository.parsingStatistics.isEmpty {
                addLog("📈 Parsing statistics available")
                // Could parse the JSON statistics here for more details
            }
            
            addLog("✅ Diagnostics completed successfully")
            
        } catch {
            addLog("❌ Diagnostics failed: \(error.localizedDescription)")
            result.modelContextWorking = false
            result.contextError = error.localizedDescription
        }
        
        diagnosticsResult = result
        isRunning = false
    }
    
    /// Load parsing logs from file if available, or fall back to string
    private func loadParsingLogs() async -> String {
        // First try to load from file
        if let logFileURL = repository.parsingLogFileURL {
            do {
                // Check if file exists
                if FileManager.default.fileExists(atPath: logFileURL.path) {
                    // Read file with size limit
                    let fileSize = try FileManager.default.attributesOfItem(atPath: logFileURL.path)[.size] as? UInt64 ?? 0
                    
                    addLog("📁 Found log file (\(fileSize) bytes): \(logFileURL.lastPathComponent)")
                    
                    let maxFileSize = 500_000 // 500KB limit
                    if fileSize > maxFileSize {
                        addLog("⚠️ Log file too large (\(fileSize) bytes), reading first \(maxFileSize) bytes")
                        
                        // Read only the first part of the file
                        let fileHandle = try FileHandle(forReadingFrom: logFileURL)
                        defer { fileHandle.closeFile() }
                        
                        let data = fileHandle.readData(ofLength: maxFileSize)
                        if let content = String(data: data, encoding: .utf8) {
                            await MainActor.run {
                                logSource = "File (partial)"
                            }
                            return content
                        }
                    } else {
                        // Read entire file
                        let content = try String(contentsOf: logFileURL, encoding: .utf8)
                        await MainActor.run {
                            logSource = "File (complete)"
                        }
                        return content
                    }
                } else {
                    addLog("⚠️ Log file not found at: \(logFileURL.path)")
                    await MainActor.run {
                        logSource = "File (not found)"
                    }
                }
            } catch {
                addLog("❌ Failed to read log file: \(error.localizedDescription)")
                await MainActor.run {
                    logSource = "File (read error)"
                }
            }
        }
        
        // Fall back to in-memory logs with size limits
        if !repository.parsingLogs.isEmpty {
            let maxLogSize = 500_000 // 500KB limit
            let logContent = repository.parsingLogs.count > maxLogSize 
                ? String(repository.parsingLogs.prefix(maxLogSize))
                : repository.parsingLogs
            
            if repository.parsingLogs.count > maxLogSize {
                addLog("⚠️ In-memory log truncated to \(maxLogSize) chars (original: \(repository.parsingLogs.count) chars)")
                await MainActor.run {
                    logSource = "Memory (truncated)"
                }
            } else {
                await MainActor.run {
                    logSource = "Memory (complete)"
                }
            }
            
            return logContent
        }
        
        await MainActor.run {
            logSource = "No logs available"
        }
        
        return ""
    }
    
    private func addLog(_ message: String) {
        let timestamp = DateFormatter().string(from: Date())
        
        // Aggressively limit individual log message length to prevent text rendering crashes
        let maxMessageLength = 150
        let truncatedMessage = message.count > maxMessageLength 
            ? String(message.prefix(maxMessageLength)) + "..."
            : message
            
        logs.append("[\(timestamp)] \(truncatedMessage)")
        
        // Limit the logs array to prevent memory issues
        if logs.count > 200 {
            logs = Array(logs.suffix(150)) // Keep the last 150 entries when we hit the limit
        }
        
        logger.debug("\(message)")
    }
}

// MARK: - Supporting Views

private struct DiagnosticItem: View {
    let label: String
    let value: String
    
    // Clean text to remove potentially problematic characters
    private var cleanValue: String {
        let maxLength = 200
        let truncated = value.count > maxLength ? String(value.prefix(maxLength)) + "..." : value
        return truncated
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .controlCharacters)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(verbatim: cleanValue)
                .font(.body)
                .fontWeight(.medium)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(8)
    }
}

private struct ResultItem: View {
    let label: String
    let expected: Int
    let actual: Int
    let icon: String
    
    private var isMatch: Bool {
        expected == actual
    }
    
    private var color: Color {
        isMatch ? .green : (actual > 0 ? .orange : .red)
    }
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: isMatch ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(color)
            }
            
            HStack {
                VStack(alignment: .leading) {
                    Text("\(actual)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(color)
                    Text("Found")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing) {
                    Text("\(expected)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)
                    Text("Expected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Data Models

private struct DiagnosticsResult {
    var modelContextWorking = false
    var contextError: String?
    var actualPostCount = 0
    var actualConnectionCount = 0
    var actualMediaCount = 0
    var actualProfileCount = 0
    var actualATProtocolRecordCount = 0
    var connectionTypeBreakdown: [String: Int] = [:]
    var atProtocolTypeBreakdown: [String: Int] = [:]
    var samplePosts: [ParsedPost] = []
}

#Preview {
    let sampleRepository = RepositoryRecord(
        backupRecordID: UUID(),
        userDID: "did:plc:example",
        userHandle: "alice.bsky.social",
        originalCarSize: 1024000
    )
    
    RepositoryDiagnosticsView(repository: sampleRepository)
        .modelContainer(for: [RepositoryRecord.self, ParsedPost.self], inMemory: true)
}