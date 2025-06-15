import SwiftUI
import SwiftData

// MARK: - ⚠️ EXPERIMENTAL REPOSITORY DETAIL VIEW ⚠️

/// 🧪 EXPERIMENTAL: Comprehensive view for browsing all aspects of a parsed repository
/// ⚠️ This combines timeline, connections, media, and search functionality
struct RepositoryDetailView: View {
    let repositoryID: UUID
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var repository: RepositoryRecord?
    @State private var selectedTab: DetailTab = .overview
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            Group {
                if let repository = repository {
                    repositoryDetailContent(repository)
                } else if isLoading {
                    loadingView
                } else {
                    errorView
                }
            }
            .navigationTitle(repository?.userHandle ?? "Repository")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                
                if repository != nil {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button("Refresh Data", systemImage: "arrow.clockwise") {
                                loadRepository()
                            }
                            
                            Button("Export All Data", systemImage: "square.and.arrow.up") {
                                // Export functionality would go here
                            }
                            
                            Button("Repository Info", systemImage: "info.circle") {
                                selectedTab = .overview
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .onAppear {
            loadRepository()
        }
        .alert("Repository Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }
    
    // MARK: - Repository Detail Content
    
    @ViewBuilder
    private func repositoryDetailContent(_ repository: RepositoryRecord) -> some View {
        VStack(spacing: 0) {
            // Experimental warning banner
            ExperimentalRepositoryDetailHeader(repository: repository)
                .background(Color(UIColor.systemGroupedBackground))
            
            // Tab picker
            Picker("View", selection: $selectedTab) {
                ForEach(DetailTab.allCases, id: \.self) { tab in
                    Label(tab.displayName, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding()
            .background(Color(UIColor.systemGroupedBackground))
            
            // Tab content
            TabView(selection: $selectedTab) {
                ForEach(DetailTab.allCases, id: \.self) { tab in
                    tabContent(for: tab, repository: repository)
                        .tag(tab)
                }
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
        }
    }
    
    @ViewBuilder
    private func tabContent(for tab: DetailTab, repository: RepositoryRecord) -> some View {
        switch tab {
        case .overview:
            RepositoryOverviewView(repository: repository)
        case .timeline:
            RepositoryTimelineView(repository: repository)
        case .connections:
            RepositoryConnectionsView(repository: repository)
        case .media:
            RepositoryMediaGalleryView(repository: repository)
        case .search:
            RepositoryUniversalSearchView(repository: repository)
        }
    }
    
    // MARK: - Loading View
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
            
            Text("Loading Repository...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxHeight: .infinity)
    }
    
    // MARK: - Error View
    
    private var errorView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 64))
                .foregroundColor(.orange)
            
            Text("Repository Not Found")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("The requested repository could not be loaded. It may have been deleted or corrupted.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            Button("Retry") {
                loadRepository()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxHeight: .infinity)
    }
    
    // MARK: - Repository Loading
    
    private func loadRepository() {
        isLoading = true
        errorMessage = nil
        
        do {
            let descriptor = FetchDescriptor<RepositoryRecord>(
                predicate: #Predicate { $0.id == repositoryID }
            )
            
            let repositories = try modelContext.fetch(descriptor)
            
            if let foundRepository = repositories.first {
                repository = foundRepository
            } else {
                errorMessage = "Repository not found"
            }
        } catch {
            errorMessage = "Failed to load repository: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
}

// MARK: - Repository Overview View

private struct RepositoryOverviewView: View {
    let repository: RepositoryRecord
    @Environment(\.modelContext) private var modelContext
    @State private var detailStats: RepositoryDetailStats?
    @State private var isLoadingStats = true
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Repository header
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(repository.userHandle)
                                .font(.title)
                                .fontWeight(.bold)
                            
                            Text(repository.userDID)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        StatusBadge(status: repository.parsingStatus)
                    }
                    
                    Text("Parsed \(repository.parsingAgeDescription)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                // Quick stats grid
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 16) {
                    StatCard(
                        title: "Posts",
                        value: "\(repository.postCount)",
                        icon: "text.bubble.fill",
                        color: .blue
                    )
                    
                    StatCard(
                        title: "Connections", 
                        value: "\(repository.connectionCount)",
                        icon: "person.2.fill",
                        color: .green
                    )
                    
                    StatCard(
                        title: "Media Items",
                        value: "\(repository.mediaCount)",
                        icon: "photo.fill",
                        color: .purple
                    )
                    
                    StatCard(
                        title: "Success Rate",
                        value: repository.successRate,
                        icon: "checkmark.circle.fill",
                        color: .orange
                    )
                }
                
                // Parsing information
                VStack(alignment: .leading, spacing: 12) {
                    Text("Parsing Information")
                        .font(.headline)
                    
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 12) {
                        InfoItem(label: "Total Records", value: "\(repository.totalRecordCount)")
                        InfoItem(label: "Successfully Parsed", value: "\(repository.successfullyParsedCount)")
                        InfoItem(label: "Failed Parsing", value: "\(repository.failedParseCount)")
                        InfoItem(label: "Unknown Types", value: "\(repository.unknownRecordTypeCount)")
                        InfoItem(label: "Confidence Score", value: String(format: "%.1f%%", repository.parsingConfidenceScore * 100))
                        InfoItem(label: "Original Size", value: ByteCountFormatter.string(fromByteCount: repository.originalCarSize, countStyle: .file))
                    }
                }
                
                // Detailed statistics (if loaded)
                if let stats = detailStats {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Content Breakdown")
                            .font(.headline)
                        
                        ContentBreakdownChart(stats: stats)
                    }
                } else if isLoadingStats {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading detailed statistics...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }
                
                // Repository commit info
                if let commit = repository.repositoryCommit {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Repository Information")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Commit: \(commit)")
                                .font(.system(.caption, design: .monospaced))
                            
                            if let lastModified = repository.repositoryLastModified {
                                Text("Last Modified: \(lastModified, style: .date)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding()
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                
                // Parsing logs (if available)
                if !repository.parsingLogs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Parsing Logs")
                            .font(.headline)
                        
                        ScrollView(.horizontal) {
                            Text(repository.parsingLogs)
                                .font(.system(.caption, design: .monospaced))
                                .padding()
                        }
                        .frame(maxHeight: 100)
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding()
        }
        .onAppear {
            loadDetailedStats()
        }
    }
    
    private func loadDetailedStats() {
        isLoadingStats = true
        
        Task {
            // Load detailed statistics from SwiftData
            do {
                let postDescriptor = FetchDescriptor<ParsedPost>()
                let allPosts = try modelContext.fetch(postDescriptor)
                let posts = allPosts.filter { $0.repositoryRecordID == repository.id }
                
                let connectionDescriptor = FetchDescriptor<ParsedConnection>()
                let allConnections = try modelContext.fetch(connectionDescriptor)
                let connections = allConnections.filter { $0.repositoryRecordID == repository.id }
                
                let mediaDescriptor = FetchDescriptor<ParsedMedia>()
                let allMedia = try modelContext.fetch(mediaDescriptor)
                let media = allMedia.filter { $0.repositoryRecordID == repository.id }
                
                await MainActor.run {
                    detailStats = RepositoryDetailStats(
                        posts: posts,
                        connections: connections,
                        media: media
                    )
                    isLoadingStats = false
                }
            } catch {
                await MainActor.run {
                    isLoadingStats = false
                }
            }
        }
    }
}

// MARK: - Supporting Views

private struct ExperimentalRepositoryDetailHeader: View {
    let repository: RepositoryRecord
    
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("🧪 EXPERIMENTAL REPOSITORY BROWSER")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.orange)
                
                Text("Browsing experimental parsing results. Data accuracy not guaranteed.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            
            HStack {
                Text(value)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(color)
                Spacer()
            }
        }
        .padding()
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct InfoItem: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.body)
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct StatusBadge: View {
    let status: RepositoryParsingStatus
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.systemImage)
                .font(.caption2)
            Text(status.displayName)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(status.color).opacity(0.2))
        .foregroundColor(Color(status.color))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ContentBreakdownChart: View {
    let stats: RepositoryDetailStats
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ContentBreakdownBar(
                    segments: [
                        ("Posts", stats.postTypeBreakdown.values.reduce(0, +), .blue),
                        ("Connections", stats.connectionTypeBreakdown.values.reduce(0, +), .green),
                        ("Media", stats.mediaTypeBreakdown.values.reduce(0, +), .purple)
                    ]
                )
            }
            .frame(height: 20)
            
            // Legend
            HStack(spacing: 16) {
                LegendItem(color: .blue, label: "Posts")
                LegendItem(color: .green, label: "Connections") 
                LegendItem(color: .purple, label: "Media")
            }
        }
    }
}

private struct ContentBreakdownBar: View {
    let segments: [(String, Int, Color)]
    
    private var total: Int {
        segments.reduce(0) { $0 + $1.1 }
    }
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                Rectangle()
                    .fill(segment.2)
                    .frame(width: calculateWidth(for: segment.1))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
    
    private func calculateWidth(for value: Int) -> CGFloat {
        // Ensure we don't divide by zero or get negative/infinite values
        guard total > 0, value >= 0 else { return 0 }
        
        let ratio = CGFloat(value) / CGFloat(total)
        let width = ratio * 300
        
        // Ensure the width is finite and non-negative
        guard width.isFinite, width >= 0 else { return 0 }
        
        return width
    }
}

private struct LegendItem: View {
    let color: Color
    let label: String
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
        }
    }
}

// MARK: - Supporting Types

private enum DetailTab: String, CaseIterable {
    case overview = "overview"
    case timeline = "timeline"
    case connections = "connections"
    case media = "media"
    case search = "search"
    
    var displayName: String {
        switch self {
        case .overview:
            return "Overview"
        case .timeline:
            return "Timeline"
        case .connections:
            return "Connections"
        case .media:
            return "Media"
        case .search:
            return "Search"
        }
    }
    
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
        }
    }
}

private struct RepositoryDetailStats {
    let postTypeBreakdown: [String: Int]
    let connectionTypeBreakdown: [String: Int]
    let mediaTypeBreakdown: [String: Int]
    let averageConfidence: Double
    let parseErrorCount: Int
    
    init(posts: [ParsedPost], connections: [ParsedConnection], media: [ParsedMedia]) {
        self.postTypeBreakdown = Dictionary(grouping: posts) { $0.postType }.mapValues { $0.count }
        self.connectionTypeBreakdown = Dictionary(grouping: connections) { $0.connectionType }.mapValues { $0.count }
        self.mediaTypeBreakdown = Dictionary(grouping: media) { $0.mediaType }.mapValues { $0.count }
        
        let postConfidences = posts.map { $0.parseConfidence }
        let connectionConfidences = connections.map { $0.parseConfidence }
        let mediaConfidences = media.map { $0.parseConfidence }
        let allConfidences = postConfidences + connectionConfidences + mediaConfidences
        
        self.averageConfidence = allConfidences.isEmpty ? 0 : allConfidences.reduce(0, +) / Double(allConfidences.count)
        
        let postErrors = posts.filter { !$0.parseSuccessful }.count
        let connectionErrors = connections.filter { !$0.parseSuccessful }.count
        let mediaErrors = media.filter { !$0.parseSuccessful }.count
        self.parseErrorCount = postErrors + connectionErrors + mediaErrors
    }
}

#Preview {
    let sampleRepository = RepositoryRecord(
        backupRecordID: UUID(),
        userDID: "did:plc:example",
        userHandle: "alice.bsky.social",
        originalCarSize: 1024000
    )
    
    return RepositoryDetailView(repositoryID: sampleRepository.id)
        .modelContainer(for: [RepositoryRecord.self, ParsedPost.self, ParsedConnection.self, ParsedMedia.self, ParsedProfile.self], inMemory: true)
}
