import SwiftUI
import OSLog

/// Real-time migration progress view with emergency controls
struct MigrationProgressView: View {
  let migration: MigrationOperation?
  let migrationService: AccountMigrationService
  
  @State private var showEmergencyStop = false
  @State private var detailedLogs: [MigrationLogEntry] = []
  @State private var showDetailedLogs = false
  @State private var alertMonitor: SafetyMonitor?
  
  private let logger = Logger(subsystem: "blue.catbird", category: "MigrationProgress")
  
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        
        if let migration = migration {
          // Overall progress section
          progressHeader(migration: migration)
          
          // Current phase details
          currentPhaseSection(migration: migration)
          
          // Migration timeline
          migrationTimelineSection(migration: migration)
          
          // Safety monitoring
          safetyMonitoringSection(migration: migration)
          
          // Emergency controls
          emergencyControlsSection(migration: migration)
          
          // Technical details (expandable)
          technicalDetailsSection(migration: migration)
          
        } else {
          Text("No migration in progress")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
        }
      }
      .padding()
    }
    .navigationTitle("Migration in Progress")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .navigationBarTrailing) {
        Button {
          showDetailedLogs = true
        } label: {
          Image(systemName: "doc.text")
        }
      }
    }
    .alert("Emergency Stop", isPresented: $showEmergencyStop) {
      Button("Cancel", role: .cancel) { }
      Button("Emergency Stop", role: .destructive) {
        Task {
          try? await migrationService.cancelMigration()
        }
      }
    } message: {
      Text("This will immediately halt the migration process. Your account may be left in an incomplete state. Are you sure?")
    }
    .sheet(isPresented: $showDetailedLogs) {
      MigrationLogsView(logs: detailedLogs)
    }
    .task {
      if let migration = migration {
        await startSafetyMonitoring(migration: migration)
      }
    }
  }
  
  // MARK: - Progress Header
  
  private func progressHeader(migration: MigrationOperation) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      
      // Status and overall progress
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Account Migration")
            .font(.title2)
            .fontWeight(.semibold)
          
          Text("From \(migration.sourceServer.displayName) to \(migration.destinationServer.displayName)")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        
        Spacer()
        
        statusBadge(status: migration.status)
      }
      
      // Progress bar
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Overall Progress")
            .font(.headline)
            .fontWeight(.medium)
          
          Spacer()
          
          Text("\(Int(migration.progress * 100))%")
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
        }
        
        ProgressView(value: migration.progress)
          .progressViewStyle(LinearProgressViewStyle(tint: progressColor(for: migration.status)))
          .scaleEffect(y: 2.0)
        
        Text(migration.currentPhase)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding()
    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
  }
  
  // MARK: - Current Phase Section
  
  private func currentPhaseSection(migration: MigrationOperation) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Current Phase")
        .font(.headline)
        .fontWeight(.medium)
      
      HStack {
        Image(systemName: migration.status.systemImage)
          .foregroundStyle(colorFromString(migration.status.color))
          .font(.title2)
        
        VStack(alignment: .leading, spacing: 4) {
          Text(migration.status.description)
            .font(.callout)
            .fontWeight(.medium)
          
          Text(phaseDescription(for: migration.status))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        
        Spacer()
        
        if isActivePhase(migration.status) {
          ProgressView()
            .scaleEffect(0.8)
        }
      }
      .padding()
      .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
  }
  
  // MARK: - Migration Timeline
  
  private func migrationTimelineSection(migration: MigrationOperation) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Migration Timeline")
        .font(.headline)
        .fontWeight(.medium)
      
      VStack(alignment: .leading, spacing: 8) {
        timelineStep(
          phase: .preparing,
          title: "Preparation",
          description: "Initialize migration process",
          current: migration.status,
          startTime: migration.createdAt
        )
        
        timelineStep(
          phase: .preparingBackup,
          title: "Backup Creation",
          description: "Create pre-migration backup",
          current: migration.status,
          startTime: migration.createdAt
        )
        
        timelineStep(
          phase: .authenticating,
          title: "Authentication",
          description: "Authenticate with destination server",
          current: migration.status,
          startTime: migration.createdAt
        )
        
        timelineStep(
          phase: .validating,
          title: "Validation",
          description: "Validate server compatibility",
          current: migration.status,
          startTime: migration.createdAt
        )
        
        timelineStep(
          phase: .exporting,
          title: "Data Export",
          description: "Export repository from source",
          current: migration.status,
          startTime: migration.createdAt
        )
        
        timelineStep(
          phase: .importing,
          title: "Data Import",
          description: "Import repository to destination",
          current: migration.status,
          startTime: migration.createdAt
        )
        
        timelineStep(
          phase: .verifying,
          title: "Verification",
          description: "Verify migration integrity",
          current: migration.status,
          startTime: migration.createdAt
        )
        
        timelineStep(
          phase: .completed,
          title: "Completion",
          description: "Finalize migration process",
          current: migration.status,
          startTime: migration.createdAt
        )
      }
    }
  }
  
  // MARK: - Safety Monitoring Section
  
  private func safetyMonitoringSection(migration: MigrationOperation) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("🛡️ Safety Monitoring")
        .font(.headline)
        .fontWeight(.medium)
      
      VStack(alignment: .leading, spacing: 8) {
        safetyIndicator(
          icon: "clock",
          title: "Duration",
          value: formatDuration(from: migration.createdAt),
          status: durationStatus(from: migration.createdAt)
        )
        
        safetyIndicator(
          icon: "network",
          title: "Connection",
          value: "Stable",
          status: .safe
        )
        
        safetyIndicator(
          icon: "internaldrive",
          title: "Data Transferred",
          value: ByteCountFormatter().string(fromByteCount: Int64(migration.exportedDataSize)),
          status: .safe
        )
        
        if migration.status == .failed {
          safetyIndicator(
            icon: "exclamationmark.triangle.fill",
            title: "Status",
            value: "Migration Failed",
            status: .critical
          )
        }
      }
      .padding()
      .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
  }
  
  // MARK: - Emergency Controls
  
  private func emergencyControlsSection(migration: MigrationOperation) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("🚨 Emergency Controls")
        .font(.headline)
        .fontWeight(.medium)
        .foregroundStyle(.red)
      
      VStack(spacing: 8) {
        Button {
          showEmergencyStop = true
        } label: {
          HStack {
            Image(systemName: "stop.circle.fill")
            Text("Emergency Stop Migration")
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.red)
        .disabled(!canEmergencyStop(migration.status))
        
        Text("⚠️ Use only if migration appears stuck or if critical issues occur. This may leave your account in an incomplete state.")
          .font(.caption)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
      }
      .padding()
      .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(.red.opacity(0.3), lineWidth: 1)
      )
    }
  }
  
  // MARK: - Technical Details Section
  
  private func technicalDetailsSection(migration: MigrationOperation) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Technical Details")
        .font(.headline)
        .fontWeight(.medium)
      
      VStack(alignment: .leading, spacing: 8) {
        technicalDetail(label: "Migration ID", value: migration.id.uuidString.prefix(8) + "...")
        technicalDetail(label: "Started", value: formatTimestamp(migration.createdAt))
        
        if let backupId = migration.preMigrationBackupId {
          technicalDetail(label: "Backup ID", value: String(backupId.uuidString.prefix(8)) + "...")
        }
        
        if migration.exportedDataSize > 0 {
          technicalDetail(label: "Data Size", value: ByteCountFormatter().string(fromByteCount: Int64(migration.exportedDataSize)))
        }
        
        if let destinationDID = migration.destinationDID {
          technicalDetail(label: "Destination DID", value: String(destinationDID.prefix(20)) + "...")
        }
      }
      .padding()
      .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
  }
  
  // MARK: - Helper Views
  
  private func statusBadge(status: MigrationStatus) -> some View {
    Label(status.description, systemImage: status.systemImage)
      .font(.caption)
      .fontWeight(.medium)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(colorFromString(status.color).opacity(0.2))
      .foregroundStyle(colorFromString(status.color))
      .clipShape(Capsule())
  }
  
    @ViewBuilder
  private func timelineStep(
    phase: MigrationStatus,
    title: String,
    description: String,
    current: MigrationStatus,
    startTime: Date
  ) -> some View {
    
    let stepStatus = getStepStatus(phase: phase, current: current)
    
    HStack(alignment: .top, spacing: 12) {
      VStack(spacing: 4) {
        Circle()
          .fill(stepColor(status: stepStatus))
          .frame(width: 12, height: 12)
          .overlay(
            Circle()
              .stroke(stepColor(status: stepStatus), lineWidth: 2)
              .frame(width: 16, height: 16)
          )
        
        if phase != .completed {
          Rectangle()
            .fill(stepColor(status: stepStatus).opacity(0.3))
            .frame(width: 2, height: 20)
        }
      }
      
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(title)
            .font(.callout)
            .fontWeight(.medium)
            .foregroundStyle(stepStatus == .completed ? .primary : .secondary)
          
          if stepStatus == .active {
            ProgressView()
              .scaleEffect(0.6)
          } else if stepStatus == .completed {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.green)
              .font(.caption)
          }
        }
        
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      
      Spacer()
    }
  }
  
  private func safetyIndicator(
    icon: String,
    title: String,
    value: String,
    status: SafetyLevel
  ) -> some View {
    HStack {
      Image(systemName: icon)
        .foregroundStyle(colorForSafetyLevel(status))
        .frame(width: 20)
      
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
        
        Text(value)
          .font(.callout)
          .fontWeight(.medium)
      }
      
      Spacer()
      
      Circle()
        .fill(colorForSafetyLevel(status))
        .frame(width: 8, height: 8)
    }
  }
  
  private func technicalDetail(label: String, value: String) -> some View {
    HStack {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 100, alignment: .leading)
      
      Text(value)
        .font(.caption)
        .fontWeight(.medium)
        .foregroundStyle(.primary)
      
      Spacer()
    }
  }
  
  // MARK: - Helper Functions
  
  private func progressColor(for status: MigrationStatus) -> Color {
    switch status {
    case .failed:
      return .red
    case .cancelled:
      return .orange
    case .completed:
      return .green
    default:
      return .blue
    }
  }
  
  private func phaseDescription(for status: MigrationStatus) -> String {
    switch status {
    case .preparing:
      return "Setting up migration environment and validating prerequisites"
    case .preparingBackup:
      return "Creating mandatory backup of your current account data"
    case .authenticating:
      return "Establishing secure connections to both servers"
    case .validating:
      return "Checking server compatibility and migration feasibility"
    case .exporting:
      return "Downloading your repository data from the source server"
    case .importing:
      return "Uploading and importing your data to the destination server"
    case .verifying:
      return "Verifying data integrity and migration completeness"
    case .completed:
      return "Migration completed successfully"
    case .failed:
      return "Migration encountered an error and was stopped"
    case .cancelled:
      return "Migration was cancelled by user request"
    }
  }
  
  private func isActivePhase(_ status: MigrationStatus) -> Bool {
    switch status {
    case .preparing, .preparingBackup, .authenticating, .validating, .exporting, .importing, .verifying:
      return true
    case .completed, .failed, .cancelled:
      return false
    }
  }
  
  private enum StepStatus {
    case pending, active, completed, failed
  }
  
  private func getStepStatus(phase: MigrationStatus, current: MigrationStatus) -> StepStatus {
    let phaseOrder: [MigrationStatus] = [
      .preparing, .preparingBackup, .authenticating, .validating,
      .exporting, .importing, .verifying, .completed
    ]
    
    guard let currentIndex = phaseOrder.firstIndex(of: current),
          let phaseIndex = phaseOrder.firstIndex(of: phase) else {
      return .pending
    }
    
    if current == .failed || current == .cancelled {
      return phaseIndex <= currentIndex ? .failed : .pending
    }
    
    if phaseIndex < currentIndex {
      return .completed
    } else if phaseIndex == currentIndex {
      return .active
    } else {
      return .pending
    }
  }
  
  private func stepColor(status: StepStatus) -> Color {
    switch status {
    case .pending: return .secondary
    case .active: return .blue
    case .completed: return .green
    case .failed: return .red
    }
  }
  
  private func formatDuration(from startTime: Date) -> String {
    let duration = Date().timeIntervalSince(startTime)
    let minutes = Int(duration) / 60
    let seconds = Int(duration) % 60
    return String(format: "%d:%02d", minutes, seconds)
  }
  
  private func durationStatus(from startTime: Date) -> SafetyLevel {
    let duration = Date().timeIntervalSince(startTime)
    if duration > 1800 { // 30 minutes
      return .high
    } else if duration > 900 { // 15 minutes
      return .medium
    } else {
      return .safe
    }
  }
  
  private func colorForSafetyLevel(_ level: SafetyLevel) -> Color {
    switch level {
    case .safe: return .green
    case .low: return .blue
    case .medium: return .yellow
    case .high: return .orange
    case .critical: return .red
    }
  }
  
  private func canEmergencyStop(_ status: MigrationStatus) -> Bool {
    switch status {
    case .preparing, .preparingBackup, .authenticating, .validating, .exporting, .importing, .verifying:
      return true
    case .completed, .failed, .cancelled:
      return false
    }
  }
  
  private func formatTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .medium
    return formatter.string(from: date)
  }
  
  private func colorFromString(_ colorName: String) -> Color {
    switch colorName {
    case "blue": return .blue
    case "green": return .green
    case "red": return .red
    case "orange": return .orange
    case "yellow": return .yellow
    default: return .primary
    }
  }
  
  // MARK: - Safety Monitoring
  
  private func startSafetyMonitoring(migration: MigrationOperation) async {
    let safetyService = MigrationSafetyService()
    alertMonitor = await safetyService.monitorMigrationSafety(migration: migration)
    alertMonitor?.startMonitoring()
  }
}

// MARK: - Migration Logs View

struct MigrationLogsView: View {
  @Environment(\.dismiss) private var dismiss
  let logs: [MigrationLogEntry]
  
  var body: some View {
    NavigationView {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(logs) { log in
            logEntryView(log)
          }
          
          if logs.isEmpty {
            Text("No detailed logs available yet")
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .center)
              .padding()
          }
        }
        .padding()
      }
      .navigationTitle("Migration Logs")
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
  
  private func logEntryView(_ log: MigrationLogEntry) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(log.timestamp.formatted(date: .omitted, time: .complete))
          .font(.caption)
          .foregroundStyle(.secondary)
        
        Spacer()
        
        Text(log.level.rawValue.uppercased())
          .font(.caption2)
          .fontWeight(.bold)
          .padding(.horizontal, 4)
          .padding(.vertical, 2)
          .background(log.level.color.opacity(0.2))
          .foregroundStyle(log.level.color)
          .clipShape(Capsule())
      }
      
      Text(log.message)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 12)
    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
  }
}

// MARK: - Migration Log Entry

struct MigrationLogEntry: Identifiable {
  let id = UUID()
  let timestamp: Date
  let level: LogLevel
  let message: String
  
  enum LogLevel: String {
    case debug = "debug"
    case info = "info"
    case warning = "warning"
    case error = "error"
    
    var color: Color {
      switch self {
      case .debug: return .secondary
      case .info: return .blue
      case .warning: return .orange
      case .error: return .red
      }
    }
  }
}
