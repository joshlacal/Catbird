import SwiftUI

/// Final confirmation view before starting migration
struct MigrationConfirmationView: View {
  let destinationServer: ServerConfiguration?
  let options: MigrationOptions
  let safetyReport: SafetyReport?
  let compatibilityReport: CompatibilityReport?
  let onConfirm: () -> Void
  
  @State private var hasReadDisclaimer = false
  @State private var confirmationText = ""
  @State private var showFinalWarning = false
  
  private let requiredConfirmationText = "I UNDERSTAND THE RISKS"
  
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        
        // Header
        VStack(alignment: .leading, spacing: 8) {
          Text("⚠️ Final Confirmation")
            .font(.title2)
            .fontWeight(.semibold)
            .foregroundStyle(.red)
          
          Text("Review all details carefully before proceeding with this experimental migration")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        
        // Migration summary
        migrationSummarySection
        
        // Safety summary
        safetySummarySection
        
        // Final disclaimers
        finalDisclaimersSection
        
        // Confirmation controls
        confirmationControlsSection
      }
      .padding()
    }
    .alert("🚨 FINAL WARNING", isPresented: $showFinalWarning) {
      Button("Cancel", role: .cancel) { }
      Button("Proceed with Migration", role: .destructive) {
        onConfirm()
      }
    } message: {
      Text("This is your last chance to cancel. Account migration is experimental and may result in data loss or account corruption. Are you absolutely sure you want to continue?")
    }
  }
  
  // MARK: - Migration Summary Section
  
  private var migrationSummarySection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Migration Summary")
        .font(.headline)
        .fontWeight(.medium)
      
      VStack(alignment: .leading, spacing: 8) {
        // Server migration
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("bsky.social")
              .font(.callout)
              .fontWeight(.medium)
            Text("Current Server")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          
          Spacer()
          
          Image(systemName: "arrow.right")
            .foregroundStyle(.blue)
            .font(.title2)
          
          Spacer()
          
          VStack(alignment: .trailing, spacing: 4) {
            Text(destinationServer?.displayName ?? "Unknown")
              .font(.callout)
              .fontWeight(.medium)
            Text("Destination Server")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding()
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        
        // Data selection summary
        dataSummaryGrid
        
        // Options summary
        optionsSummary
      }
    }
  }
  
  // MARK: - Safety Summary Section
  
  private var safetySummarySection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("🛡️ Safety Summary")
        .font(.headline)
        .fontWeight(.medium)
      
      VStack(alignment: .leading, spacing: 8) {
        if let safety = safetyReport {
          HStack {
            Image(systemName: safety.overallLevel.systemImage)
              .foregroundStyle(colorForSafetyLevel(safety.overallLevel))
              .font(.title2)
            
            VStack(alignment: .leading, spacing: 2) {
              Text("Safety Level: \(safety.overallLevel.displayName)")
                .font(.callout)
                .fontWeight(.medium)
              
              Text("\(safety.risks.count) risks identified, \(safety.blockers.count) blockers")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if safety.canProceed {
              Label("Cleared", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
            } else {
              Label("Blocked", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
            }
          }
        }
        
        if let compatibility = compatibilityReport {
          HStack {
            Image(systemName: compatibility.riskLevel.systemImage)
              .foregroundStyle(colorFromString(compatibility.riskLevel.color))
              .font(.title2)
            
            VStack(alignment: .leading, spacing: 2) {
              Text("Compatibility: \(compatibility.riskLevel.rawValue.capitalized) Risk")
                .font(.callout)
                .fontWeight(.medium)
              
              Text("Est. duration: \(formatDuration(compatibility.estimatedDuration))")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if compatibility.canProceed {
              Label("Compatible", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
            } else {
              Label("Issues", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            }
          }
        }
      }
      .padding()
      .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
  }
  
  // MARK: - Final Disclaimers Section
  
  private var finalDisclaimersSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("🚨 CRITICAL WARNINGS")
        .font(.headline)
        .fontWeight(.bold)
        .foregroundStyle(.red)
      
      VStack(alignment: .leading, spacing: 8) {
        disclaimerItem(
          icon: "exclamationmark.triangle.fill",
          text: "This is EXPERIMENTAL functionality with no guarantees",
          severity: .critical
        )
        
        disclaimerItem(
          icon: "trash.circle.fill",
          text: "Migration may result in complete data loss",
          severity: .critical
        )
        
        disclaimerItem(
          icon: "xmark.circle.fill",
          text: "Your account may become permanently unusable",
          severity: .critical
        )
        
        disclaimerItem(
          icon: "clock.arrow.circlepath",
          text: "Interruption during migration may corrupt both accounts",
          severity: .high
        )
        
        disclaimerItem(
          icon: "person.2.slash",
          text: "Followers will NOT be migrated automatically",
          severity: .medium
        )
      }
      .padding()
      .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(.red.opacity(0.3), lineWidth: 2)
      )
      
      // Legal disclaimer
      VStack(alignment: .leading, spacing: 8) {
        Text("⚖️ Legal Disclaimer")
          .font(.callout)
          .fontWeight(.medium)
        
        Text("By proceeding, you acknowledge that:\n• This feature is experimental and unsupported\n• Catbird developers are not responsible for any data loss\n• You use this feature entirely at your own risk\n• You have read and understood all warnings\n• You have created recent backups of your data")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding()
      .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
  }
  
  // MARK: - Confirmation Controls Section
  
  private var confirmationControlsSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Confirmation Required")
        .font(.headline)
        .fontWeight(.medium)
      
      VStack(spacing: 12) {
        // Disclaimer checkbox
        Toggle(isOn: $hasReadDisclaimer) {
          VStack(alignment: .leading, spacing: 4) {
            Text("I have read and understand all warnings")
              .fontWeight(.medium)
            Text("I acknowledge this is experimental functionality with significant risks")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .toggleStyle(SwitchToggleStyle())
        
        // Confirmation text field
        VStack(alignment: .leading, spacing: 8) {
          Text("Type '\(requiredConfirmationText)' to confirm:")
            .font(.callout)
            .fontWeight(.medium)
          
          TextField("Confirmation text", text: $confirmationText)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .autocorrectionDisabled()
            .textInputAutocapitalization(.characters)
          
          if !confirmationText.isEmpty && confirmationText != requiredConfirmationText {
            Text("Text must match exactly: \(requiredConfirmationText)")
              .font(.caption)
              .foregroundStyle(.red)
          }
        }
        
        // Confirm button
        Button {
          showFinalWarning = true
        } label: {
          HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("START EXPERIMENTAL MIGRATION")
              .fontWeight(.bold)
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.red)
        .disabled(!canProceed)
        
        if !canProceed {
          VStack(spacing: 4) {
            Text("Requirements to proceed:")
              .font(.caption)
              .fontWeight(.medium)
              .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 2) {
              requirementStatus("Read disclaimers", met: hasReadDisclaimer)
              requirementStatus("Enter confirmation text", met: confirmationText == requiredConfirmationText)
              
              if let safety = safetyReport {
                requirementStatus("Pass safety checks", met: safety.canProceed)
              }
            }
          }
        }
      }
    }
  }
  
  // MARK: - Data Summary Grid
  
  private var dataSummaryGrid: some View {
    LazyVGrid(columns: [
      GridItem(.flexible()),
      GridItem(.flexible())
    ], spacing: 8) {
      dataToggleStatus("Profile", included: options.includeProfile)
      dataToggleStatus("Posts", included: options.includePosts)
      dataToggleStatus("Media", included: options.includeMedia)
      dataToggleStatus("Follows", included: options.includeFollows)
      dataToggleStatus("Likes", included: options.includeLikes)
      dataToggleStatus("Reposts", included: options.includeReposts)
      dataToggleStatus("Blocks", included: options.includeBlocks)
      dataToggleStatus("Mutes", included: options.includeMutes)
    }
    .padding()
    .background(.quaternary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
  }
  
  // MARK: - Options Summary
  
  private var optionsSummary: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Migration Options")
        .font(.callout)
        .fontWeight(.medium)
      
      HStack {
        optionsBadge("Batch: \(options.batchSize)", color: .blue)
        optionsBadge(options.preserveTimestamps ? "Preserve Dates" : "Current Dates", color: .orange)
        optionsBadge(options.skipDuplicates ? "Skip Dupes" : "Include Dupes", color: .green)
      }
      
      HStack {
        optionsBadge(options.createBackupBeforeMigration ? "Backup: Yes" : "Backup: No", color: options.createBackupBeforeMigration ? .green : .red)
        optionsBadge(options.verifyAfterMigration ? "Verify: Yes" : "Verify: No", color: options.verifyAfterMigration ? .green : .orange)
      }
    }
  }
  
  // MARK: - Helper Views
  
  private func disclaimerItem(icon: String, text: String, severity: SafetyLevel) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: icon)
        .foregroundStyle(colorForSafetyLevel(severity))
        .font(.callout)
      
      Text(text)
        .font(.callout)
        .fontWeight(.medium)
        .foregroundStyle(colorForSafetyLevel(severity))
        .fixedSize(horizontal: false, vertical: true)
    }
  }
  
  private func dataToggleStatus(_ title: String, included: Bool) -> some View {
    HStack {
      Image(systemName: included ? "checkmark.circle.fill" : "xmark.circle.fill")
        .foregroundStyle(included ? .green : .red)
        .font(.caption)
      
      Text(title)
        .font(.caption)
        .fontWeight(.medium)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
  
  private func optionsBadge(_ text: String, color: Color) -> some View {
    Text(text)
      .font(.caption2)
      .fontWeight(.medium)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(color.opacity(0.2))
      .foregroundStyle(color)
      .clipShape(Capsule())
  }
  
  private func requirementStatus(_ title: String, met: Bool) -> some View {
    HStack {
      Image(systemName: met ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(met ? .green : .secondary)
        .font(.caption)
      
      Text(title)
        .font(.caption)
        .foregroundStyle(met ? .primary : .secondary)
    }
  }
  
  // MARK: - Computed Properties
  
  private var canProceed: Bool {
    guard hasReadDisclaimer else { return false }
    guard confirmationText == requiredConfirmationText else { return false }
    guard let safety = safetyReport, safety.canProceed else { return false }
    return true
  }
  
  // MARK: - Helper Functions
  
  private func colorForSafetyLevel(_ level: SafetyLevel) -> Color {
    switch level {
    case .safe: return .green
    case .low: return .blue
    case .medium: return .yellow
    case .high: return .orange
    case .critical: return .red
    }
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
  
  private func formatDuration(_ duration: TimeInterval) -> String {
    let minutes = Int(duration) / 60
    if minutes < 60 {
      return "\(minutes) minutes"
    } else {
      let hours = minutes / 60
      let remainingMinutes = minutes % 60
      return "\(hours)h \(remainingMinutes)m"
    }
  }
}

/// Completion view shown after migration finishes
struct MigrationCompletionView: View {
  let migration: MigrationOperation?
  let onDismiss: () -> Void
  
  var body: some View {
    ScrollView {
      VStack(spacing: 24) {
        
        if let migration = migration {
          // Success or failure header
          VStack(spacing: 16) {
            statusIcon(for: migration.status)
            
            VStack(spacing: 8) {
              Text(statusTitle(for: migration.status))
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(statusColor(for: migration.status))
              
              Text(statusMessage(for: migration.status))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
          }
          
          // Migration details
          migrationDetailsSection(migration)
          
          // Next steps
          nextStepsSection(migration)
          
          // Action buttons
          actionButtonsSection(migration)
          
        } else {
          Text("No migration data available")
            .foregroundStyle(.secondary)
        }
      }
      .padding()
    }
  }
  
  private func statusIcon(for status: MigrationStatus) -> some View {
    ZStack {
      Circle()
        .fill(statusColor(for: status).opacity(0.2))
        .frame(width: 80, height: 80)
      
      Image(systemName: status.systemImage)
        .font(.system(size: 32))
        .foregroundStyle(statusColor(for: status))
    }
  }
  
  private func migrationDetailsSection(_ migration: MigrationOperation) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Migration Details")
        .font(.headline)
        .fontWeight(.medium)
      
      VStack(alignment: .leading, spacing: 8) {
        detailRow("From", value: migration.sourceServer.displayName)
        detailRow("To", value: migration.destinationServer.displayName)
        detailRow("Started", value: formatTimestamp(migration.createdAt))
        
        if let completed = migration.completedAt {
          detailRow("Completed", value: formatTimestamp(completed))
          detailRow("Duration", value: formatDuration(completed.timeIntervalSince(migration.createdAt)))
        }
        
        if migration.exportedDataSize > 0 {
          detailRow("Data Size", value: ByteCountFormatter().string(fromByteCount: Int64(migration.exportedDataSize)))
        }
        
        if let verification = migration.verificationReport {
          detailRow("Success Rate", value: "\(String(format: "%.1f", verification.successRate * 100))%")
        }
      }
      .padding()
      .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
  }
  
  private func nextStepsSection(_ migration: MigrationOperation) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Next Steps")
        .font(.headline)
        .fontWeight(.medium)
      
      VStack(alignment: .leading, spacing: 8) {
        if migration.status == .completed {
          nextStepItem(
            icon: "checkmark.circle.fill",
            title: "Verify Your Data",
            description: "Check that all your posts and follows migrated correctly",
            color: .green
          )
          
          nextStepItem(
            icon: "megaphone.fill",
            title: "Announce Migration",
            description: "Let your followers know about your new account",
            color: .blue
          )
          
          nextStepItem(
            icon: "gear",
            title: "Update Settings",
            description: "Configure your account settings on the new server",
            color: .orange
          )
          
        } else if migration.status == .failed {
          nextStepItem(
            icon: "arrow.clockwise.circle.fill",
            title: "Review Error",
            description: "Check the error message and try again if possible",
            color: .red
          )
          
          nextStepItem(
            icon: "square.and.arrow.down.fill",
            title: "Check Backup",
            description: "Ensure your backup is intact and can be restored",
            color: .blue
          )
        }
      }
    }
  }
  
  private func actionButtonsSection(_ migration: MigrationOperation) -> some View {
    VStack(spacing: 12) {
      Button {
        onDismiss()
      } label: {
        Text("Done")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      
      if migration.status == .failed {
        Button {
          // Could implement retry logic
        } label: {
          Text("Try Again")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
      }
    }
  }
  
  private func detailRow(_ label: String, value: String) -> some View {
    HStack {
      Text(label)
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(width: 80, alignment: .leading)
      
      Text(value)
        .font(.callout)
        .fontWeight(.medium)
      
      Spacer()
    }
  }
  
  private func nextStepItem(icon: String, title: String, description: String, color: Color) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .foregroundStyle(color)
        .font(.title3)
      
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.callout)
          .fontWeight(.medium)
        
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
  
  private func statusTitle(for status: MigrationStatus) -> String {
    switch status {
    case .completed: return "Migration Complete!"
    case .failed: return "Migration Failed"
    case .cancelled: return "Migration Cancelled"
    default: return "Migration Status"
    }
  }
  
  private func statusMessage(for status: MigrationStatus) -> String {
    switch status {
    case .completed: return "Your account has been successfully migrated to the new server."
    case .failed: return "The migration encountered an error and could not be completed."
    case .cancelled: return "The migration was cancelled before completion."
    default: return "Migration status unknown."
    }
  }
  
  private func statusColor(for status: MigrationStatus) -> Color {
    switch status {
    case .completed: return .green
    case .failed: return .red
    case .cancelled: return .orange
    default: return .blue
    }
  }
  
  private func formatTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }
  
  private func formatDuration(_ duration: TimeInterval) -> String {
    let minutes = Int(duration) / 60
    let seconds = Int(duration) % 60
    return "\(minutes)m \(seconds)s"
  }
}