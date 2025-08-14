import SwiftUI
import SwiftData

// MARK: - ⚠️ EXPERIMENTAL MEDIA GALLERY ⚠️

/// 🧪 EXPERIMENTAL: Gallery view for browsing media references from repository data
/// ⚠️ This shows experimental parsing results of media attachments and references
struct RepositoryMediaGalleryView: View {
    let repository: RepositoryRecord
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: MediaGalleryViewModel
    @State private var selectedMedia: ParsedMedia?
    @State private var showingMediaAnalytics = false
    @State private var selectedLayoutMode: MediaLayoutMode = .grid
    
    init(repository: RepositoryRecord) {
        self.repository = repository
        self._viewModel =  State(wrappedValue: MediaGalleryViewModel(repositoryID: repository.id))
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Experimental warning header
                ExperimentalMediaHeader(repository: repository)
                    .background(Color(UIColor.systemGroupedBackground))
                
                // Main content
                if viewModel.mediaItems.isEmpty && !viewModel.isLoading {
                    emptyMediaView
                } else {
                    mediaContentView
                }
            }
            .navigationTitle("Media Gallery")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Picker("Layout", selection: $selectedLayoutMode) {
                        ForEach(MediaLayoutMode.allCases, id: \.self) { mode in
                            Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            viewModel.loadMediaItems()
                        }
                        
                        Button("Analytics", systemImage: "chart.bar") {
                            showingMediaAnalytics = true
                        }
                        
                        Picker("Media Type", selection: $viewModel.mediaTypeFilter) {
                            ForEach(MediaTypeFilter.allCases, id: \.self) { filter in
                                Text(filter.displayName).tag(filter)
                            }
                        }
                        
                        Picker("Sort Order", selection: $viewModel.sortOrder) {
                            ForEach(MediaSortOrder.allCases, id: \.self) { order in
                                Label(order.displayName, systemImage: order.systemImage).tag(order)
                            }
                        }
                        
                        Toggle("Show Parse Errors", isOn: $viewModel.showParseErrors)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .searchable(text: $viewModel.searchQuery, prompt: "Search media...")
            .sheet(isPresented: $showingMediaAnalytics) {
                MediaAnalyticsView(viewModel: viewModel)
            }
            .sheet(item: $selectedMedia) { media in
                MediaDetailView(media: media, repository: repository)
            }
        }
        .onAppear {
            viewModel.setModelContext(modelContext)
            viewModel.loadMediaItems()
        }
    }
    
    // MARK: - Media Content View
    
    private var mediaContentView: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                // Summary section
                MediaSummaryView(viewModel: viewModel)
                    .padding(.horizontal)
                
                // Media gallery
                switch selectedLayoutMode {
                case .grid:
                    mediaGridView
                case .list:
                    mediaListView
                case .timeline:
                    mediaTimelineView
                }
            }
            .padding(.vertical)
        }
        .refreshable {
            viewModel.loadMediaItems()
        }
    }
    
    // MARK: - Media Grid View
    
    private var mediaGridView: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
            spacing: 8
        ) {
            ForEach(viewModel.filteredMediaItems, id: \.id) { media in
                MediaGridItem(media: media) {
                    selectedMedia = media
                }
            }
        }
        .padding(.horizontal)
    }
    
    // MARK: - Media List View
    
    private var mediaListView: some View {
        LazyVStack(spacing: 8) {
            ForEach(viewModel.filteredMediaItems, id: \.id) { media in
                MediaListItem(media: media) {
                    selectedMedia = media
                }
                .padding(.horizontal)
            }
        }
    }
    
    // MARK: - Media Timeline View
    
    private var mediaTimelineView: some View {
        LazyVStack(spacing: 16) {
            ForEach(viewModel.groupedMediaItems, id: \.date) { group in
                VStack(alignment: .leading, spacing: 12) {
                    // Date header
                    HStack {
                        Text(group.date, style: .date)
                            .font(.headline)
                            .fontWeight(.semibold)
                        
                        Spacer()
                        
                        Text("\(group.mediaItems.count) items")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    
                    // Media items for this date
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                        spacing: 8
                    ) {
                        ForEach(group.mediaItems, id: \.id) { media in
                            MediaGridItem(media: media) {
                                selectedMedia = media
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
    
    // MARK: - Empty Media View
    
    private var emptyMediaView: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.stack")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            Text("No Media References")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("🧪 EXPERIMENTAL FEATURE\n\nNo media references found in this repository. This could indicate parsing issues or no media attachments in the backup.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            Button("Retry Loading") {
                viewModel.loadMediaItems()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
}

// MARK: - Media Gallery ViewModel

@MainActor
@Observable
final class MediaGalleryViewModel {
    private let repositoryID: UUID
    private var modelContext: ModelContext?
    
    var mediaItems: [ParsedMedia] = []
    var isLoading = false
    var errorMessage: String?
    var searchQuery = ""
    var sortOrder: MediaSortOrder = .dateDescending
    var mediaTypeFilter: MediaTypeFilter = .all
    var showParseErrors = false
    
    init(repositoryID: UUID) {
        self.repositoryID = repositoryID
    }
    
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }
    
    var filteredMediaItems: [ParsedMedia] {
        var filtered = mediaItems
        
        // Apply search filter
        if !searchQuery.isEmpty {
            filtered = filtered.filter { media in
                media.altText?.localizedCaseInsensitiveContains(searchQuery) == true ||
                media.mimeType?.localizedCaseInsensitiveContains(searchQuery) == true ||
                media.recordKey.localizedCaseInsensitiveContains(searchQuery)
            }
        }
        
        // Apply media type filter
        switch mediaTypeFilter {
        case .all:
            break
        case .images:
            filtered = filtered.filter { $0.mediaType.lowercased().contains("image") }
        case .videos:
            filtered = filtered.filter { $0.mediaType.lowercased().contains("video") }
        case .unknown:
            filtered = filtered.filter { !$0.mediaType.lowercased().contains("image") && !$0.mediaType.lowercased().contains("video") }
        }
        
        // Apply parse error filter
        if !showParseErrors {
            filtered = filtered.filter { $0.parseSuccessful }
        }
        
        // Apply sort order
        switch sortOrder {
        case .dateAscending:
            filtered.sort { $0.discoveredAt < $1.discoveredAt }
        case .dateDescending:
            filtered.sort { $0.discoveredAt > $1.discoveredAt }
        case .size:
            filtered.sort { ($0.size ?? 0) > ($1.size ?? 0) }
        case .confidence:
            filtered.sort { $0.parseConfidence > $1.parseConfidence }
        case .type:
            filtered.sort { $0.mediaType < $1.mediaType }
        }
        
        return filtered
    }
    
    var mediaByType: [String: Int] {
        Dictionary(grouping: filteredMediaItems) { $0.mediaType }
            .mapValues { $0.count }
    }
    
    var groupedMediaItems: [MediaGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredMediaItems) { media in
            calendar.startOfDay(for: media.discoveredAt)
        }
        
        return grouped.map { date, mediaItems in
            MediaGroup(date: date, mediaItems: mediaItems.sorted { $0.discoveredAt > $1.discoveredAt })
        }.sorted { $0.date > $1.date }
    }
    
    var totalMediaSize: Int64 {
        filteredMediaItems.compactMap { $0.size }.reduce(0, +)
    }
    
    func loadMediaItems() {
        guard let modelContext = modelContext else { return }
        
        isLoading = true
        errorMessage = nil
        
        do {
            let descriptor = FetchDescriptor<ParsedMedia>(
                sortBy: [SortDescriptor(\.discoveredAt, order: .reverse)]
            )
            let allMedia = try modelContext.fetch(descriptor)
            mediaItems = allMedia.filter { $0.repositoryRecordID == repositoryID }
        } catch {
            errorMessage = "Failed to load media: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
}

// MARK: - Supporting Views

private struct ExperimentalMediaHeader: View {
    let repository: RepositoryRecord
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("🧪 EXPERIMENTAL MEDIA GALLERY")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                    
                    Text("Media references parsed from \(repository.userHandle)'s repository. Actual media files not available.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            // Statistics row
            HStack(spacing: 16) {
                StatisticBadge(label: "Media Items", value: "\(repository.mediaCount)")
                StatisticBadge(label: "Success Rate", value: repository.successRate)
                StatisticBadge(label: "Confidence", value: String(format: "%.0f%%", repository.parsingConfidenceScore * 100))
                Spacer()
            }
        }
        .padding()
    }
}

private struct MediaSummaryView: View {
     var viewModel: MediaGalleryViewModel
    
    var body: some View {
        VStack(spacing: 12) {
            // Type breakdown
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                ForEach(Array(viewModel.mediaByType.keys.sorted()), id: \.self) { type in
                    MediaTypeSummary(
                        type: type,
                        count: viewModel.mediaByType[type] ?? 0
                    )
                }
            }
            
            // Total size
            if viewModel.totalMediaSize > 0 {
                HStack {
                    Text("Total Size:")
                        .font(.headline)
                    
                    Spacer()
                    
                    Text(ByteCountFormatter.string(fromByteCount: viewModel.totalMediaSize, countStyle: .file))
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.blue)
                }
                .padding()
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct MediaTypeSummary: View {
    let type: String
    let count: Int
    
    private var displayInfo: (name: String, icon: String, color: Color) {
        let lowercaseType = type.lowercased()
        if lowercaseType.contains("image") {
            return ("Images", "photo", .blue)
        } else if lowercaseType.contains("video") {
            return ("Videos", "video", .red)
        } else {
            return (type.capitalized, "doc", .gray)
        }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: displayInfo.icon)
                .font(.title2)
                .foregroundColor(displayInfo.color)
            
            Text("\(count)")
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(displayInfo.color)
            
            Text(displayInfo.name)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(displayInfo.color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MediaGridItem: View {
    let media: ParsedMedia
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                // Media placeholder
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(mediaTypeColor.opacity(0.3))
                        .aspectRatio(1, contentMode: .fit)
                    
                    VStack(spacing: 4) {
                        Image(systemName: mediaTypeIcon)
                            .font(.title2)
                            .foregroundColor(mediaTypeColor)
                        
                        if let size = media.size {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Confidence badge in corner
                    VStack {
                        HStack {
                            Spacer()
                            ConfidenceBadge(confidence: media.parseConfidence)
                        }
                        Spacer()
                    }
                    .padding(4)
                }
                
                // Alt text preview
                if let altText = media.altText, !altText.isEmpty {
                    Text(altText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var mediaTypeIcon: String {
        let lowercaseType = media.mediaType.lowercased()
        if lowercaseType.contains("image") {
            return "photo"
        } else if lowercaseType.contains("video") {
            return "video"
        } else {
            return "doc"
        }
    }
    
    private var mediaTypeColor: Color {
        let lowercaseType = media.mediaType.lowercased()
        if lowercaseType.contains("image") {
            return .blue
        } else if lowercaseType.contains("video") {
            return .red
        } else {
            return .gray
        }
    }
}

private struct MediaListItem: View {
    let media: ParsedMedia
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Media type icon
                ZStack {
                    Circle()
                        .fill(mediaTypeColor.opacity(0.2))
                        .frame(width: 50, height: 50)
                    
                    Image(systemName: mediaTypeIcon)
                        .font(.title3)
                        .foregroundColor(mediaTypeColor)
                }
                
                // Media info
                VStack(alignment: .leading, spacing: 4) {
                    Text(media.mediaType.capitalized)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    if let mimeType = media.mimeType {
                        Text(mimeType)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if let altText = media.altText, !altText.isEmpty {
                        Text(altText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                
                Spacer()
                
                // Details
                VStack(alignment: .trailing, spacing: 4) {
                    if let _ = media.size {
                        Text(media.formattedSize)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    
                    ConfidenceBadge(confidence: media.parseConfidence)
                    
                    if !media.parseSuccessful {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                    }
                }
            }
            .padding()
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var mediaTypeIcon: String {
        let lowercaseType = media.mediaType.lowercased()
        if lowercaseType.contains("image") {
            return "photo"
        } else if lowercaseType.contains("video") {
            return "video"
        } else {
            return "doc"
        }
    }
    
    private var mediaTypeColor: Color {
        let lowercaseType = media.mediaType.lowercased()
        if lowercaseType.contains("image") {
            return .blue
        } else if lowercaseType.contains("video") {
            return .red
        } else {
            return .gray
        }
    }
}

// MARK: - Media Detail View

private struct MediaDetailView: View {
    let media: ParsedMedia
    let repository: RepositoryRecord
    @Environment(\.dismiss) private var dismiss
    @State private var showingRawData = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Media header
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Media Details")
                                .font(.title2)
                                .fontWeight(.bold)
                            
                            Spacer()
                            
                            MediaTypeIcon(type: media.mediaType)
                        }
                        
                        Text("Discovered \(media.discoveredAt, style: .relative) ago")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Divider()
                    
                    // Media preview placeholder
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Media Preview")
                            .font(.headline)
                        
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(UIColor.secondarySystemGroupedBackground))
                                .frame(height: 200)
                            
                            VStack(spacing: 12) {
                                Image(systemName: mediaTypeIcon)
                                    .font(.system(size: 48))
                                    .foregroundColor(.secondary)
                                
                                Text("🧪 EXPERIMENTAL")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.orange)
                                
                                Text("Media files not available in repository parsing")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                    }
                    
                    // Media metadata
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Metadata")
                            .font(.headline)
                        
                        MediaMetadataGrid(media: media)
                    }
                    
                    // Technical details
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Technical Details")
                            .font(.headline)
                        
                        MediaTechnicalDetailsView(media: media)
                    }
                    
                    if !media.parseSuccessful {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Parse Error")
                                .font(.headline)
                                .foregroundColor(.red)
                            
                            Text(media.parseErrorMessage ?? "Unknown parsing error")
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
            .navigationTitle("Media Detail")
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
                MediaRawDataView(media: media)
            }
        }
    }
    
    private var mediaTypeIcon: String {
        let lowercaseType = media.mediaType.lowercased()
        if lowercaseType.contains("image") {
            return "photo"
        } else if lowercaseType.contains("video") {
            return "video"
        } else {
            return "doc"
        }
    }
}

private struct MediaTypeIcon: View {
    let type: String
    
    var body: some View {
        Group {
            let lowercaseType = type.lowercased()
            if lowercaseType.contains("image") {
                Image(systemName: "photo.fill")
                    .foregroundColor(.blue)
            } else if lowercaseType.contains("video") {
                Image(systemName: "video.fill")
                    .foregroundColor(.red)
            } else {
                Image(systemName: "doc.fill")
                    .foregroundColor(.gray)
            }
        }
        .font(.caption)
    }
}

private struct MediaMetadataGrid: View {
    let media: ParsedMedia
    
    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 12) {
            MetadataItem(label: "Media Type", value: media.mediaType)
            MetadataItem(label: "MIME Type", value: media.mimeType ?? "Unknown")
            MetadataItem(label: "Size", value: media.formattedSize)
            MetadataItem(label: "Confidence", value: String(format: "%.1f%%", media.parseConfidence * 100))
            MetadataItem(label: "Alt Text", value: media.altText ?? "None")
            MetadataItem(label: "Parse Status", value: media.parseSuccessful ? "Success" : "Failed")
        }
    }
}

private struct MediaTechnicalDetailsView: View {
    let media: ParsedMedia
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Blob CID:")
                    .fontWeight(.medium)
                Spacer()
                Text(media.blobCID)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            HStack {
                Text("Record Key:")
                    .fontWeight(.medium)
                Spacer()
                Text(media.recordKey)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            if let aspectRatio = media.aspectRatio {
                HStack {
                    Text("Aspect Ratio:")
                        .fontWeight(.medium)
                    Spacer()
                    Text(aspectRatio)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MediaRawDataView: View {
    let media: ParsedMedia
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
                        Text("CBOR Data (\(media.rawCBORData.count) bytes)")
                            .font(.headline)
                        
                        Text(media.rawCBORData.map { String(format: "%02x", $0) }.joined(separator: " "))
                            .font(.system(.caption, design: .monospaced))
                            .padding()
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
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

// MARK: - Analytics View

private struct MediaAnalyticsView: View {
     var viewModel: MediaGalleryViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Summary statistics
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Media Analytics")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 12) {
                            AnalyticsCard(
                                title: "Total Media",
                                value: "\(viewModel.mediaItems.count)",
                                icon: "photo.stack",
                                color: .blue
                            )
                            
                            AnalyticsCard(
                                title: "Media Types",
                                value: "\(viewModel.mediaByType.count)",
                                icon: "list.bullet",
                                color: .green
                            )
                            
                            AnalyticsCard(
                                title: "Total Size",
                                value: ByteCountFormatter.string(fromByteCount: viewModel.totalMediaSize, countStyle: .file),
                                icon: "internaldrive",
                                color: .purple
                            )
                            
                            AnalyticsCard(
                                title: "Avg Confidence",
                                value: String(format: "%.1f%%", averageConfidence * 100),
                                icon: "chart.bar",
                                color: .orange
                            )
                        }
                    }
                    
                    // Type breakdown
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Media Types")
                            .font(.headline)
                        
                        ForEach(Array(viewModel.mediaByType.keys.sorted()), id: \.self) { type in
                            HStack {
                                MediaTypeIcon(type: type)
                                Text(type.capitalized)
                                    .fontWeight(.medium)
                                Spacer()
                                Text("\(viewModel.mediaByType[type] ?? 0)")
                                    .fontWeight(.bold)
                            }
                            .padding()
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Analytics")
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
    
    private var averageConfidence: Double {
        guard !viewModel.mediaItems.isEmpty else { return 0 }
        let total = viewModel.mediaItems.reduce(0) { $0 + $1.parseConfidence }
        return total / Double(viewModel.mediaItems.count)
    }
}

private struct AnalyticsCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(color)
        }
        .padding()
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Supporting Types

struct MediaGroup {
    let date: Date
    let mediaItems: [ParsedMedia]
}

enum MediaLayoutMode: String, CaseIterable {
    case grid = "grid"
    case list = "list"
    case timeline = "timeline"
    
    var displayName: String {
        switch self {
        case .grid:
            return "Grid"
        case .list:
            return "List"
        case .timeline:
            return "Timeline"
        }
    }
    
    var systemImage: String {
        switch self {
        case .grid:
            return "square.grid.3x3"
        case .list:
            return "list.bullet"
        case .timeline:
            return "calendar"
        }
    }
}

enum MediaTypeFilter: String, CaseIterable {
    case all = "all"
    case images = "images"
    case videos = "videos"
    case unknown = "unknown"
    
    var displayName: String {
        switch self {
        case .all:
            return "All Types"
        case .images:
            return "Images"
        case .videos:
            return "Videos"
        case .unknown:
            return "Unknown"
        }
    }
}

enum MediaSortOrder: String, CaseIterable {
    case dateAscending = "date_asc"
    case dateDescending = "date_desc"
    case size = "size"
    case confidence = "confidence"
    case type = "type"
    
    var displayName: String {
        switch self {
        case .dateAscending:
            return "Oldest First"
        case .dateDescending:
            return "Newest First"
        case .size:
            return "File Size"
        case .confidence:
            return "Parse Confidence"
        case .type:
            return "Media Type"
        }
    }
    
    var systemImage: String {
        switch self {
        case .dateAscending:
            return "arrow.up"
        case .dateDescending:
            return "arrow.down"
        case .size:
            return "internaldrive"
        case .confidence:
            return "checkmark.circle"
        case .type:
            return "textformat"
        }
    }
}

// Reuse components from other views
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

#Preview {
    let sampleRepository = RepositoryRecord(
        backupRecordID: UUID(),
        userDID: "did:plc:example",
        userHandle: "alice.bsky.social",
        originalCarSize: 1024000
    )
    
    return RepositoryMediaGalleryView(repository: sampleRepository)
        .modelContainer(for: [RepositoryRecord.self, ParsedMedia.self], inMemory: true)
}
