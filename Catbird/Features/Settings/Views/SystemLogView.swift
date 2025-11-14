import SwiftUI
import OSLog

/// System log viewer for debugging and diagnostics
struct SystemLogView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  
  @State private var logService: SystemLogService?
  @State private var error: Error?
  @State private var showingFilters = false
  @State private var showingLogDetail: LogEntry?
  @State private var showingExportSheet = false
  @State private var exportText = ""
  
  var body: some View {
    NavigationStack {
      Group {
        if let logService = logService {
          LogContentView(
            logService: logService,
            showingFilters: $showingFilters,
            showingLogDetail: $showingLogDetail,
            showingExportSheet: $showingExportSheet,
            exportText: $exportText
          )
        } else if let error = error {
          ErrorView(error: error, onRetry: initializeLogService)
        } else {
          SystemLogLoadingView()
        }
      }
      .navigationTitle("System Logs")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") {
            dismiss()
          }
        }
        
        if logService != nil {
          ToolbarItem(placement: .primaryAction) {
            Menu {
              Button {
                Task {
                  await logService?.loadRecentLogs()
                }
              } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
              }
              
              Button {
                showingFilters = true
              } label: {
                Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
              }
              
              Button {
                logService?.clearLogs()
              } label: {
                Label("Clear", systemImage: "trash")
              }
              
              Button {
                exportText = logService?.exportLogsAsText() ?? ""
                showingExportSheet = true
              } label: {
                Label("Export", systemImage: "square.and.arrow.up")
              }
            } label: {
              Image(systemName: "ellipsis.circle")
            }
          }
        }
      }
      .sheet(isPresented: $showingFilters) {
        if let logService = logService {
          LogFilterView(logService: logService)
        }
      }
      .sheet(item: $showingLogDetail) { logEntry in
        LogDetailView(logEntry: logEntry)
      }
      .sheet(isPresented: $showingExportSheet) {
        LogExportView(exportText: exportText)
      }
      .appDisplayScale(appState: appState)
      .contrastAwareBackground(appState: appState, defaultColor: Color.systemBackground)
      .task {
        await initializeLogService()
      }
    }
  }
  
  private func initializeLogService() async {
    do {
      let service = try SystemLogService()
      await MainActor.run {
        self.logService = service
        self.error = nil
      }
      await service.loadRecentLogs()
    } catch {
      await MainActor.run {
        self.error = error
        self.logService = nil
      }
    }
  }
}

// MARK: - Log Content View

private struct LogContentView: View {
  @Bindable var logService: SystemLogService
  @Binding var showingFilters: Bool
  @Binding var showingLogDetail: LogEntry?
  @Binding var showingExportSheet: Bool
  @Binding var exportText: String
  
  var body: some View {
    VStack(spacing: 0) {
      // Status bar with entry count and filters
      StatusBarView(logService: logService)
      
      // Log entries list
      if logService.logEntries.isEmpty {
        EmptyStateView(isLoading: logService.isLoading)
      } else {
        LogListView(
          entries: logService.logEntries,
          isLoading: logService.isLoading,
          showingLogDetail: $showingLogDetail
        )
      }
    }
  }
}

// MARK: - Status Bar

private struct StatusBarView: View {
  let logService: SystemLogService
  
  var body: some View {
    HStack {
      Text("\(logService.logEntries.count) entries")
        .appCaption()
        .foregroundStyle(.secondary)
      
      if !logService.filterSettings.searchText.isEmpty {
        Text("• Filtered")
          .appCaption()
          .foregroundStyle(.blue)
      }
      
      Spacer()
      
      if logService.isLoading {
        ProgressView()
          .scaleEffect(0.8)
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(Color.systemGray6)
  }
}

// MARK: - Empty State

private struct EmptyStateView: View {
  let isLoading: Bool
  
  var body: some View {
    VStack(spacing: 16) {
      if isLoading {
        ProgressView("Loading logs...")
          .progressViewStyle(CircularProgressViewStyle())
      } else {
        Image(systemName: "doc.text.magnifyingglass")
          .font(.system(size: 48))
          .foregroundStyle(.secondary)
        
        Text("No log entries found")
          .appHeadline()
          .foregroundStyle(.secondary)
        
        Text("Try adjusting your filter settings or refresh to load new entries")
          .appBody()
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
      }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Log List

private struct LogListView: View {
  let entries: [LogEntry]
  let isLoading: Bool
  @Binding var showingLogDetail: LogEntry?
  
  var body: some View {
    List {
      ForEach(entries) { entry in
        LogEntryRow(entry: entry) {
          showingLogDetail = entry
        }
      }
      
      if isLoading {
        HStack {
          Spacer()
          ProgressView()
            .padding()
          Spacer()
        }
      }
    }
    .listStyle(PlainListStyle())
  }
}

// MARK: - Log Entry Row

private struct LogEntryRow: View {
  let entry: LogEntry
  let onTap: () -> Void
  
  var body: some View {
    Button(action: onTap) {
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          // Log level indicator
          Image(systemName: entry.level.systemImage)
            .foregroundStyle(entry.level.color)
            .font(.caption)
          
          Text(entry.level.displayName)
            .appCaption()
            .foregroundStyle(entry.level.color)
          
          Spacer()
          
          Text(entry.formattedTimestamp)
            .appCaption()
            .foregroundStyle(.secondary)
        }
        
        Text(entry.message)
          .appBody()
          .lineLimit(3)
          .multilineTextAlignment(.leading)
        
        HStack {
          Text(entry.subsystem)
            .appCaption()
            .foregroundStyle(.secondary)
          
          Text("•")
            .appCaption()
            .foregroundStyle(.secondary)
          
          Text(entry.category)
            .appCaption()
            .foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 4)
    }
    .buttonStyle(PlainButtonStyle())
  }
}

// MARK: - Error View

private struct ErrorView: View {
  let error: Error
  let onRetry: () async -> Void
  
  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 48))
        .foregroundStyle(.orange)
      
      Text("Failed to Load Logs")
        .appHeadline()
      
      Text(error.localizedDescription)
        .appBody()
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      
      Button("Retry") {
        Task {
          await onRetry()
        }
      }
      .buttonStyle(.borderedProminent)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Loading View

private struct SystemLogLoadingView: View {
  var body: some View {
    VStack(spacing: 16) {
      ProgressView()
        .scaleEffect(1.2)
      
      Text("Initializing log service...")
        .appBody()
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Log Filter View

private struct LogFilterView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var logService: SystemLogService
  @State private var filterSettings: LogFilterSettings
  
  init(logService: SystemLogService) {
    self.logService = logService
    self._filterSettings = State(initialValue: logService.filterSettings)
  }
  
  var body: some View {
    NavigationStack {
      Form {
        Section("Log Levels") {
          ForEach(LogLevel.allCases, id: \.self) { level in
            Toggle(isOn: Binding(
              get: { filterSettings.logLevels.contains(level) },
              set: { isSelected in
                if isSelected {
                  filterSettings.logLevels.insert(level)
                } else {
                  filterSettings.logLevels.remove(level)
                }
              }
            )) {
              HStack {
                Image(systemName: level.systemImage)
                  .foregroundStyle(level.color)
                Text(level.displayName)
              }
            }
          }
        }
        
        Section("Time Range") {
          Picker("Time Range", selection: $filterSettings.timeRange) {
            ForEach(LogTimeRange.allCases, id: \.self) { range in
              Text(range.displayName).tag(range)
            }
          }
          #if os(iOS)
          .pickerStyle(WheelPickerStyle())
          #endif
        }
        
        Section("Search") {
          TextField("Search message text", text: $filterSettings.searchText)
        }
        
        Section("Subsystems") {
          Toggle("Show only Catbird logs", isOn: Binding(
            get: { filterSettings.subsystems.contains(OSLog.subsystem) },
            set: { isSelected in
              if isSelected {
                filterSettings.subsystems = [OSLog.subsystem]
              } else {
                filterSettings.subsystems = []
              }
            }
          ))
        }
      }
      .navigationTitle("Log Filters")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", systemImage: "xmark") {
            dismiss()
          }
        }
        
        ToolbarItem(placement: .primaryAction) {
          Button("Apply") {
            Task {
              await logService.updateFilter(filterSettings)
              dismiss()
            }
          }
        }
      }
    }
  }
}

// MARK: - Log Detail View

private struct LogDetailView: View {
  @Environment(\.dismiss) private var dismiss
  let logEntry: LogEntry
  
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          // Header info
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Image(systemName: logEntry.level.systemImage)
                .foregroundStyle(logEntry.level.color)
              Text(logEntry.level.displayName)
                .appHeadline()
                .foregroundStyle(logEntry.level.color)
              Spacer()
            }
            
            Text(logEntry.fullTimestamp)
              .appBody()
              .foregroundStyle(.secondary)
          }
          
          // Message
          VStack(alignment: .leading, spacing: 4) {
            Text("Message")
              .appSubheadline()
              .fontWeight(.semibold)
            
            Text(logEntry.message)
              .appBody()
              .textSelection(.enabled)
          }
          
          // Metadata
          VStack(alignment: .leading, spacing: 8) {
            Text("Metadata")
              .appSubheadline()
              .fontWeight(.semibold)
            
            DetailRow(label: "Subsystem", value: logEntry.subsystem)
            DetailRow(label: "Category", value: logEntry.category)
            DetailRow(label: "Process", value: logEntry.process)
            DetailRow(label: "Thread", value: String(logEntry.thread))
          }
        }
        .padding()
      }
      .navigationTitle("Log Entry")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
    }
  }
}

private struct DetailRow: View {
  let label: String
  let value: String
  
  var body: some View {
    HStack {
      Text(label)
        .appCaption()
        .foregroundStyle(.secondary)
        .frame(width: 80, alignment: .leading)
      
      Text(value)
        .appCaption()
        .textSelection(.enabled)
      
      Spacer()
    }
  }
}

// MARK: - Log Export View

private struct LogExportView: View {
  @Environment(\.dismiss) private var dismiss
  let exportText: String
  
  var body: some View {
    NavigationStack {
      ScrollView {
        Text(exportText)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .padding()
      }
      .navigationTitle("Export Logs")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") {
            dismiss()
          }
        }
        
        ToolbarItem(placement: .primaryAction) {
          ShareLink(item: exportText) {
            Image(systemName: "square.and.arrow.up")
          }
        }
      }
    }
  }
}

// MARK: - Preview

#Preview {
    @Previewable @Environment(AppState.self) var appState
  SystemLogView()
    .environment(appState)
}
