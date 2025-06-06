import SwiftUI

/// View for configuring migration options and data selection
struct MigrationOptionsView: View {
  @Binding var options: MigrationOptions
  @Binding var estimatedDataSize: Int
  
  @State private var showAdvancedOptions = false
  
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        
        // Header
        VStack(alignment: .leading, spacing: 8) {
          Text("Migration Options")
            .font(.title2)
            .fontWeight(.semibold)
          
          Text("Choose what data to migrate and how the migration should be performed. More data means longer migration time.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        
        // Quick presets
        presetSection
        
        // Data selection
        dataSelectionSection
        
        // Advanced options (collapsible)
        advancedOptionsSection
        
        // Safety options
        safetyOptionsSection
        
        // Estimated impact
        estimatedImpactSection
      }
      .padding()
    }
  }
  
  // MARK: - Preset Section
  
  private var presetSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Quick Presets")
        .font(.headline)
        .fontWeight(.medium)
      
      HStack(spacing: 12) {
        presetButton(
          title: "Complete",
          description: "All data",
          preset: .default,
          icon: "square.grid.3x3.fill"
        )
        
        presetButton(
          title: "Essential",
          description: "Posts & follows",
          preset: essentialPreset,
          icon: "star.fill"
        )
        
        presetButton(
          title: "Minimal",
          description: "Profile only",
          preset: .minimal,
          icon: "person.fill"
        )
      }
    }
  }
  
  private func presetButton(
    title: String,
    description: String,
    preset: MigrationOptions,
    icon: String
  ) -> some View {
    Button {
      options = preset
    } label: {
      VStack(spacing: 8) {
        Image(systemName: icon)
          .font(.title2)
          .foregroundStyle(.blue)
        
        VStack(spacing: 2) {
          Text(title)
            .font(.callout)
            .fontWeight(.medium)
            .foregroundStyle(.primary)
          
          Text(description)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 12)
      .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(PlainButtonStyle())
  }
  
  // MARK: - Data Selection Section
  
  private var dataSelectionSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Data to Migrate")
        .font(.headline)
        .fontWeight(.medium)
      
      VStack(spacing: 8) {
        dataToggle(
          isOn: $options.includeProfile,
          title: "Profile Information",
          description: "Display name, bio, avatar, banner",
          icon: "person.circle.fill",
          recommended: true
        )
        
        dataToggle(
          isOn: $options.includePosts,
          title: "Posts & Replies",
          description: "All your posts and replies",
          icon: "text.bubble.fill",
          recommended: true
        )
        
        dataToggle(
          isOn: $options.includeMedia,
          title: "Media Files",
          description: "Images and videos in posts",
          icon: "photo.fill",
          sizeImpact: "High"
        )
        
        dataToggle(
          isOn: $options.includeFollows,
          title: "Following List",
          description: "Accounts you follow",
          icon: "person.badge.plus.fill",
          recommended: true
        )
        
        dataToggle(
          isOn: $options.includeLikes,
          title: "Liked Posts",
          description: "Posts you've liked",
          icon: "heart.fill"
        )
        
        dataToggle(
          isOn: $options.includeReposts,
          title: "Reposts",
          description: "Posts you've reposted",
          icon: "arrow.2.squarepath"
        )
        
        dataToggle(
          isOn: $options.includeBlocks,
          title: "Blocked Accounts",
          description: "Accounts you've blocked",
          icon: "hand.raised.fill"
        )
        
        dataToggle(
          isOn: $options.includeMutes,
          title: "Muted Accounts",
          description: "Accounts you've muted",
          icon: "speaker.slash.fill"
        )
      }
      
      // Note about followers
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Image(systemName: "info.circle.fill")
            .foregroundStyle(.blue)
          
          Text("Note about followers")
            .font(.callout)
            .fontWeight(.medium)
        }
        
        Text("Followers cannot be migrated automatically. They will need to discover and follow your new account. Consider announcing your migration to help followers find you.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding()
      .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
  }
  
  // MARK: - Advanced Options Section
  
  private var advancedOptionsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button {
        withAnimation {
          showAdvancedOptions.toggle()
        }
      } label: {
        HStack {
          Text("Advanced Options")
            .font(.headline)
            .fontWeight(.medium)
            .foregroundStyle(.primary)
          
          Spacer()
          
          Image(systemName: showAdvancedOptions ? "chevron.up" : "chevron.down")
            .foregroundStyle(.secondary)
        }
      }
      .buttonStyle(PlainButtonStyle())
      
      if showAdvancedOptions {
        VStack(spacing: 12) {
          advancedToggle(
            isOn: $options.preserveTimestamps,
            title: "Preserve Timestamps",
            description: "Keep original post dates (may not work on all servers)"
          )
          
          advancedToggle(
            isOn: $options.skipDuplicates,
            title: "Skip Duplicates",
            description: "Avoid importing duplicate content if found"
          )
          
          // Batch size picker
          VStack(alignment: .leading, spacing: 8) {
            Text("Batch Size")
              .font(.callout)
              .fontWeight(.medium)
            
            Picker("Batch Size", selection: Binding(
              get: { options.batchSize },
              set: { newValue in
                options = MigrationOptions(
                  includeFollows: options.includeFollows,
                  includeFollowers: options.includeFollowers,
                  includePosts: options.includePosts,
                  includeMedia: options.includeMedia,
                  includeLikes: options.includeLikes,
                  includeReposts: options.includeReposts,
                  includeBlocks: options.includeBlocks,
                  includeMutes: options.includeMutes,
                  includeProfile: options.includeProfile,
                  destinationHandle: options.destinationHandle,
                  preserveTimestamps: options.preserveTimestamps,
                  batchSize: newValue,
                  skipDuplicates: options.skipDuplicates,
                  createBackupBeforeMigration: options.createBackupBeforeMigration,
                  verifyAfterMigration: options.verifyAfterMigration,
                  enableRollbackOnFailure: options.enableRollbackOnFailure
                )
              }
            )) {
              Text("Small (50)").tag(50)
              Text("Medium (100)").tag(100)
              Text("Large (200)").tag(200)
            }
            .pickerStyle(SegmentedPickerStyle())
            
            Text("Smaller batches are safer but slower")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding()
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
      }
    }
  }
  
  // MARK: - Safety Options Section
  
  private var safetyOptionsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("🛡️ Safety Options")
        .font(.headline)
        .fontWeight(.medium)
      
      VStack(spacing: 8) {
        safetyToggle(
          isOn: $options.createBackupBeforeMigration,
          title: "Create Backup Before Migration",
          description: "Mandatory backup of your current account",
          required: true
        )
        
        safetyToggle(
          isOn: $options.verifyAfterMigration,
          title: "Verify After Migration",
          description: "Check data integrity after import",
          recommended: true
        )
        
        safetyToggle(
          isOn: $options.enableRollbackOnFailure,
          title: "Enable Rollback on Failure",
          description: "Attempt to undo changes if migration fails"
        )
      }
    }
  }
  
  // MARK: - Estimated Impact Section
  
  private var estimatedImpactSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Estimated Impact")
        .font(.headline)
        .fontWeight(.medium)
      
      VStack(alignment: .leading, spacing: 8) {
        impactRow(
          icon: "clock",
          title: "Duration",
          value: estimatedDuration,
          color: .blue
        )
        
        impactRow(
          icon: "internaldrive",
          title: "Data Size",
          value: estimatedSize,
          color: .orange
        )
        
        impactRow(
          icon: "speedometer",
          title: "Complexity",
          value: complexityLevel,
          color: complexityColor
        )
      }
      .padding()
      .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
  }
  
  // MARK: - Helper Views
  
  private func dataToggle(
    isOn: Binding<Bool>,
    title: String,
    description: String,
    icon: String,
    recommended: Bool = false,
    sizeImpact: String? = nil
  ) -> some View {
    HStack {
      Image(systemName: icon)
        .foregroundStyle(.blue)
        .frame(width: 24)
      
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(title)
            .font(.callout)
            .fontWeight(.medium)
          
          if recommended {
            Text("RECOMMENDED")
              .font(.caption2)
              .fontWeight(.bold)
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(.green.opacity(0.2))
              .foregroundStyle(.green)
              .clipShape(Capsule())
          }
          
          if let impact = sizeImpact {
            Text(impact.uppercased())
              .font(.caption2)
              .fontWeight(.bold)
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(.orange.opacity(0.2))
              .foregroundStyle(.orange)
              .clipShape(Capsule())
          }
        }
        
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      
      Spacer()
      
      Toggle("", isOn: isOn)
        .labelsHidden()
    }
    .padding(.vertical, 4)
  }
  
  private func advancedToggle(
    isOn: Binding<Bool>,
    title: String,
    description: String
  ) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.callout)
          .fontWeight(.medium)
        
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      
      Spacer()
      
      Toggle("", isOn: isOn)
        .labelsHidden()
    }
  }
  
  private func safetyToggle(
    isOn: Binding<Bool>,
    title: String,
    description: String,
    required: Bool = false,
    recommended: Bool = false
  ) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(title)
            .font(.callout)
            .fontWeight(.medium)
          
          if required {
            Text("REQUIRED")
              .font(.caption2)
              .fontWeight(.bold)
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(.red.opacity(0.2))
              .foregroundStyle(.red)
              .clipShape(Capsule())
          } else if recommended {
            Text("RECOMMENDED")
              .font(.caption2)
              .fontWeight(.bold)
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(.green.opacity(0.2))
              .foregroundStyle(.green)
              .clipShape(Capsule())
          }
        }
        
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      
      Spacer()
      
      Toggle("", isOn: isOn)
        .labelsHidden()
        .disabled(required)
    }
  }
  
  private func impactRow(
    icon: String,
    title: String,
    value: String,
    color: Color
  ) -> some View {
    HStack {
      Image(systemName: icon)
        .foregroundStyle(color)
        .frame(width: 20)
      
      Text(title)
        .font(.callout)
        .fontWeight(.medium)
      
      Spacer()
      
      Text(value)
        .font(.callout)
        .fontWeight(.medium)
        .foregroundStyle(color)
    }
  }
  
  // MARK: - Computed Properties
  
  private var essentialPreset: MigrationOptions {
    MigrationOptions(
      includeFollows: true,
      includeFollowers: false,
      includePosts: true,
      includeMedia: false,
      includeLikes: false,
      includeReposts: false,
      includeBlocks: true,
      includeMutes: true,
      includeProfile: true,
      destinationHandle: nil,
      preserveTimestamps: true,
      batchSize: 100,
      skipDuplicates: true,
      createBackupBeforeMigration: true,
      verifyAfterMigration: true,
      enableRollbackOnFailure: true
    )
  }
  
  private var estimatedDuration: String {
    let baseTime = 5 // 5 minutes base
    var multiplier = 1.0
    
    if options.includePosts { multiplier += 2.0 }
    if options.includeMedia { multiplier += 3.0 }
    if options.includeLikes { multiplier += 1.0 }
    if options.includeReposts { multiplier += 0.5 }
    
    let minutes = Int(Double(baseTime) * multiplier)
    
    if minutes < 60 {
      return "\(minutes) minutes"
    } else {
      let hours = minutes / 60
      let remainingMinutes = minutes % 60
      return "\(hours)h \(remainingMinutes)m"
    }
  }
  
  private var estimatedSize: String {
    let baseSize = 1024 * 1024 // 1MB base
    var multiplier = 1.0
    
    if options.includePosts { multiplier += 5.0 }
    if options.includeMedia { multiplier += 20.0 }
    if options.includeLikes { multiplier += 2.0 }
    if options.includeReposts { multiplier += 1.0 }
    
    let bytes = Int(Double(baseSize) * multiplier)
    return ByteCountFormatter().string(fromByteCount: Int64(bytes))
  }
  
  private var complexityLevel: String {
    var score = 0
    
    if options.includeProfile { score += 1 }
    if options.includePosts { score += 3 }
    if options.includeMedia { score += 4 }
    if options.includeFollows { score += 2 }
    if options.includeLikes { score += 2 }
    if options.includeReposts { score += 1 }
    if options.includeBlocks { score += 1 }
    if options.includeMutes { score += 1 }
    
    switch score {
    case 0...3: return "Low"
    case 4...7: return "Medium"
    case 8...10: return "High"
    default: return "Very High"
    }
  }
  
  private var complexityColor: Color {
    switch complexityLevel {
    case "Low": return .green
    case "Medium": return .yellow
    case "High": return .orange
    default: return .red
    }
  }
}