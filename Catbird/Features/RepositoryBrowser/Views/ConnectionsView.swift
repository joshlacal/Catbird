import SwiftUI
import SwiftData
import Charts

// MARK: - Connections Analytics

/// View for analyzing social connections from repository data
/// This shows parsing results of follow/follower relationships
struct RepositoryConnectionsView: View {
    let repository: RepositoryRecord
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: ConnectionsViewModel
    @State private var selectedConnection: ParsedConnection?
    @State private var showingAnalytics = false
    
    init(repository: RepositoryRecord) {
        self.repository = repository
        self._viewModel = State(initialValue: ConnectionsViewModel(repositoryID: repository.id))
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Experimental warning header
                ExperimentalConnectionsHeader(repository: repository)
                    .background(Color(platformColor: PlatformColor.platformSystemGroupedBackground))
                
                // Main content
                if viewModel.connections.isEmpty && !viewModel.isLoading {
                    emptyConnectionsView
                } else {
                    connectionsContentView
                }
            }
            .navigationTitle("Social Connections")
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            viewModel.loadConnections()
                        }
                        
                        Button("Analytics", systemImage: "chart.bar") {
                            showingAnalytics = true
                        }
                        
                        Picker("Connection Type", selection: $viewModel.connectionTypeFilter) {
                            ForEach(ConnectionTypeFilter.allCases, id: \.self) { filter in
                                Text(filter.displayName).tag(filter)
                            }
                        }
                        
                        Picker("Sort Order", selection: $viewModel.sortOrder) {
                            ForEach(ConnectionSortOrder.allCases, id: \.self) { order in
                                Label(order.displayName, systemImage: order.systemImage).tag(order)
                            }
                        }
                        
                        Toggle("Show Parse Errors", isOn: $viewModel.showParseErrors)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .searchable(text: $viewModel.searchQuery, prompt: "Search connections...")
            .sheet(isPresented: $showingAnalytics) {
                ConnectionsAnalyticsView(viewModel: viewModel)
            }
            .sheet(item: $selectedConnection) { connection in
                ConnectionDetailView(connection: connection, repository: repository)
            }
        }
        .onAppear {
            viewModel.setModelContext(modelContext)
            viewModel.loadConnections()
        }
    }
    
    // MARK: - Connections Content View
    
    private var connectionsContentView: some View {
        List {
            // Summary section
            Section("Connection Summary") {
                ConnectionsSummaryView(viewModel: viewModel)
            }
            
            // Timeline section
            if !viewModel.connectionTimeline.isEmpty {
                Section("Connection Timeline") {
                    ConnectionsTimelineChart(timeline: viewModel.connectionTimeline)
                        .frame(height: 200)
                }
            }
            
            // Connections list
            Section("All Connections (\(viewModel.filteredConnections.count))") {
                ForEach(viewModel.filteredConnections, id: \.id) { connection in
                    ConnectionRowView(connection: connection) {
                        selectedConnection = connection
                    }
                }
            }
            
            if viewModel.isLoading {
                Section {
                    HStack {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                        Text("Loading connections...")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }
            }
        }
        .refreshable {
            viewModel.loadConnections()
        }
    }
    
    // MARK: - Empty Connections View
    
    private var emptyConnectionsView: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.2.badge.minus")
                .appFont(size: 64)
                .foregroundColor(.secondary)
            
            Text("No Connection Data")
                .appFont(AppTextRole.title2)
                .fontWeight(.semibold)
            
            Text("No social connections found in this repository. This could indicate parsing issues or no follow/follower records in the backup.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            Button("Retry Loading") {
                viewModel.loadConnections()
            }
            .buttonStyle(.catbird(.tonal))
        }
        .padding()
    }
}

// MARK: - Connections ViewModel

@MainActor
@Observable
final class ConnectionsViewModel {
    private let repositoryID: UUID
    private var modelContext: ModelContext?
    
    var connections: [ParsedConnection] = []
    var isLoading = false
    var errorMessage: String?
    var searchQuery = ""
    var sortOrder: ConnectionSortOrder = .dateDescending
    var connectionTypeFilter: ConnectionTypeFilter = .all
    var showParseErrors = false
    
    init(repositoryID: UUID) {
        self.repositoryID = repositoryID
    }
    
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }
    
    var filteredConnections: [ParsedConnection] {
        var filtered = connections
        
        // Apply search filter
        if !searchQuery.isEmpty {
            filtered = filtered.filter { connection in
                connection.targetUserDID.localizedCaseInsensitiveContains(searchQuery) ||
                connection.recordKey.localizedCaseInsensitiveContains(searchQuery)
            }
        }
        
        // Apply connection type filter
        switch connectionTypeFilter {
        case .all:
            break
        case .follows:
            filtered = filtered.filter { $0.connectionType == "follow" }
        case .blocks:
            filtered = filtered.filter { $0.connectionType == "block" }
        case .mutes:
            filtered = filtered.filter { $0.connectionType == "mute" }
        case .lists:
            filtered = filtered.filter { $0.connectionType.contains("list") }
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
        case .type:
            filtered.sort { $0.connectionType < $1.connectionType }
        }
        
        return filtered
    }
    
    var connectionsByType: [String: Int] {
        Dictionary(grouping: filteredConnections) { $0.connectionType }
            .mapValues { $0.count }
    }
    
    var connectionTimeline: [ConnectionTimelinePoint] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredConnections) { connection in
            calendar.startOfDay(for: connection.createdAt)
        }
        
        return grouped.map { date, connections in
            ConnectionTimelinePoint(date: date, count: connections.count)
        }.sorted { $0.date < $1.date }
    }
    
    func loadConnections() {
        guard let modelContext = modelContext else { return }
        
        isLoading = true
        errorMessage = nil
        
        do {
            let descriptor = FetchDescriptor<ParsedConnection>(
                predicate: #Predicate { $0.repositoryRecordID == repositoryID },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            connections = try modelContext.fetch(descriptor)
        } catch {
            errorMessage = String(
                localized: "Failed to load connections: \(error.localizedDescription)",
                comment: "Error shown when loading repository connections fails."
            )
        }
        
        isLoading = false
    }
}

// MARK: - Supporting Views

private struct ExperimentalConnectionsHeader: View {
    let repository: RepositoryRecord
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("CONNECTIONS ANALYSIS")
                        .appFont(AppTextRole.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                    
                    Text(
                        "Social connections parsed from \(repository.userHandle)'s repository data. Results may be incomplete.",
                        comment: "Disclaimer header on connections analysis view. Placeholder is the repository owner's handle."
                    )
                        .appFont(AppTextRole.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            // Statistics row
            HStack(spacing: 16) {
                StatisticBadge(label: "Connections", value: repository.connectionCount.formatted(.number))
                StatisticBadge(label: "Success Rate", value: repository.successRate)
                StatisticBadge(label: "Confidence", value: repository.parsingConfidenceScore.formatted(.percent.precision(.fractionLength(0))))
                Spacer()
            }
        }
        .padding()
    }
}

private struct ConnectionsSummaryView: View {
    var viewModel: ConnectionsViewModel
    
    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 12) {
            ForEach(Array(viewModel.connectionsByType.keys.sorted()), id: \.self) { type in
                ConnectionTypeSummary(
                    type: type,
                    count: viewModel.connectionsByType[type] ?? 0
                )
            }
        }
    }
}

private struct ConnectionTypeSummary: View {
    let type: String
    let count: Int
    
    private var displayInfo: (name: String, icon: String, color: Color) {
        switch type.lowercased() {
        case "follow":
            return (String(localized: "Follows", comment: "Social connection category for accounts the user follows."), "person.badge.plus", .blue)
        case "block":
            return (String(localized: "Blocks", comment: "Social connection category for blocked accounts."), "person.badge.minus", .red)
        case "mute":
            return (String(localized: "Mutes", comment: "Social connection category for muted accounts."), "speaker.slash", .orange)
        default:
            return (type.capitalized, "person.2", .gray)
        }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: displayInfo.icon)
                    .foregroundColor(displayInfo.color)
                Text(displayInfo.name)
                    .appFont(AppTextRole.caption)
                    .fontWeight(.medium)
                Spacer()
            }
            
            HStack {
                Text(count, format: .number)
                    .appFont(AppTextRole.title2)
                    .fontWeight(.bold)
                    .foregroundColor(displayInfo.color)
                Spacer()
            }
        }
        .padding()
        .background(displayInfo.color.opacity(0.1))
        .clipShape(Radius.sm.shape)
    }
}

private struct ConnectionsTimelineChart: View {
    let timeline: [ConnectionTimelinePoint]
    
    var body: some View {
        Chart {
            ForEach(timeline, id: \.date) { point in
                BarMark(
                    x: .value("Date", point.date),
                    y: .value("Connections", point.count)
                )
                .foregroundStyle(Color.accentColor.gradient)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel()
            }
        }
        .padding()
    }
}

private struct ConnectionRowView: View {
    let connection: ParsedConnection
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ConnectionTypeIcon(type: connection.connectionType)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: shortDID)
                            .appFont(AppTextRole.body)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        Text(connection.ageDescription)
                            .appFont(AppTextRole.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 2) {
                        if !connection.parseSuccessful {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .appFont(AppTextRole.caption)
                        }
                        
                        ConfidenceBadge(confidence: connection.parseConfidence)
                    }
                }
                
                if connection.targetUserDID != shortDID {
                    Text(verbatim: connection.targetUserDID)
                        .appFont(AppTextRole.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var shortDID: String {
        let components = connection.targetUserDID.components(separatedBy: ":")
        if components.count >= 3 {
            return String(components[2].prefix(12)) + "..."
        }
        return connection.targetUserDID
    }
}

private struct ConnectionTypeIcon: View {
    let type: String
    
    var body: some View {
        Group {
            switch type.lowercased() {
            case "follow":
                Image(systemName: "person.badge.plus.fill")
                    .foregroundColor(Color.accentColor)
            case "block":
                Image(systemName: "person.badge.minus.fill")
                    .foregroundColor(.red)
            case "mute":
                Image(systemName: "speaker.slash.fill")
                    .foregroundColor(.orange)
            default:
                Image(systemName: "person.2.fill")
                    .foregroundColor(.gray)
            }
        }
        .appFont(AppTextRole.caption)
    }
}

// MARK: - Connection Detail View

private struct ConnectionDetailView: View {
    let connection: ParsedConnection
    let repository: RepositoryRecord
    @Environment(\.dismiss) private var dismiss
    #if DEBUG
    @State private var showingRawData = false
    #endif
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Connection header
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Connection Details")
                                .appFont(AppTextRole.title2)
                                .fontWeight(.bold)
                            
                            Spacer()
                            
                            ConnectionTypeIcon(type: connection.connectionType)
                        }
                        
                        Text(connection.ageDescription)
                            .appFont(AppTextRole.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Divider()
                    
                    // Connection info
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connection Information")
                            .appFont(AppTextRole.headline)
                        
                        ConnectionMetadataGrid(connection: connection)
                    }
                    
                    // Technical details
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Technical Details")
                            .appFont(AppTextRole.headline)
                        
                        ConnectionTechnicalDetailsView(connection: connection)
                    }
                    
                    if !connection.parseSuccessful {
                        VStack(alignment: .leading, spacing: 12) {
                            CatbirdNotice(
                                tone: .error,
                                title: Text("Parse Error"),
                                message: Text(
                                  connection.parseErrorMessage
                                    ?? String(localized: "Unknown parsing error", comment: "Fallback message when a record failed to parse without a specific error message.")))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Connection Detail")
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Close") {
                        dismiss()
                    }
                }
                
                #if DEBUG
                ToolbarItem(placement: .automatic) {
                    Button("Raw Data") {
                        showingRawData = true
                    }
                }
                #endif
            }
            #if DEBUG
            .sheet(isPresented: $showingRawData) {
                ConnectionRawDataView(connection: connection)
            }
            #endif
        }
    }
}

private struct ConnectionMetadataGrid: View {
    let connection: ParsedConnection
    
    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 12) {
            MetadataItem(label: "Connection Type", value: connection.connectionType.capitalized)
            MetadataItem(label: "Record Key", value: connection.recordKey)
            MetadataItem(label: "Target DID", value: connection.targetUserDID)
            MetadataItem(label: "Confidence", value: connection.parseConfidence.formatted(.percent.precision(.fractionLength(1))))
            MetadataItem(
                label: "Parse Status",
                value: connection.parseSuccessful
                    ? String(localized: "Success", comment: "Record parse status when parsing succeeded.")
                    : String(localized: "Failed", comment: "Record parse status when parsing failed.")
            )
            MetadataItem(label: "Created", value: connection.createdAt.formatted(date: .abbreviated, time: .shortened))
        }
    }
}

private struct ConnectionTechnicalDetailsView: View {
    let connection: ParsedConnection
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CID:", comment: "Label for Content Identifier (CID) of an AT Protocol record.")
                    .fontWeight(.medium)
                Spacer()
                Text(verbatim: connection.recordCID)
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            HStack {
                Text("Data Size:")
                    .fontWeight(.medium)
                Spacer()
                Text("\(connection.rawCBORData.count) bytes", comment: "Byte size of raw CBOR record data.")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(platformColor: PlatformColor.platformSecondarySystemGroupedBackground))
        .clipShape(Radius.sm.shape)
    }
}

#if DEBUG
private struct ConnectionRawDataView: View {
    let connection: ParsedConnection
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
                        Text("CBOR Data (\(connection.rawCBORData.count) bytes)", comment: "Section header showing raw CBOR payload size in bytes.")
                            .appFont(AppTextRole.headline)
                        
                        Text(verbatim: connection.rawCBORData.map { String(format: "%02x", $0) }.joined(separator: " "))
                            .font(.system(.caption, design: .monospaced))
                            .padding()
                            .background(Color(platformColor: PlatformColor.platformSecondarySystemGroupedBackground))
                            .clipShape(Radius.sm.shape)
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

// MARK: - Analytics View

private struct ConnectionsAnalyticsView: View {
    var viewModel: ConnectionsViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Summary statistics
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connection Analytics")
                            .appFont(AppTextRole.title2)
                            .fontWeight(.bold)
                        
                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 12) {
                            AnalyticsCard(
                                title: "Total Connections",
                                value: viewModel.connections.count.formatted(.number),
                                icon: "person.2",
                                color: .blue
                            )
                            
                            AnalyticsCard(
                                title: "Connection Types",
                                value: viewModel.connectionsByType.count.formatted(.number),
                                icon: "list.bullet",
                                color: .green
                            )
                            
                            AnalyticsCard(
                                title: "Parse Success",
                                value: parseSuccessRate.formatted(.percent.precision(.fractionLength(1))),
                                icon: "checkmark.circle",
                                color: .green
                            )
                            
                            AnalyticsCard(
                                title: "Avg Confidence",
                                value: averageConfidence.formatted(.percent.precision(.fractionLength(1))),
                                icon: "chart.bar",
                                color: .orange
                            )
                        }
                    }
                    
                    // Connection timeline
                    if !viewModel.connectionTimeline.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Connection Timeline")
                                .appFont(AppTextRole.headline)
                            
                            ConnectionsTimelineChart(timeline: viewModel.connectionTimeline)
                                .frame(height: 300)
                        }
                    }
                    
                    // Type breakdown
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connection Types")
                            .appFont(AppTextRole.headline)
                        
                        ForEach(Array(viewModel.connectionsByType.keys.sorted()), id: \.self) { type in
                            HStack {
                                ConnectionTypeIcon(type: type)
                                Text(verbatim: type.capitalized)
                                    .fontWeight(.medium)
                                Spacer()
                                Text(viewModel.connectionsByType[type] ?? 0, format: .number)
                                    .fontWeight(.bold)
                            }
                            .padding()
                            .background(Color(platformColor: PlatformColor.platformSecondarySystemGroupedBackground))
                            .clipShape(Radius.sm.shape)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Analytics")
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
    
    private var parseSuccessRate: Double {
        guard !viewModel.connections.isEmpty else { return 0 }
        let successful = viewModel.connections.filter { $0.parseSuccessful }.count
        return Double(successful) / Double(viewModel.connections.count)
    }
    
    private var averageConfidence: Double {
        guard !viewModel.connections.isEmpty else { return 0 }
        let total = viewModel.connections.reduce(0) { $0 + $1.parseConfidence }
        return total / Double(viewModel.connections.count)
    }
}

private struct AnalyticsCard: View {
    let title: LocalizedStringResource
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(title)
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            
            Text(verbatim: value)
                .appFont(AppTextRole.title2)
                .fontWeight(.bold)
                .foregroundColor(color)
        }
        .padding()
        .background(color.opacity(0.1))
        .clipShape(Radius.sm.shape)
    }
}

// MARK: - Supporting Types

struct ConnectionTimelinePoint {
    let date: Date
    let count: Int
}

enum ConnectionTypeFilter: String, CaseIterable {
    case all = "all"
    case follows = "follows"
    case blocks = "blocks"
    case mutes = "mutes"
    case lists = "lists"
    
    var displayName: String {
        switch self {
        case .all:
            return String(localized: "All Types", comment: "Filter option showing all social connection types.")
        case .follows:
            return String(localized: "Follows", comment: "Filter option showing only follow records.")
        case .blocks:
            return String(localized: "Blocks", comment: "Filter option showing only block records.")
        case .mutes:
            return String(localized: "Mutes", comment: "Filter option showing only mute records.")
        case .lists:
            return String(localized: "Lists", comment: "Filter option showing only list records.")
        }
    }
}

enum ConnectionSortOrder: String, CaseIterable {
    case dateAscending = "date_asc"
    case dateDescending = "date_desc"
    case confidence = "confidence"
    case type = "type"
    
    var displayName: String {
        switch self {
        case .dateAscending:
            return String(localized: "Oldest First", comment: "Sort order option from oldest to newest.")
        case .dateDescending:
            return String(localized: "Newest First", comment: "Sort order option from newest to oldest.")
        case .confidence:
            return String(localized: "Parse Confidence", comment: "Sort order option by record parsing confidence score.")
        case .type:
            return String(localized: "Connection Type", comment: "Sort order option grouping by social connection type.")
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
        case .type:
            return "textformat"
        }
    }
}

// Reuse some components from other views
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

#Preview {
    let sampleRepository = RepositoryRecord(
        backupRecordID: UUID(),
        userDID: "did:plc:example",
        userHandle: "alice.bsky.social",
        originalCarSize: 1024000
    )
    
    return RepositoryConnectionsView(repository: sampleRepository)
        .modelContainer(for: [RepositoryRecord.self, ParsedConnection.self], inMemory: true)
}
