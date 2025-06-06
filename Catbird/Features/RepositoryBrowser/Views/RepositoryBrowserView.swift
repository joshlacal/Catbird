import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - ⚠️ EXPERIMENTAL REPOSITORY BROWSER ⚠️

/// 🧪 EXPERIMENTAL: Main interface for browsing parsed repository data
/// ⚠️ This is experimental functionality for exploring backup CAR data
struct RepositoryBrowserView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: RepositoryBrowserViewModel?
    @State private var showingExportSheet = false
    @State private var showingFilterSheet = false
    @State private var exportedFileURL: URL?
    @State private var selectedRepositoryForDetail: RepositoryData?
    
    init() {
        // ViewModel will be initialized in onAppear with proper ModelContext
    }
    
    var body: some View {
        navigationContent
            .onAppear {
                if viewModel == nil {
                    initializeViewModel()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackupCreated"))) { _ in
                // Refresh when a new backup is created
                viewModel?.refresh()
            }
            .alert("Repository Browser Error", isPresented: errorBinding) {
                Button("OK") {
                    viewModel?.errorMessage = nil
                }
            } message: {
                Text(viewModel?.errorMessage ?? "")
            }
    }
    
    private var navigationContent: some View {
        NavigationStack {
            mainViewContent
                .navigationTitle("🧪 Repository Browser")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    toolbarItems
                }
                .searchable(text: searchTextBinding, prompt: "Search repositories...")
                .sheet(isPresented: $showingFilterSheet) {
                    filterSheetContent
                }
                .sheet(isPresented: $showingExportSheet) {
                    exportSheetContent
                }
                .sheet(item: $selectedRepositoryForDetail) { repositoryData in
                    RepositoryDetailView(repositoryID: repositoryData.id)
                }
                .fileExporter(
                    isPresented: fileExporterBinding,
                    document: exportedFileURL.map { ExportDocument(url: $0) },
                    contentType: .data,
                    defaultFilename: "catbird_repository_export"
                ) { result in
                    handleExportResult(result)
                }
        }
    }
    
    private var mainViewContent: some View {
        Group {
            if let viewModel = viewModel {
                contentView(for: viewModel)
            } else {
                ProgressView("Loading...")
                    .onAppear {
                        initializeViewModel()
                    }
            }
        }
    }
    
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Done") {
                dismiss()
            }
        }
        
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    viewModel?.refresh()
                }
                
                Button("Filter", systemImage: "line.3.horizontal.decrease.circle") {
                    showingFilterSheet = true
                }
                
                Button("Clear Filters", systemImage: "trash") {
                    viewModel?.clearFilters()
                }
                .disabled(clearFiltersDisabled)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
    
    @ViewBuilder
    private var filterSheetContent: some View {
        if let viewModel = viewModel {
            FilterSheetView(viewModel: viewModel)
        }
    }
    
    @ViewBuilder
    private var exportSheetContent: some View {
        if let viewModel = viewModel, let repository = viewModel.selectedRepository {
            ExportSheetView(repository: repository, viewModel: viewModel) { url in
                exportedFileURL = url
            }
        }
    }
    
    private var searchTextBinding: Binding<String> {
        Binding(
            get: { viewModel?.searchQuery ?? "" },
            set: { viewModel?.searchQuery = $0 }
        )
    }
    
    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel?.errorMessage != nil },
            set: { if !$0 { viewModel?.errorMessage = nil } }
        )
    }
    
    private var fileExporterBinding: Binding<Bool> {
        Binding(
            get: { exportedFileURL != nil },
            set: { if !$0 { exportedFileURL = nil } }
        )
    }
    
    private var clearFiltersDisabled: Bool {
        let isEmpty = viewModel?.searchQuery.isEmpty ?? true
        let noStartDate = viewModel?.dateFilterStart == nil
        let noEndDate = viewModel?.dateFilterEnd == nil
        return isEmpty && noStartDate && noEndDate
    }
    
    private func handleExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            print("Exported to: \(url)")
        case .failure(let error):
            print("Export failed: \(error)")
        }
        exportedFileURL = nil
    }
    
    // MARK: - ViewModel Initialization
    
    private func initializeViewModel() {
        viewModel = RepositoryBrowserViewModel(modelContext: modelContext)
    }
    
    @ViewBuilder
    private func contentView(for viewModel: RepositoryBrowserViewModel) -> some View {
        let hasData = !viewModel.repositoryData.isEmpty || !viewModel.backupData.isEmpty
        let isLoading = viewModel.isLoading
        
        if !hasData && !isLoading {
            emptyStateView
        } else {
            repositoryListView
        }
    }
    
    private func triggerBackupParsing(_ backup: BackupData) async {
        // For now, just show an alert. In a real implementation, this would
        // trigger the RepositoryParsingService to parse the backup
        await MainActor.run {
            // Show parsing alert or trigger actual parsing
            print("Would trigger parsing for backup: \(backup.userHandle)")
        }
    }
    
    // MARK: - Repository List View
    
    private var repositoryListView: some View {
        List {
            // Experimental warning section
            Section {
                ExperimentalWarningView()
            }
            
            // Parsed repository records
            if let viewModel = viewModel, !viewModel.filteredRepositories.isEmpty {
                Section("Parsed Repositories (\(viewModel.filteredRepositories.count))") {
                    ForEach(viewModel.filteredRepositories, id: \.id) { repository in
                        RepositoryRowView(repository: repository) {
                            viewModel.selectRepository(repository)
                            selectedRepositoryForDetail = repository
                        }
                    }
                }
            }
            
            // Unparsed backup records
            if let viewModel = viewModel, !viewModel.filteredBackupRecords.isEmpty {
                Section("Backup Records (Not Parsed) (\(viewModel.filteredBackupRecords.count))") {
                    ForEach(viewModel.filteredBackupRecords, id: \.id) { backup in
                        BackupRowView(backup: backup) {
                            // Trigger parsing of backup record
                            Task {
                                await triggerBackupParsing(backup)
                            }
                        }
                    }
                }
            }
            
            if viewModel?.isLoading == true {
                Section {
                    HStack {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                        Text("Loading repositories...")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }
            }
        }
        .refreshable {
            viewModel?.refresh()
        }
    }
    
    // MARK: - Empty State View
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "archivebox")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            Text("No Repository Data")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("🧪 EXPERIMENTAL FEATURE\n\nNo repository data found. Create backup CAR files from your account in Settings → Account Settings, or parse existing backup files to explore your data.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            Button("Learn More") {
                // Open help or documentation
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
}

// MARK: - Repository Row View

private struct RepositoryRowView: View {
    let repository: RepositoryData
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(repository.userHandle)
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Text(repository.userDID)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 4) {
                        StatusBadge(status: repository.parsingStatus)
                        
                        Text(repository.parsingAgeDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Statistics row
                HStack(spacing: 16) {
                    StatisticView(label: "Posts", value: "\(repository.postCount)")
                    StatisticView(label: "Success Rate", value: repository.successRate)
                    StatisticView(label: "Confidence", value: String(format: "%.1f%%", repository.parsingConfidenceScore * 100))
                    
                    Spacer()
                    
                    if repository.hasMediaReferences {
                        Image(systemName: "photo")
                            .foregroundColor(.blue)
                    }
                }
                .font(.caption)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Backup Row View

private struct BackupRowView: View {
    let backup: BackupData
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(backup.userHandle)
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Text(backup.userDID)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 4) {
                        StatusBadge(status: .notStarted)
                        
                        Text(formatBackupAge(backup.createdDate))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Backup info row
                HStack(spacing: 16) {
                    StatisticView(label: "Size", value: ByteCountFormatter.string(fromByteCount: backup.fileSize, countStyle: .file))
                    StatisticView(label: "Status", value: backup.status?.rawValue.capitalized ?? "Unknown")
                    
                    Spacer()
                    
                    Image(systemName: "archivebox")
                        .foregroundColor(.orange)
                }
                .font(.caption)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private func formatBackupAge(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Supporting Views

private struct ExperimentalWarningView: View {
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("🧪 EXPERIMENTAL FEATURE")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.orange)
                
                Text("This browser shows experimental parsing results from CAR backup files. Data accuracy and completeness are not guaranteed.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
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

private struct StatisticView: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Filter Sheet

private struct FilterSheetView: View {
    @Bindable var viewModel: RepositoryBrowserViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section("Date Range") {
                    DatePicker("Start Date", selection: Binding(
                        get: { viewModel.dateFilterStart ?? Date.distantPast },
                        set: { viewModel.dateFilterStart = $0 }
                    ), displayedComponents: .date)
                    
                    DatePicker("End Date", selection: Binding(
                        get: { viewModel.dateFilterEnd ?? Date() },
                        set: { viewModel.dateFilterEnd = $0 }
                    ), displayedComponents: .date)
                }
                
                Section("Data Type") {
                    Picker("Filter by", selection: $viewModel.dataTypeFilter) {
                        ForEach(DataTypeFilter.allCases, id: \.self) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                }
                
                Section("Sort Order") {
                    Picker("Sort by", selection: $viewModel.sortOrder) {
                        ForEach(SortOrder.allCases, id: \.self) { order in
                            Label(order.rawValue, systemImage: order.systemImage).tag(order)
                        }
                    }
                }
            }
            .navigationTitle("Filter Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Reset") {
                        viewModel.clearFilters()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Export Sheet

private struct ExportSheetView: View {
    let repository: RepositoryData
    @Bindable var viewModel: RepositoryBrowserViewModel
    let onExport: (URL) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFormat: ExportFormat = .json
    @State private var isExporting = false
    
    var body: some View {
        NavigationView {
            exportFormContent
                .navigationTitle("Export Data")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    exportToolbarItems
                }
        }
    }
    
    @ViewBuilder
    private var exportFormContent: some View {
        Form {
            repositoryInfoSection
            exportFormatSection
            experimentalWarningSection
            exportProgressSection
        }
    }
    
    @ViewBuilder
    private var repositoryInfoSection: some View {
        Section("Repository") {
            VStack(alignment: .leading, spacing: 4) {
                Text(repository.userHandle)
                    .font(.headline)
                repositoryStatsText
            }
        }
    }
    
    private var repositoryStatsText: some View {
        Text("\(repository.postCount) posts, \(repository.connectionCount) connections")
            .font(.caption)
            .foregroundColor(.secondary)
    }
    
    @ViewBuilder
    private var exportFormatSection: some View {
        Section("Export Format") {
            ForEach(ExportFormat.allCases, id: \.self) { format in
                exportFormatRow(for: format)
            }
        }
    }
    
    @ViewBuilder
    private func exportFormatRow(for format: ExportFormat) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(format.rawValue)
                    .fontWeight(.medium)
                Text(format.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if selectedFormat == format {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.blue)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedFormat = format
        }
    }
    
    @ViewBuilder
    private var experimentalWarningSection: some View {
        Section {
            ExperimentalWarningView()
        }
    }
    
    @ViewBuilder
    private var exportProgressSection: some View {
        if viewModel.isExporting {
            Section("Export Progress") {
                VStack(spacing: 8) {
                    ProgressView(value: viewModel.exportProgress)
                    Text("Exporting data...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    @ToolbarContentBuilder
    private var exportToolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Cancel") {
                dismiss()
            }
            .disabled(viewModel.isExporting)
        }
        
        ToolbarItem(placement: .navigationBarTrailing) {
            Button("Export") {
                handleExportAction()
            }
            .disabled(viewModel.isExporting)
        }
    }
    
    private func handleExportAction() {
        Task {
            do {
                let url = try await viewModel.exportRepositoryData(repository, format: selectedFormat)
                await MainActor.run {
                    onExport(url)
                    dismiss()
                }
            } catch {
                print("Export failed: \(error)")
            }
        }
    }
}

// MARK: - Export Document

private struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    
    let url: URL
    
    init(url: URL) {
        self.url = url
    }
    
    init(configuration: ReadConfiguration) throws {
        fatalError("Reading not supported")
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return try FileWrapper(url: url)
    }
}

#Preview {
    RepositoryBrowserView()
        .modelContainer(for: RepositoryRecord.self, inMemory: true)
}
