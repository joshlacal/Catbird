import SwiftUI
import SwiftData
import Foundation
import OSLog
import Petrel

// MARK: - Timeline Browser

/// Timeline view for browsing chronological post history
/// This reconstructs posting timeline from parsing results
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
                    .background(Color(platformColor: PlatformColor.platformSystemGroupedBackground))
                
                // Timeline content
                if viewModel.posts.isEmpty && !viewModel.isLoading {
                    emptyTimelineView
                } else {
                    timelineListView
                }
            }
            .navigationTitle("Timeline")
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
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
    
    @ViewBuilder
    private var emptyTimelineView: some View {
        if let errorMessage = viewModel.errorMessage {
            ErrorStateView(
                error: NSError(
                    domain: "RepositoryBrowser", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: errorMessage]),
                context: errorMessage,
                retryAction: { viewModel.loadPosts() })
        } else {
            emptyTimelineContent
        }
    }

    private var emptyTimelineContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "calendar.badge.exclamationmark")
                .appFont(size: 64)
                .foregroundColor(.secondary)

            Text("No Timeline Data")
                .appFont(AppTextRole.title2)
                .fontWeight(.semibold)

            Text("No posts found in this repository's timeline. This could indicate parsing issues or an empty repository.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            #if DEBUG
            // Debug information
            VStack(spacing: 8) {
                Text("Debug Information")
                    .appFont(AppTextRole.headline)
                    .foregroundColor(.secondary)
                
                Text(verbatim: "Repository ID: \(repository.id.uuidString)")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
                
                Text("Expected Posts: \(repository.postCount.formatted(.number))", comment: "Diagnostic label showing expected post count in empty timeline state.")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
                
                Text("Parsing Status: \(repository.parsingStatus.displayName)", comment: "Diagnostic label showing repository parsing status.")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
                
                if repository.parsingConfidenceScore > 0 {
                    Text(
                        "Parsing Confidence: \(repository.parsingConfidenceScore.formatted(.percent.precision(.fractionLength(1))))",
                        comment: "Diagnostic label showing repository parsing confidence percentage."
                    )
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(platformColor: PlatformColor.platformSecondarySystemGroupedBackground))
            .clipShape(Radius.sm.shape)
            #endif

            Button("Retry Loading") {
                viewModel.loadPosts()
            }
            .buttonStyle(.catbird(.tonal))
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
    private let logger = Logger(subsystem: "blue.catbird", category: "TimelineViewModel")
    
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
            errorMessage = String(localized: "ModelContext not available", comment: "Internal error when SwiftData model context is missing.")
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
                errorMessage = String(localized: "Repository not found", comment: "Error shown when repository record cannot be found.")
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
            errorMessage = String(
                localized: "Failed to load timeline: \(error.localizedDescription)",
                comment: "Error shown when loading timeline posts fails."
            )
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
                    Text("TIMELINE RECONSTRUCTION")
                        .appFont(AppTextRole.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                    
                    Text(
                        "Timeline reconstructed from \(repository.userHandle)'s parsed repository data. Accuracy not guaranteed.",
                        comment: "Disclaimer header on repository timeline view. Placeholder is the repository owner's handle."
                    )
                        .appFont(AppTextRole.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            // Statistics row
            HStack(spacing: 16) {
                StatisticBadge(label: "Posts", value: repository.postCount.formatted(.number))
                StatisticBadge(label: "Success Rate", value: repository.successRate)
                StatisticBadge(label: "Confidence", value: repository.parsingConfidenceScore.formatted(.percent.precision(.fractionLength(0))))
                Spacer()
            }
        }
        .padding()
    }
}

private struct TimelineDateHeader: View {
    let date: Date
    
    var body: some View {
        HStack {
            Text(date, format: Date.FormatStyle(date: .complete, time: .omitted))
                .appFont(AppTextRole.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(platformColor: PlatformColor.platformSystemGroupedBackground))
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
                        
                        Text(post.createdAt, format: Date.FormatStyle(date: .omitted, time: .shortened))
                            .appFont(AppTextRole.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    if !post.parseSuccessful {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .appFont(AppTextRole.caption)
                    }
                    
                    ConfidenceBadge(confidence: post.parseConfidence)
                }
                
                // Post content (using safe display text)
                Text(post.displayText)
                    .appFont(AppTextRole.body)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(6)
                
                // Post metadata
                HStack {
                    if post.replyToRecordKey != nil {
                        Label {
                            Text("Reply", comment: "Badge indicating a timeline post is a reply.")
                        } icon: {
                            Image(systemName: "arrowshape.turn.up.left")
                        }
                            .appFont(AppTextRole.caption2)
                            .foregroundColor(Color.accentColor)
                    }
                    
                    if post.quotedRecordKey != nil {
                        Label {
                            Text("Quote", comment: "Badge indicating a timeline post quotes another post.")
                        } icon: {
                            Image(systemName: "quote.bubble")
                        }
                            .appFont(AppTextRole.caption2)
                            .foregroundColor(.green)
                    }
                    
                    if post.mediaAttachmentCount > 0 {
                        Label {
                            Text(post.mediaAttachmentCount, format: .number)
                        } icon: {
                            Image(systemName: "photo")
                        }
                            .appFont(AppTextRole.caption2)
                            .foregroundColor(.purple)
                    }
                    
                    if post.hasExternalLinks {
                        Label {
                            Text("Link", comment: "Badge indicating a timeline post contains an external link.")
                        } icon: {
                            Image(systemName: "link")
                        }
                            .appFont(AppTextRole.caption2)
                            .foregroundColor(.orange)
                    }
                    
                    Spacer()
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

private struct PostTypeIcon: View {
    let post: ParsedPost
    
    var body: some View {
        Group {
            if post.replyToRecordKey != nil {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .foregroundColor(Color.accentColor)
            } else if post.quotedRecordKey != nil {
                Image(systemName: "quote.bubble.fill")
                    .foregroundColor(.green)
            } else {
                Image(systemName: "text.bubble.fill")
                    .foregroundColor(.primary)
            }
        }
        .appFont(AppTextRole.caption)
    }
}

private struct ConfidenceBadge: View {
    let confidence: Double

    private var tone: CatbirdBadgeTone {
        if confidence >= 0.9 {
            return .success
        } else if confidence >= 0.7 {
            return .warning
        } else {
            return .danger
        }
    }

    var body: some View {
        CatbirdBadge(Text(confidence, format: .percent.precision(.fractionLength(0))), tone: tone)
    }
}

private struct StatisticBadge: View {
    let label: LocalizedStringResource
    let value: String
    
    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            Text(verbatim: value)
                .appFont(AppTextRole.caption)
                .fontWeight(.semibold)
            Text(label)
                .appFont(AppTextRole.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(platformColor: PlatformColor.platformSecondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Post Detail View

private struct PostDetailView: View {
    let post: ParsedPost
    let repository: RepositoryRecord
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Post header
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Post Details")
                                .appFont(AppTextRole.title2)
                                .fontWeight(.bold)
                            
                            Spacer()
                            
                            PostTypeIcon(post: post)
                        }
                        
                        Text(post.ageDescription)
                            .appFont(AppTextRole.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Divider()
                    
                    // Post content
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Content")
                            .appFont(AppTextRole.headline)
                        
                        Text(post.displayText)
                            .appFont(AppTextRole.body)
                            .padding()
                            .background(Color(platformColor: PlatformColor.platformSecondarySystemGroupedBackground))
                            .clipShape(Radius.sm.shape)
                    }
                    
                    // Metadata
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Metadata")
                            .appFont(AppTextRole.headline)
                        
                        MetadataGrid(post: post)
                    }
                    
                    // Technical details
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Technical Details")
                            .appFont(AppTextRole.headline)
                        
                        TechnicalDetailsView(post: post)
                    }
                    
                    if !post.parseSuccessful {
                        VStack(alignment: .leading, spacing: 12) {
                            CatbirdNotice(
                                tone: .error,
                                title: Text("Parse Error"),
                                message: Text(
                                  post.parseErrorMessage
                                    ?? String(localized: "Unknown parsing error", comment: "Fallback message when a post record failed to parse without a specific error message.")))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Post Detail")
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .modifier(PostRawDataSheet(post: post))
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
            MetadataItem(label: "Confidence", value: post.parseConfidence.formatted(.percent.precision(.fractionLength(1))))
            MetadataItem(label: "Media Count", value: post.mediaAttachmentCount.formatted(.number))
            MetadataItem(
                label: "Has Links",
                value: post.hasExternalLinks
                    ? String(localized: "Yes", comment: "Affirmative boolean value in metadata grid.")
                    : String(localized: "No", comment: "Negative boolean value in metadata grid.")
            )
            MetadataItem(
                label: "Has Mentions",
                value: post.hasMentions
                    ? String(localized: "Yes", comment: "Affirmative boolean value in metadata grid.")
                    : String(localized: "No", comment: "Negative boolean value in metadata grid.")
            )
            MetadataItem(
                label: "Has Hashtags",
                value: post.hasHashtags
                    ? String(localized: "Yes", comment: "Affirmative boolean value in metadata grid.")
                    : String(localized: "No", comment: "Negative boolean value in metadata grid.")
            )
            MetadataItem(
                label: "Parse Status",
                value: post.parseSuccessful
                    ? String(localized: "Success", comment: "Record parse status when parsing succeeded.")
                    : String(localized: "Failed", comment: "Record parse status when parsing failed.")
            )
        }
    }
}

private struct MetadataItem: View {
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

private struct TechnicalDetailsView: View {
    let post: ParsedPost
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CID:", comment: "Label for Content Identifier (CID) of an AT Protocol record.")
                    .fontWeight(.medium)
                Spacer()
                Text(verbatim: post.recordCID)
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            if let replyKey = post.replyToRecordKey {
                HStack {
                    Text("Reply To:")
                        .fontWeight(.medium)
                    Spacer()
                    Text(verbatim: replyKey)
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            if let quoteKey = post.quotedRecordKey {
                HStack {
                    Text("Quote:", comment: "Label for the record key of a quoted post.")
                        .fontWeight(.medium)
                    Spacer()
                    Text(verbatim: quoteKey)
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding()
        .background(Color(platformColor: PlatformColor.platformSecondarySystemGroupedBackground))
        .clipShape(Radius.sm.shape)
    }
}

#if DEBUG
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
                            .appFont(AppTextRole.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .clipShape(Radius.sm.shape)
                    
                    // Raw data
                    VStack(alignment: .leading, spacing: 8) {
                        Text("CBOR Data (\(post.rawCBORData.count) bytes)", comment: "Section header showing raw CBOR payload size in bytes.")
                            .appFont(AppTextRole.headline)
                        
                        Text(verbatim: post.rawCBORData.map { String(format: "%02x", $0) }.joined(separator: " "))
                            .font(.system(.caption, design: .monospaced))
                            .padding()
                            .background(Color(platformColor: PlatformColor.platformSecondarySystemGroupedBackground))
                            .clipShape(Radius.sm.shape)
                    }
                    
                    // JSON representations
                    if !post.facets.isEmpty && post.facets != "[]" {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Facets (Rich Text)")
                                .appFont(AppTextRole.headline)
                            
                            Text(verbatim: post.facets)
                                .font(.system(.caption, design: .monospaced))
                                .padding()
                                .background(Color(platformColor: PlatformColor.platformSecondarySystemGroupedBackground))
                                .clipShape(Radius.sm.shape)
                        }
                    }
                    
                    if !post.embeds.isEmpty && post.embeds != "[]" {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Embeds")
                                .appFont(AppTextRole.headline)
                            
                            Text(verbatim: post.embeds)
                                .font(.system(.caption, design: .monospaced))
                                .padding()
                                .background(Color(platformColor: PlatformColor.platformSecondarySystemGroupedBackground))
                                .clipShape(Radius.sm.shape)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Raw Data")
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
#endif

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
            return String(localized: "Oldest First", comment: "Sort order option from oldest to newest.")
        case .dateDescending:
            return String(localized: "Newest First", comment: "Sort order option from newest to oldest.")
        case .confidence:
            return String(localized: "Parse Confidence", comment: "Sort order option by record parsing confidence score.")
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
            return String(localized: "All Posts", comment: "Timeline filter option showing all post types.")
        case .originalPosts:
            return String(localized: "Original Posts", comment: "Timeline filter option showing only top-level original posts.")
        case .replies:
            return String(localized: "Replies", comment: "Timeline filter option showing only reply posts.")
        case .quotes:
            return String(localized: "Quote Posts", comment: "Timeline filter option showing only quote posts.")
        case .withMedia:
            return String(localized: "With Media", comment: "Timeline filter option showing only posts containing media attachments.")
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

// MARK: - Debug Raw Data

/// Adds the "Raw Data" toolbar button and its sheet in debug builds only.
/// Release builds get the content unchanged.
private struct PostRawDataSheet: ViewModifier {
    let post: ParsedPost
    #if DEBUG
    @State private var showingRawData = false
    #endif

    func body(content: Content) -> some View {
        #if DEBUG
        content
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Raw Data") {
                        showingRawData = true
                    }
                }
            }
            .sheet(isPresented: $showingRawData) {
                RawDataView(post: post)
            }
        #else
        content
        #endif
    }
}
