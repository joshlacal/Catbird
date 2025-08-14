import SwiftUI
import SwiftData
import Charts

// MARK: - ⚠️ EXPERIMENTAL CONNECTIONS ANALYTICS ⚠️

/// 🧪 EXPERIMENTAL: View for analyzing social connections from repository data
/// ⚠️ This shows experimental parsing results of follow/follower relationships
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
                    .background(Color(UIColor.systemGroupedBackground))
                
                // Main content
                if viewModel.connections.isEmpty && !viewModel.isLoading {
                    emptyConnectionsView
                } else {
                    connectionsContentView
                }
            }
            .navigationTitle("Social Connections")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
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
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            Text("No Connection Data")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("🧪 EXPERIMENTAL FEATURE\n\nNo social connections found in this repository. This could indicate parsing issues or no follow/follower records in the backup.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            Button("Retry Loading") {
                viewModel.loadConnections()
            }
            .buttonStyle(.bordered)
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
            errorMessage = "Failed to load connections: \(error.localizedDescription)"
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
                    Text("🧪 EXPERIMENTAL CONNECTIONS ANALYSIS")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                    
                    Text("Social connections parsed from \(repository.userHandle)'s repository data. Results may be incomplete.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            // Statistics row
            HStack(spacing: 16) {
                StatisticBadge(label: "Connections", value: "\(repository.connectionCount)")
                StatisticBadge(label: "Success Rate", value: repository.successRate)
                StatisticBadge(label: "Confidence", value: String(format: "%.0f%%", repository.parsingConfidenceScore * 100))
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
            return ("Follows", "person.badge.plus", .blue)
        case "block":
            return ("Blocks", "person.badge.minus", .red)
        case "mute":
            return ("Mutes", "speaker.slash", .orange)
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
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
            }
            
            HStack {
                Text("\(count)")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(displayInfo.color)
                Spacer()
            }
        }
        .padding()
        .background(displayInfo.color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                .foregroundStyle(.blue.gradient)
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
                        Text(shortDID)
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        Text(connection.ageDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 2) {
                        if !connection.parseSuccessful {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                        }
                        
                        ConfidenceBadge(confidence: connection.parseConfidence)
                    }
                }
                
                if connection.targetUserDID != shortDID {
                    Text(connection.targetUserDID)
                        .font(.caption2)
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
                    .foregroundColor(.blue)
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
        .font(.caption)
    }
}

// MARK: - Connection Detail View

private struct ConnectionDetailView: View {
    let connection: ParsedConnection
    let repository: RepositoryRecord
    @Environment(\.dismiss) private var dismiss
    @State private var showingRawData = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Connection header
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Connection Details")
                                .font(.title2)
                                .fontWeight(.bold)
                            
                            Spacer()
                            
                            ConnectionTypeIcon(type: connection.connectionType)
                        }
                        
                        Text(connection.ageDescription)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Divider()
                    
                    // Connection info
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connection Information")
                            .font(.headline)
                        
                        ConnectionMetadataGrid(connection: connection)
                    }
                    
                    // Technical details
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Technical Details")
                            .font(.headline)
                        
                        ConnectionTechnicalDetailsView(connection: connection)
                    }
                    
                    if !connection.parseSuccessful {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Parse Error")
                                .font(.headline)
                                .foregroundColor(.red)
                            
                            Text(connection.parseErrorMessage ?? "Unknown parsing error")
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
            .navigationTitle("Connection Detail")
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
                ConnectionRawDataView(connection: connection)
            }
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
            MetadataItem(label: "Confidence", value: String(format: "%.1f%%", connection.parseConfidence * 100))
            MetadataItem(label: "Parse Status", value: connection.parseSuccessful ? "Success" : "Failed")
            MetadataItem(label: "Created", value: DateFormatter.localizedString(from: connection.createdAt, dateStyle: .medium, timeStyle: .short))
        }
    }
}

private struct ConnectionTechnicalDetailsView: View {
    let connection: ParsedConnection
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CID:")
                    .fontWeight(.medium)
                Spacer()
                Text(connection.recordCID)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            HStack {
                Text("Data Size:")
                    .fontWeight(.medium)
                Spacer()
                Text("\(connection.rawCBORData.count) bytes")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

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
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    
                    // Raw data
                    VStack(alignment: .leading, spacing: 8) {
                        Text("CBOR Data (\(connection.rawCBORData.count) bytes)")
                            .font(.headline)
                        
                        Text(connection.rawCBORData.map { String(format: "%02x", $0) }.joined(separator: " "))
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
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 12) {
                            AnalyticsCard(
                                title: "Total Connections",
                                value: "\(viewModel.connections.count)",
                                icon: "person.2",
                                color: .blue
                            )
                            
                            AnalyticsCard(
                                title: "Connection Types",
                                value: "\(viewModel.connectionsByType.count)",
                                icon: "list.bullet",
                                color: .green
                            )
                            
                            AnalyticsCard(
                                title: "Parse Success",
                                value: String(format: "%.1f%%", parseSuccessRate),
                                icon: "checkmark.circle",
                                color: .green
                            )
                            
                            AnalyticsCard(
                                title: "Avg Confidence",
                                value: String(format: "%.1f%%", averageConfidence * 100),
                                icon: "chart.bar",
                                color: .orange
                            )
                        }
                    }
                    
                    // Connection timeline
                    if !viewModel.connectionTimeline.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Connection Timeline")
                                .font(.headline)
                            
                            ConnectionsTimelineChart(timeline: viewModel.connectionTimeline)
                                .frame(height: 300)
                        }
                    }
                    
                    // Type breakdown
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connection Types")
                            .font(.headline)
                        
                        ForEach(Array(viewModel.connectionsByType.keys.sorted()), id: \.self) { type in
                            HStack {
                                ConnectionTypeIcon(type: type)
                                Text(type.capitalized)
                                    .fontWeight(.medium)
                                Spacer()
                                Text("\(viewModel.connectionsByType[type] ?? 0)")
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
    
    private var parseSuccessRate: Double {
        guard !viewModel.connections.isEmpty else { return 0 }
        let successful = viewModel.connections.filter { $0.parseSuccessful }.count
        return (Double(successful) / Double(viewModel.connections.count)) * 100
    }
    
    private var averageConfidence: Double {
        guard !viewModel.connections.isEmpty else { return 0 }
        let total = viewModel.connections.reduce(0) { $0 + $1.parseConfidence }
        return total / Double(viewModel.connections.count)
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
            return "All Types"
        case .follows:
            return "Follows"
        case .blocks:
            return "Blocks"
        case .mutes:
            return "Mutes"
        case .lists:
            return "Lists"
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
            return "Oldest First"
        case .dateDescending:
            return "Newest First"
        case .confidence:
            return "Parse Confidence"
        case .type:
            return "Connection Type"
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
    
    return RepositoryConnectionsView(repository: sampleRepository)
        .modelContainer(for: [RepositoryRecord.self, ParsedConnection.self], inMemory: true)
}
