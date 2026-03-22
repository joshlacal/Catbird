import SwiftUI
import SwiftData

struct DataBackupSettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.modelContext) private var modelContext
  @State private var backupRecords: [BackupRecord] = []
  @State private var config: BackupConfiguration?
  @State private var isBackingUp = false
  @State private var backupProgress: Double = 0
  @State private var showingRepositoryBrowser = false
  @State private var errorMessage: String?
  @State private var showError = false

  var body: some View {
    List {
      latestBackupSection
      backupActionSection
      automaticBackupsSection
      backupHistorySection
      dataExplorerSection
    }
    .navigationTitle("Data & Backup")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .alert("Backup Error", isPresented: $showError) {
      Button("OK") {
        errorMessage = nil
      }
    } message: {
      Text(errorMessage ?? "An unknown error occurred.")
    }
    .sheet(isPresented: $showingRepositoryBrowser) {
      RepositoryBrowserView()
    }
    .onAppear {
      loadData()
    }
  }

  // MARK: - Latest Backup

  @ViewBuilder
  private var latestBackupSection: some View {
    if let latest = backupRecords.first {
      Section("Latest Backup") {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Image(systemName: latest.status.systemImage)
              .foregroundStyle(Color(latest.status.color))
            Text(latest.status.displayName)
              .font(.headline)

            Spacer()

            Text(latest.ageDescription)
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          HStack {
            Label(latest.formattedFileSize, systemImage: "doc.fill")
              .font(.subheadline)
              .foregroundStyle(.secondary)

            Spacer()

            if latest.isIntegrityValid {
              Label("Verified", systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
            }
          }

          if latest.status == .completed || latest.status == .verified {
            Button("Verify Integrity") {
              verifyBackup(latest)
            }
            .font(.subheadline)
          }
        }
        .padding(.vertical, 4)
      }
    }
  }

  // MARK: - Backup Action

  private var backupActionSection: some View {
    Section("Backup") {
      if isBackingUp {
        VStack(spacing: 8) {
          ProgressView(value: backupProgress)
          Text("Backing up...")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
      } else {
        Button("Back Up Now") {
          startBackup()
        }
      }
    }
  }

  // MARK: - Automatic Backups

  @ViewBuilder
  private var automaticBackupsSection: some View {
    if let config = config {
      Section("Automatic Backups") {
        Toggle("Enable Automatic Backups", isOn: Binding(
          get: { config.autoBackupEnabled },
          set: { newValue in
            config.autoBackupEnabled = newValue
            saveConfig()
          }
        ))

        if config.autoBackupEnabled {
          Picker("Frequency", selection: Binding(
            get: { config.backupFrequencyHours },
            set: { newValue in
              config.backupFrequencyHours = newValue
              saveConfig()
            }
          )) {
            Text("Daily").tag(24)
            Text("Weekly").tag(168)
            Text("Monthly").tag(720)
          }

          Stepper(
            "Max Backups: \(config.maxBackupsToKeep)",
            value: Binding(
              get: { config.maxBackupsToKeep },
              set: { newValue in
                config.maxBackupsToKeep = newValue
                saveConfig()
              }
            ),
            in: 1...20
          )
        }
      }
    }
  }

  // MARK: - Backup History

  private var backupHistorySection: some View {
    Section("Backup History") {
      if backupRecords.isEmpty {
        Text("No backups yet")
          .foregroundStyle(.secondary)
      } else {
        ForEach(backupRecords, id: \.id) { record in
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              HStack(spacing: 6) {
                Image(systemName: record.status.systemImage)
                  .foregroundStyle(Color(record.status.color))
                  .font(.caption)
                Text(record.status.displayName)
                  .font(.subheadline)
              }

              Text(record.createdDate, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text(record.formattedFileSize)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 2)
        }
        .onDelete { indexSet in
          deleteBackups(at: indexSet)
        }
      }
    }
  }

  // MARK: - Data Explorer

  private var dataExplorerSection: some View {
    Section("Data Explorer") {
      Button("Browse Repository Data") {
        showingRepositoryBrowser = true
      }
    }
  }

  // MARK: - Data Loading

  private func loadData() {
    Task {
      do {
        let backupActor = BackupModelActor(modelContainer: modelContext.container)
        let records = try await backupActor.fetchAllBackupRecords()
        await MainActor.run {
          backupRecords = records.sorted { $0.createdDate > $1.createdDate }
        }
      } catch {
        await MainActor.run {
          errorMessage = "Failed to load backups: \(error.localizedDescription)"
          showError = true
        }
      }
    }

    loadConfig()
  }

  private func loadConfig() {
    let userDID = appState.userDID
    let descriptor = FetchDescriptor<BackupConfiguration>(
      predicate: #Predicate { $0.userDID == userDID }
    )

    do {
      let configs = try modelContext.fetch(descriptor)
      if let existing = configs.first {
        config = existing
      } else {
        let newConfig = BackupConfiguration(userDID: userDID)
        modelContext.insert(newConfig)
        try modelContext.save()
        config = newConfig
      }
    } catch {
      errorMessage = "Failed to load backup settings: \(error.localizedDescription)"
      showError = true
    }
  }

  private func saveConfig() {
    do {
      try modelContext.save()
    } catch {
      errorMessage = "Failed to save settings: \(error.localizedDescription)"
      showError = true
    }
  }

  // MARK: - Actions

  private func startBackup() {
    guard let backupManager = appState.backupManager else {
      errorMessage = "Backup manager not available"
      showError = true
      return
    }

    isBackingUp = true
    backupProgress = 0

    Task {
      do {
        let handle = appState.currentUserProfile?.handle.value ?? appState.userDID
        let record = try await backupManager.createManualBackup(userHandle: handle)
        await MainActor.run {
          isBackingUp = false
          backupProgress = 0
          loadData()
        }
      } catch {
        await MainActor.run {
          isBackingUp = false
          backupProgress = 0
          errorMessage = "Backup failed: \(error.localizedDescription)"
          showError = true
        }
      }
    }
  }

  private func verifyBackup(_ record: BackupRecord) {
    guard let backupManager = appState.backupManager else { return }

    Task {
      do {
        try await backupManager.verifyBackupIntegrity(record)
        await MainActor.run {
          loadData()
        }
      } catch {
        await MainActor.run {
          errorMessage = "Verification failed: \(error.localizedDescription)"
          showError = true
        }
      }
    }
  }

  private func deleteBackups(at offsets: IndexSet) {
    guard let backupManager = appState.backupManager else {
      errorMessage = "Backup manager not available"
      showError = true
      return
    }

    let recordsToDelete = offsets.map { backupRecords[$0] }

    Task {
      do {
        for record in recordsToDelete {
          try await backupManager.deleteBackup(record)
        }
        await MainActor.run {
          backupRecords.remove(atOffsets: offsets)
        }
      } catch {
        await MainActor.run {
          errorMessage = "Failed to delete backup: \(error.localizedDescription)"
          showError = true
        }
      }
    }
  }
}

#Preview {
  AsyncPreviewContent { appState in
    NavigationStack {
      DataBackupSettingsView()
    }
  }
}
