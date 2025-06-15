import SwiftUI

/// View displaying safety analysis and compatibility report
struct MigrationSafetyView: View {
  let safetyReport: SafetyReport?
  let compatibilityReport: CompatibilityReport?
  let isLoading: Bool
  
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        
        // Header
        VStack(alignment: .leading, spacing: 8) {
          Text("🛡️ Safety Analysis")
            .font(.title2)
            .fontWeight(.semibold)
          
          Text("Comprehensive analysis of migration safety and server compatibility")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        
        if isLoading {
          loadingSection
        } else {
          // Overall safety assessment
          if let safety = safetyReport {
            overallSafetySection(safety)
          }
          
          // Compatibility report
          if let compatibility = compatibilityReport {
            compatibilitySection(compatibility)
          }
          
          // Risk analysis
          if let safety = safetyReport {
            riskAnalysisSection(safety)
          }
          
          // Recommendations
          if let safety = safetyReport {
            recommendationsSection(safety)
          }
          
          // Proceed decision
          proceedDecisionSection
        }
      }
      .padding()
    }
  }
  
  // MARK: - Loading Section
  
  private var loadingSection: some View {
    VStack(spacing: 16) {
      ProgressView()
        .scaleEffect(1.2)
      
      VStack(spacing: 8) {
        Text("Analyzing Migration Safety")
          .font(.headline)
          .fontWeight(.medium)
        
        Text("Checking server compatibility, validating configurations, and assessing risks...")
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
  }
  
  // MARK: - Overall Safety Section
  
  private func overallSafetySection(_ safety: SafetyReport) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Overall Safety Assessment")
        .font(.headline)
        .fontWeight(.medium)
      
      HStack {
        // Safety level indicator
        VStack(spacing: 8) {
          ZStack {
            Circle()
              .fill(colorForSafetyLevel(safety.overallLevel).opacity(0.2))
              .frame(width: 80, height: 80)
            
            VStack(spacing: 4) {
              Image(systemName: safety.overallLevel.systemImage)
                .font(.title2)
                .foregroundStyle(colorForSafetyLevel(safety.overallLevel))
              
              Text(safety.overallLevel.displayName)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(colorForSafetyLevel(safety.overallLevel))
            }
          }
          
          // Risk score
          VStack(spacing: 2) {
            Text("Risk Score")
              .font(.caption)
              .foregroundStyle(.secondary)
            
            Text("\(Int(safety.estimatedRiskScore * 100))%")
              .font(.headline)
              .fontWeight(.bold)
              .foregroundStyle(colorForSafetyLevel(safety.overallLevel))
          }
        }
        
        Spacer()
        
        // Status summary
        VStack(alignment: .leading, spacing: 8) {
          safetyStatusRow(
            icon: safety.canProceed ? "checkmark.circle.fill" : "xmark.circle.fill",
            title: "Migration Status",
            value: safety.canProceed ? "Can Proceed" : "Blocked",
            color: safety.canProceed ? .green : .red
          )
          
          safetyStatusRow(
            icon: "exclamationmark.triangle.fill",
            title: "Risk Count",
            value: "\(safety.risks.count) issues",
            color: safety.risks.isEmpty ? .green : .orange
          )
          
          safetyStatusRow(
            icon: "clock",
            title: "Analyzed",
            value: formatRelativeTime(safety.checkedAt),
            color: .blue
          )
        }
      }
      .padding()
      .background(colorForSafetyLevel(safety.overallLevel).opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .stroke(colorForSafetyLevel(safety.overallLevel).opacity(0.3), lineWidth: 2)
      )
    }
  }
  
  // MARK: - Compatibility Section
  
  private func compatibilitySection(_ compatibility: CompatibilityReport) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Server Compatibility")
        .font(.headline)
        .fontWeight(.medium)
      
      VStack(alignment: .leading, spacing: 8) {
        // Version compatibility
        HStack {
          Image(systemName: "server.rack")
            .foregroundStyle(.blue)
            .frame(width: 24)
          
          VStack(alignment: .leading, spacing: 2) {
            Text("Server Versions")
              .font(.callout)
              .fontWeight(.medium)
            
            Text("Source: \(compatibility.sourceVersion) → Destination: \(compatibility.destinationVersion)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          
          Spacer()
          
          compatibilityBadge(compatibility.canProceed)
        }
        
        // Risk level
        HStack {
          Image(systemName: compatibility.riskLevel.systemImage)
            .foregroundStyle(colorFromString(compatibility.riskLevel.color))
            .frame(width: 24)
          
          VStack(alignment: .leading, spacing: 2) {
            Text("Compatibility Risk")
              .font(.callout)
              .fontWeight(.medium)
            
            Text(compatibility.riskLevel.rawValue.capitalized)
              .font(.caption)
              .foregroundStyle(colorFromString(compatibility.riskLevel.color))
          }
          
          Spacer()
          
          Text("⏱️ ~\(formatDuration(compatibility.estimatedDuration))")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        
        // Warnings
        if !compatibility.warnings.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text("⚠️ Compatibility Warnings")
              .font(.callout)
              .fontWeight(.medium)
              .foregroundStyle(.orange)
            
            ForEach(compatibility.warnings.prefix(3), id: \.self) { warning in
              Text("• \(warning)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
            if compatibility.warnings.count > 3 {
              Text("... and \(compatibility.warnings.count - 3) more")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.top, 8)
        }
        
        // Blockers
        if !compatibility.blockers.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text("🚫 Blocking Issues")
              .font(.callout)
              .fontWeight(.medium)
              .foregroundStyle(.red)
            
            ForEach(compatibility.blockers, id: \.self) { blocker in
              Text("• \(blocker)")
                .font(.caption)
                .foregroundStyle(.red)
            }
          }
          .padding(.top, 8)
        }
      }
      .padding()
      .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
  }
  
  // MARK: - Risk Analysis Section
  
  private func riskAnalysisSection(_ safety: SafetyReport) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Risk Analysis")
        .font(.headline)
        .fontWeight(.medium)
      
      if safety.risks.isEmpty {
        HStack {
          Image(systemName: "checkmark.shield.fill")
            .foregroundStyle(.green)
            .font(.title2)
          
          VStack(alignment: .leading, spacing: 4) {
            Text("No Significant Risks Detected")
              .font(.callout)
              .fontWeight(.medium)
            
            Text("Migration can proceed with standard safety measures")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding()
        .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
      } else {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(safety.risks.indices, id: \.self) { index in
            riskItemView(safety.risks[index])
          }
        }
      }
      
      // Blockers
      if !safety.blockers.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("🚫 Critical Blockers")
            .font(.callout)
            .fontWeight(.medium)
            .foregroundStyle(.red)
          
          ForEach(safety.blockers, id: \.self) { blocker in
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
              
              Text(blocker)
                .font(.caption)
                .foregroundStyle(.red)
            }
          }
        }
        .padding()
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(.red.opacity(0.3), lineWidth: 1)
        )
      }
    }
  }
  
  // MARK: - Recommendations Section
  
  private func recommendationsSection(_ safety: SafetyReport) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Recommendations")
        .font(.headline)
        .fontWeight(.medium)
      
      if safety.recommendations.isEmpty {
        Text("No specific recommendations at this time")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(safety.recommendations, id: \.self) { recommendation in
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: "lightbulb.fill")
                .foregroundStyle(.blue)
              
              Text(recommendation)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
    }
    .padding()
    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
  }
  
  // MARK: - Proceed Decision Section
  
  private var proceedDecisionSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Migration Decision")
        .font(.headline)
        .fontWeight(.medium)
      
      if let safety = safetyReport {
        VStack(alignment: .leading, spacing: 8) {
          if safety.canProceed {
            HStack {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title2)
              
              VStack(alignment: .leading, spacing: 4) {
                Text("Migration Can Proceed")
                  .font(.callout)
                  .fontWeight(.medium)
                  .foregroundStyle(.green)
                
                Text("All safety checks passed. You can continue to the confirmation step.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          } else {
            HStack {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.title2)
              
              VStack(alignment: .leading, spacing: 4) {
                Text("Migration Blocked")
                  .font(.callout)
                  .fontWeight(.medium)
                  .foregroundStyle(.red)
                
                Text("Critical issues prevent migration. Resolve blocking issues before proceeding.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
          
          // Final warning
          VStack(alignment: .leading, spacing: 8) {
            Text("⚠️ Final Safety Reminder")
              .font(.callout)
              .fontWeight(.medium)
              .foregroundStyle(.orange)
            
            Text("• Account migration is experimental and risky\n• Always ensure you have recent backups\n• Migration may fail and leave accounts unusable\n• Follow server terms of service and rate limits\n• Consider announcing migration to followers")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding()
          .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
      }
    }
  }
  
  // MARK: - Helper Views
  
  private func safetyStatusRow(
    icon: String,
    title: String,
    value: String,
    color: Color
  ) -> some View {
    HStack {
      Image(systemName: icon)
        .foregroundStyle(color)
        .frame(width: 20)
      
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
        
        Text(value)
          .font(.callout)
          .fontWeight(.medium)
      }
    }
  }
  
  private func compatibilityBadge(_ compatible: Bool) -> some View {
    Group {
      if compatible {
        Label("Compatible", systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
      } else {
        Label("Issues", systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }
  
  private func riskItemView(_ risk: SafetyRisk) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: risk.category.systemImage)
        .foregroundStyle(colorForSafetyLevel(risk.level))
        .frame(width: 24)
      
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(risk.category.displayName)
            .font(.callout)
            .fontWeight(.medium)
          
          Spacer()
          
          Text(risk.level.displayName)
            .font(.caption2)
            .fontWeight(.bold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(colorForSafetyLevel(risk.level).opacity(0.2))
            .foregroundStyle(colorForSafetyLevel(risk.level))
            .clipShape(Capsule())
        }
        
        Text(risk.description)
          .font(.caption)
          .foregroundStyle(.primary)
        
        if !risk.mitigation.isEmpty {
          Text("💡 \(risk.mitigation)")
            .font(.caption)
            .foregroundStyle(.blue)
            .padding(.top, 2)
        }
      }
    }
    .padding()
    .background(colorForSafetyLevel(risk.level).opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(colorForSafetyLevel(risk.level).opacity(0.2), lineWidth: 1)
    )
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
  
  private func formatRelativeTime(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    return formatter.localizedString(for: date, relativeTo: Date())
  }
  
  private func formatDuration(_ duration: TimeInterval) -> String {
    let minutes = Int(duration) / 60
    if minutes < 60 {
      return "\(minutes)m"
    } else {
      let hours = minutes / 60
      let remainingMinutes = minutes % 60
      return "\(hours)h \(remainingMinutes)m"
    }
  }
}
