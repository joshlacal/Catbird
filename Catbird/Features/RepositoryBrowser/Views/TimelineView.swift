import SwiftUI
import SwiftData
import Foundation

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
            .navigationBarTitleDisplayMode(.inline)
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
            
            Text("🧪 EXPERIMENTAL FEATURE\n\nNo posts found in this repository's timeline. This could indicate parsing issues or an empty repository.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
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
    
    var posts: [ParsedPost] = []
    var isLoading = false
    var errorMessage: String?
    var searchQuery = ""
    var sortOrder: TimelineSortOrder = .dateDescending
    var postTypeFilter: PostTypeFilter = .all
    var showParseErrors = false
    
    init(repositoryID: UUID) {
        self.repositoryID = repositoryID
    }
    
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
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
        guard let modelContext = modelContext else { return }
        
        isLoading = true
        errorMessage = nil
        
        do {
            let descriptor = FetchDescriptor<ParsedPost>(
                predicate: #Predicate { $0.repositoryRecordID == repositoryID },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            posts = try modelContext.fetch(descriptor)
        } catch {
            errorMessage = "Failed to load timeline: \(error.localizedDescription)"
        }
        
        isLoading = false
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
                
                // Post content
                Text(post.text)
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
                        
                        Text(post.text)
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
            .navigationBarTitleDisplayMode(.inline)
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
            .navigationBarTitleDisplayMode(.inline)
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
