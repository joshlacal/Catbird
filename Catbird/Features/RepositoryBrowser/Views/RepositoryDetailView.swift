import SwiftUI
import SwiftData

// MARK: - Repository Detail View

/// Comprehensive view for browsing all aspects of a parsed repository
/// This combines timeline, connections, media, and search functionality
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
            .navigationTitle(
                repository.map { Text(verbatim: $0.userHandle) }
                    ?? Text("Repository", comment: "Fallback navigation title for the repository detail screen.")
            )
            #if os(iOS)
            .toolbarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Done") {
                        dismiss()
                    }
                }

                if repository != nil {
                    ToolbarItem(placement: .automatic) {
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

                            Button("Run Diagnostics", systemImage: "stethoscope") {
                                selectedTab = .diagnostics
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
            // Header banner
            RepositoryDetailHeader(repository: repository)
                .background(Color(platformColor: PlatformColor.platformSystemGroupedBackground))

            // Tab picker
            Picker("View", selection: $selectedTab) {
                ForEach(DetailTab.allCases, id: \.self) { tab in
                    Label(tab.displayName, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding()
            .background(Color(platformColor: PlatformColor.platformSystemGroupedBackground))

            // Tab content
            TabView(selection: $selectedTab) {
                ForEach(DetailTab.allCases, id: \.self) { tab in
                    tabContent(for: tab, repository: repository)
                        .tag(tab)
                }
            }
            #if os(iOS)
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
            #endif
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
        case .diagnostics:
            RepositoryDiagnosticsView(repository: repository)
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())

            Text("Loading Repository...")
                .appFont(AppTextRole.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Error View

    private var errorView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .appFont(size: 64)
                .foregroundColor(.orange)

            Text("Repository Not Found")
                .appFont(AppTextRole.title2)
                .fontWeight(.semibold)

            Text("The requested repository could not be loaded. It may have been deleted or corrupted.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Button("Retry") {
                loadRepository()
            }
            .buttonStyle(.catbird(.tonal))
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
                errorMessage = String(
                    localized: "Repository not found",
                    comment: "Error shown when a parsed repository record cannot be found."
                )
            }
        } catch {
            errorMessage = String(
                localized: "Failed to load repository: \(error.localizedDescription)",
                comment: "Error shown when loading a repository record fails."
            )
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
                            Text(verbatim: repository.userHandle)
                                .appFont(AppTextRole.title1)
                                .fontWeight(.bold)

                            Text(verbatim: repository.userDID)
                                .appFont(AppTextRole.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        StatusBadge(status: repository.parsingStatus)
                    }

                    Text("Parsed \(repository.parsingAgeDescription)", comment: "Relative time label showing when the repository backup was parsed, e.g. 'Parsed 2 hr. ago'.")
                        .appFont(AppTextRole.subheadline)
                        .foregroundColor(.secondary)
                }

                // Quick stats grid
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 16) {
                    StatCard(
                        title: "Posts",
                        value: repository.postCount.formatted(.number),
                        icon: "text.bubble.fill",
                        color: .blue
                    )

                    StatCard(
                        title: "Connections",
                        value: repository.connectionCount.formatted(.number),
                        icon: "person.2.fill",
                        color: .green
                    )

                    StatCard(
                        title: "Media Items",
                        value: repository.mediaCount.formatted(.number),
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
                        .appFont(AppTextRole.headline)

                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 12) {
                        InfoItem(label: "Total Records", value: repository.totalRecordCount.formatted(.number))
                        InfoItem(label: "Successfully Parsed", value: repository.successfullyParsedCount.formatted(.number))
                        InfoItem(label: "Failed Parsing", value: repository.failedParseCount.formatted(.number))
                        InfoItem(label: "Unknown Types", value: repository.unknownRecordTypeCount.formatted(.number))
                        InfoItem(label: "Confidence Score", value: repository.parsingConfidenceScore.formatted(.percent.precision(.fractionLength(1))))
                        InfoItem(label: "Original Size", value: ByteCountFormatter.string(fromByteCount: repository.originalCarSize, countStyle: .file))
                    }
                }

                // Detailed statistics (if loaded)
                if let stats = detailStats {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Content Breakdown")
                            .appFont(AppTextRole.headline)

                        ContentBreakdownChart(stats: stats)
                    }
                } else if isLoadingStats {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading detailed statistics...")
                            .appFont(AppTextRole.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }

                // Repository commit info
                if let commit = repository.repositoryCommit {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Repository Information")
                            .appFont(AppTextRole.headline)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: "Commit: \(commit)")
                                .font(.system(.caption, design: .monospaced))

                            if let lastModified = repository.repositoryLastModified {
                                Text("Last Modified: \(lastModified.formatted(date: .abbreviated, time: .omitted))", comment: "Label showing the last modified date of the repository.")
                                    .appFont(AppTextRole.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding()
                        .background(Color(platformColor: PlatformColor.platformSecondarySystemGroupedBackground))
                        .clipShape(Radius.sm.shape)
                    }
                }

                // Parsing logs (if available)
                if !repository.parsingLogs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Parsing Logs")
                            .appFont(AppTextRole.headline)

                        ScrollView(.horizontal) {
                            Text(verbatim: repository.parsingLogs)
                                .font(.system(.caption, design: .monospaced))
                                .padding()
                        }
                        .frame(maxHeight: 100)
                        .background(Color(platformColor: PlatformColor.platformSecondarySystemGroupedBackground))
                        .clipShape(Radius.sm.shape)
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

private struct RepositoryDetailHeader: View {
    let repository: RepositoryRecord

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("REPOSITORY BROWSER")
                    .appFont(AppTextRole.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.orange)

                Text("Browsing parsing results. Data accuracy not guaranteed.")
                    .appFont(AppTextRole.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
    }
}

private struct StatCard: View {
    let title: LocalizedStringResource
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(title)
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }

            HStack {
                Text(verbatim: value)
                    .appFont(AppTextRole.title2)
                    .fontWeight(.bold)
                    .foregroundColor(color)
                Spacer()
            }
        }
        .padding()
        .background(color.opacity(0.1))
        .clipShape(Radius.sm.shape)
    }
}

private struct InfoItem: View {
    let label: LocalizedStringResource
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .appFont(AppTextRole.caption)
                .foregroundColor(.secondary)
            Text(verbatim: value)
                .appFont(AppTextRole.body)
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(platformColor: PlatformColor.platformSecondarySystemGroupedBackground))
        .clipShape(Radius.sm.shape)
    }
}

private struct StatusBadge: View {
    let status: RepositoryParsingStatus

    var body: some View {
        CatbirdBadge(Text(status.displayName), systemImage: status.systemImage, tone: status.badgeTone)
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
        .clipShape(Radius.xs.shape)
    }

    private func calculateWidth(for value: Int) -> CGFloat {
        guard total > 0, value >= 0 else { return 0 }

        let ratio = CGFloat(value) / CGFloat(total)
        let width = ratio * 300

        guard width.isFinite, width >= 0 else { return 0 }

        return width
    }
}

private struct LegendItem: View {
    let color: Color
    let label: LocalizedStringResource

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .appFont(AppTextRole.caption)
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
    case diagnostics = "diagnostics"

    var displayName: String {
        switch self {
        case .overview:
            return String(localized: "Overview", comment: "Repository detail tab title for overview summary.")
        case .timeline:
            return String(localized: "Timeline", comment: "Repository detail tab title for chronological post timeline.")
        case .connections:
            return String(localized: "Connections", comment: "Repository detail tab title for social connections.")
        case .media:
            return String(localized: "Media", comment: "Repository detail tab title for media attachments.")
        case .search:
            return String(localized: "Search", comment: "Repository detail tab title for universal record search.")
        case .diagnostics:
            return String(localized: "Diagnostics", comment: "Repository detail tab title for parsing diagnostics.")
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
        case .diagnostics:
            return "stethoscope"
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
