import SwiftUI
import SwiftData
import Foundation
import OSLog
import Petrel

// MARK: - ⚠️ EXPERIMENTAL TIMELINE BROWSER ⚠️

/// 🧪 EXPERIMENTAL: Timeline view for browsing chronological post history
/// ⚠️ This reconstructs posting timeline from experimental parsing results
struct RepositoryTimelineView: View {
    let repository: RepositoryRecord
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: TimelineViewModel
    @State private var selectedPost: ParsedPost?
    @State private var showingRawData = false
    
    init(repository: RepositoryRecord) {
        self.repository = repository
        self._viewModel = State(wrappedValue: TimelineViewModel(repositoryID: repository.id))
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Experimental warning header
                ExperimentalTimelineHeader(repository: repository)
                    .background(Color(UIColor.systemGroupedBackground))
                
                // Timeline content
                if viewModel.posts.isEmpty && !viewModel.isLoading {
                    emptyTimelineView
                } else {
                    timelineListView
                }
            }
            .navigationTitle("Timeline")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            viewModel.loadPosts()
                        }
                        
                        Picker("Sort Order", selection: $viewModel.sortOrder) {
                            ForEach(TimelineSortOrder.allCases, id: \.self) { order in
                                Label(order.displayName, systemImage: order.systemImage).tag(order)
                            }
                        }
                        
                        Picker("Filter Type", selection: $viewModel.postTypeFilter) {
                            ForEach(PostTypeFilter.allCases, id: \.self) { filter in
                                Text(filter.displayName).tag(filter)
                            }
                        }
                        
                        Toggle("Show Parse Errors", isOn: $viewModel.showParseErrors)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .searchable(text: $viewModel.searchQuery, prompt: "Search timeline...")
            .sheet(item: $selectedPost) { post in
                PostDetailView(post: post, repository: repository)
            }
        }
        .onAppear {
            viewModel.setModelContext(modelContext)
            viewModel.loadPosts()
        }
    }
    
    // MARK: - Timeline List View
    
    private var timelineListView: some View {
        List {
            ForEach(viewModel.groupedPosts, id: \.date) { group in
                Section(header: TimelineDateHeader(date: group.date)) {
                    ForEach(group.posts, id: \.id) { post in
                        TimelinePostRow(post: post, repository: repository) {
                            selectedPost = post
                        }
                        .onAppear {
                            // Trigger loading more posts when approaching the end
                            if post == viewModel.posts.last {
                                viewModel.loadMorePosts()
                            }
                        }
                    }
                }
            }
            
            if viewModel.isLoading {
                Section {
                    HStack {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                        Text("Loading posts...")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }
            }
        }
        .listStyle(PlainListStyle())
        .refreshable {
            viewModel.resetPagination()
            viewModel.loadPosts()
        }
    }
    
    // MARK: - Empty Timeline View
    
    private var emptyTimelineView: some View {
        VStack(spacing: 20) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            Text("No Timeline Data")
                .font(.title2)
                .fontWeight(.semibold)
            
            if let errorMessage = viewModel.errorMessage {
                Text("Error: \(errorMessage)")
                    .foregroundColor(.red)
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
            } else {
                Text("🧪 EXPERIMENTAL FEATURE\n\nNo posts found in this repository's timeline. This could indicate parsing issues or an empty repository.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            }
            
            // Debug information
            VStack(spacing: 8) {
                Text("Debug Information")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                Text("Repository ID: \(repository.id.uuidString)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("Expected Posts: \(repository.postCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("Parsing Status: \(repository.parsingStatus.displayName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if repository.parsingConfidenceScore > 0 {
                    Text("Parsing Confidence: \(String(format: "%.1f%%", repository.parsingConfidenceScore * 100))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(8)
            
            Button("Retry Loading") {
                viewModel.loadPosts()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Timeline ViewModel

@MainActor
@Observable
final class TimelineViewModel {
    private let repositoryID: UUID
    private var modelContext: ModelContext?
    private let logger = Logger(subsystem: "Catbird", category: "TimelineViewModel")
    
    var posts: [ParsedPost] = []
    var isLoading = false
    var errorMessage: String?
    var searchQuery = ""
    var sortOrder: TimelineSortOrder = .dateDescending
    var postTypeFilter: PostTypeFilter = .all
    var showParseErrors = false
    
    // Pagination properties
    private var currentPage = 0
    private let pageSize = 100
    private var hasMorePosts = true
    
    init(repositoryID: UUID) {
        self.repositoryID = repositoryID
        logger.debug("TimelineViewModel initialized for repository: \(repositoryID.uuidString)")
    }
    
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
        logger.debug("TimelineViewModel received ModelContext")
    }
    
    var filteredPosts: [ParsedPost] {
        var filtered = posts
        
        // Apply search filter
        if !searchQuery.isEmpty {
            filtered = filtered.filter { post in
                post.text.localizedCaseInsensitiveContains(searchQuery) ||
                post.recordKey.localizedCaseInsensitiveContains(searchQuery)
            }
        }
        
        // Apply post type filter
        switch postTypeFilter {
        case .all:
            break
        case .originalPosts:
            filtered = filtered.filter { $0.replyToRecordKey == nil && $0.quotedRecordKey == nil }
        case .replies:
            filtered = filtered.filter { $0.replyToRecordKey != nil }
        case .quotes:
            filtered = filtered.filter { $0.quotedRecordKey != nil }
        case .withMedia:
            filtered = filtered.filter { $0.mediaAttachmentCount > 0 }
        }
        
        // Apply parse error filter
        if !showParseErrors {
            filtered = filtered.filter { $0.parseSuccessful }
        }
        
        // Apply sort order
        switch sortOrder {
        case .dateAscending:
            filtered.sort { $0.createdAt < $1.createdAt }
        case .dateDescending:
            filtered.sort { $0.createdAt > $1.createdAt }
        case .confidence:
            filtered.sort { $0.parseConfidence > $1.parseConfidence }
        }
        
        return filtered
    }
    
    var groupedPosts: [TimelineGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredPosts) { post in
            calendar.startOfDay(for: post.createdAt)
        }
        
        return grouped.map { date, posts in
            TimelineGroup(date: date, posts: posts.sorted { $0.createdAt > $1.createdAt })
        }.sorted { $0.date > $1.date }
    }
    
    func loadPosts() {
        guard let modelContext = modelContext else {
            logger.error("loadPosts called but modelContext is nil")
            errorMessage = "ModelContext not available"
            return
        }
        
        logger.debug("Loading posts for repository: \(self.repositoryID.uuidString)")
        isLoading = true
        errorMessage = nil
        
        do {
            // First, let's check if the repository exists
            let repoDescriptor = FetchDescriptor<RepositoryRecord>(
                predicate: #Predicate { $0.id == repositoryID }
            )
            let repositories = try modelContext.fetch(repoDescriptor)
            
            if let repo = repositories.first {
                logger.debug("Found repository: \(repo.userHandle) with \(repo.postCount) posts")
            } else {
                logger.error("Repository not found for ID: \(self.repositoryID.uuidString)")
                errorMessage = "Repository not found"
                isLoading = false
                return
            }
            
            // Now fetch the posts with pagination to prevent memory issues
            var descriptor = FetchDescriptor<ParsedPost>(
                predicate: #Predicate { $0.repositoryRecordID == repositoryID },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            
            // CRITICAL: Use pagination to prevent memory overflow
            descriptor.fetchLimit = pageSize
            descriptor.fetchOffset = currentPage * pageSize
            
            let fetchedPosts = try modelContext.fetch(descriptor)
            logger.debug("Fetched \(fetchedPosts.count) posts from SwiftData (page \(self.currentPage))")
            
            // Check if we have more posts available
            if fetchedPosts.count < pageSize {
                hasMorePosts = false
                logger.debug("Reached end of posts - no more pages available")
            }
            
            // Log details about the first few posts for debugging
            for (index, post) in fetchedPosts.prefix(3).enumerated() {
                logger.debug("Post \(index): '\(post.displayText.prefix(30))...' created: \(post.createdAt)")
            }
            
            // For first page, replace posts; for subsequent pages, append
            if currentPage == 0 {
                posts = fetchedPosts
            } else {
                posts.append(contentsOf: fetchedPosts)
            }
            
            if posts.isEmpty {
                logger.warning("No posts found for repository \(self.repositoryID.uuidString)")
                // Let's also check if there are ANY ParsedPost records in the database
                let allPostsDescriptor = FetchDescriptor<ParsedPost>()
                let allPosts = try modelContext.fetch(allPostsDescriptor)
                logger.debug("Total ParsedPost records in database: \(allPosts.count)")
                
                // Check if any posts belong to different repositories
                let groupedByRepo = Dictionary(grouping: allPosts) { $0.repositoryRecordID }
                logger.debug("Posts grouped by repository: \(groupedByRepo.mapValues { $0.count })")
            }
            
        } catch {
            logger.error("Failed to load posts: \(error.localizedDescription)")
            errorMessage = "Failed to load timeline: \(error.localizedDescription)"
        }
        
        isLoading = false
        logger.debug("loadPosts completed with \(self.posts.count) posts")
    }
    
    func loadMorePosts() {
        guard !isLoading && hasMorePosts else {
            logger.debug("Cannot load more posts: isLoading=\(self.isLoading), hasMorePosts=\(self.hasMorePosts)")
            return
        }
        
        currentPage += 1
        logger.debug("Loading page \(self.currentPage)")
        loadPosts()
    }
    
    func resetPagination() {
        currentPage = 0
        hasMorePosts = true
        posts.removeAll()
    }
}

// MARK: - Supporting Views

private struct ExperimentalTimelineHeader: View {
    let repository: RepositoryRecord
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("🧪 EXPERIMENTAL TIMELINE RECONSTRUCTION")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                    
                    Text("Timeline reconstructed from \(repository.userHandle)'s parsed repository data. Accuracy not guaranteed.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            // Statistics row
            HStack(spacing: 16) {
                StatisticBadge(label: "Posts", value: "\(repository.postCount)")
                StatisticBadge(label: "Success Rate", value: repository.successRate)
                StatisticBadge(label: "Confidence", value: String(format: "%.0f%%", repository.parsingConfidenceScore * 100))
                Spacer()
            }
        }
        .padding()
    }
}

private struct TimelineDateHeader: View {
    let date: Date
    
    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        return formatter.string(from: date)
    }
    
    var body: some View {
        HStack {
            Text(formattedDate)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(UIColor.systemGroupedBackground))
    }
}

private struct TimelinePostRow: View {
    let post: ParsedPost
    let repository: RepositoryRecord
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                // Post header
                HStack {
                    HStack(spacing: 8) {
                        PostTypeIcon(post: post)
                        
                        Text(timeString)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    if !post.parseSuccessful {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                    }
                    
                    ConfidenceBadge(confidence: post.parseConfidence)
                }
                
                // Post content (using safe display text)
                Text(post.displayText)
                    .font(.body)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(6)
                
                // Post metadata
                HStack {
                    if let replyKey = post.replyToRecordKey {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                    
                    if let quoteKey = post.quotedRecordKey {
                        Label("Quote", systemImage: "quote.bubble")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                    
                    if post.mediaAttachmentCount > 0 {
                        Label("\(post.mediaAttachmentCount)", systemImage: "photo")
                            .font(.caption2)
                            .foregroundColor(.purple)
                    }
                    
                    if post.hasExternalLinks {
                        Label("Link", systemImage: "link")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    
                    Spacer()
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var timeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: post.createdAt)
    }
}

private struct PostTypeIcon: View {
    let post: ParsedPost
    
    var body: some View {
        Group {
            if post.replyToRecordKey != nil {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .foregroundColor(.blue)
            } else if post.quotedRecordKey != nil {
                Image(systemName: "quote.bubble.fill")
                    .foregroundColor(.green)
            } else {
                Image(systemName: "text.bubble.fill")
                    .foregroundColor(.primary)
            }
        }
        .font(.caption)
    }
}

private struct ConfidenceBadge: View {
    let confidence: Double
    
    private var color: Color {
        if confidence >= 0.9 {
            return .green
        } else if confidence >= 0.7 {
            return .orange
        } else {
            return .red
        }
    }
    
    var body: some View {
        Text(String(format: "%.0f%%", confidence * 100))
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct StatisticBadge: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Post Detail View

private struct PostDetailView: View {
    let post: ParsedPost
    let repository: RepositoryRecord
    @Environment(\.dismiss) private var dismiss
    @State private var showingRawData = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Post header
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Post Details")
                                .font(.title2)
                                .fontWeight(.bold)
                            
                            Spacer()
                            
                            PostTypeIcon(post: post)
                        }
                        
                        Text(post.ageDescription)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Divider()
                    
                    // Post content
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Content")
                            .font(.headline)
                        
                        Text(post.displayText)
                            .font(.body)
                            .padding()
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    
                    // Metadata
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Metadata")
                            .font(.headline)
                        
                        MetadataGrid(post: post)
                    }
                    
                    // Technical details
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Technical Details")
                            .font(.headline)
                        
                        TechnicalDetailsView(post: post)
                    }
                    
                    if !post.parseSuccessful {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Parse Error")
                                .font(.headline)
                                .foregroundColor(.red)
                            
                            Text(post.parseErrorMessage ?? "Unknown parsing error")
                                .font(.body)
                                .foregroundColor(.red)
                                .padding()
                                .background(Color.red.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Post Detail")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Raw Data") {
                        showingRawData = true
                    }
                }
            }
            .sheet(isPresented: $showingRawData) {
                RawDataView(post: post)
            }
        }
    }
}

private struct MetadataGrid: View {
    let post: ParsedPost
    
    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 12) {
            MetadataItem(label: "Record Key", value: post.recordKey)
            MetadataItem(label: "Post Type", value: post.postType)
            MetadataItem(label: "Confidence", value: String(format: "%.1f%%", post.parseConfidence * 100))
            MetadataItem(label: "Media Count", value: "\(post.mediaAttachmentCount)")
            MetadataItem(label: "Has Links", value: post.hasExternalLinks ? "Yes" : "No")
            MetadataItem(label: "Has Mentions", value: post.hasMentions ? "Yes" : "No")
            MetadataItem(label: "Has Hashtags", value: post.hasHashtags ? "Yes" : "No")
            MetadataItem(label: "Parse Status", value: post.parseSuccessful ? "Success" : "Failed")
        }
    }
}

private struct MetadataItem: View {
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

private struct TechnicalDetailsView: View {
    let post: ParsedPost
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CID:")
                    .fontWeight(.medium)
                Spacer()
                Text(post.recordCID)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            if let replyKey = post.replyToRecordKey {
                HStack {
                    Text("Reply To:")
                        .fontWeight(.medium)
                    Spacer()
                    Text(replyKey)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            if let quoteKey = post.quotedRecordKey {
                HStack {
                    Text("Quote:")
                        .fontWeight(.medium)
                    Spacer()
                    Text(quoteKey)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct RawDataView: View {
    let post: ParsedPost
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Warning
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        
                        Text("Raw CBOR data for debugging purposes only")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    
                    // Raw data
                    VStack(alignment: .leading, spacing: 8) {
                        Text("CBOR Data (\(post.rawCBORData.count) bytes)")
                            .font(.headline)
                        
                        Text(post.rawCBORData.map { String(format: "%02x", $0) }.joined(separator: " "))
                            .font(.system(.caption, design: .monospaced))
                            .padding()
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    
                    // JSON representations
                    if !post.facets.isEmpty && post.facets != "[]" {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Facets (Rich Text)")
                                .font(.headline)
                            
                            Text(post.facets)
                                .font(.system(.caption, design: .monospaced))
                                .padding()
                                .background(Color(UIColor.secondarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    
                    if !post.embeds.isEmpty && post.embeds != "[]" {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Embeds")
                                .font(.headline)
                            
                            Text(post.embeds)
                                .font(.system(.caption, design: .monospaced))
                                .padding()
                                .background(Color(UIColor.secondarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Raw Data")
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
}

// MARK: - Supporting Types

struct TimelineGroup {
    let date: Date
    let posts: [ParsedPost]
}

enum TimelineSortOrder: String, CaseIterable {
    case dateAscending = "date_asc"
    case dateDescending = "date_desc"
    case confidence = "confidence"
    
    var displayName: String {
        switch self {
        case .dateAscending:
            return "Oldest First"
        case .dateDescending:
            return "Newest First"
        case .confidence:
            return "Parse Confidence"
        }
    }
    
    var systemImage: String {
        switch self {
        case .dateAscending:
            return "arrow.up"
        case .dateDescending:
            return "arrow.down"
        case .confidence:
            return "checkmark.circle"
        }
    }
}

enum PostTypeFilter: String, CaseIterable {
    case all = "all"
    case originalPosts = "original"
    case replies = "replies"
    case quotes = "quotes"
    case withMedia = "media"
    
    var displayName: String {
        switch self {
        case .all:
            return "All Posts"
        case .originalPosts:
            return "Original Posts"
        case .replies:
            return "Replies"
        case .quotes:
            return "Quote Posts"
        case .withMedia:
            return "With Media"
        }
    }
}

#Preview {
    let sampleRepository = RepositoryRecord(
        backupRecordID: UUID(),
        userDID: "did:plc:example",
        userHandle: "alice.bsky.social",
        originalCarSize: 1024000
    )
    
    return RepositoryTimelineView(repository: sampleRepository)
        .modelContainer(for: [RepositoryRecord.self, ParsedPost.self], inMemory: true)
}
