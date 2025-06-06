import SwiftUI
import OSLog
import Petrel

/// ⚠️ EXPERIMENTAL: Multi-step wizard for account migration
/// This is bleeding-edge functionality with significant risks
struct MigrationWizardView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(AppState.self) private var appState
  
  @State private var currentStep: MigrationStep = .warning
  @State private var migrationService = AccountMigrationService()
  @State private var isLoading = false
  @State private var error: Error?
  @State private var showError = false
  
  // Wizard state
  @State private var hasAcknowledgedRisks = false
  @State private var selectedDestinationServer: ServerConfiguration?
  @State private var migrationOptions = MigrationOptions.default
  @State private var safetyReport: SafetyReport?
  @State private var compatibilityReport: CompatibilityReport?
  @State private var currentMigration: MigrationOperation?
  
  private let logger = Logger(subsystem: "blue.catbird", category: "MigrationWizard")
  
  var body: some View {
    NavigationView {
      ZStack {
        switch currentStep {
        case .warning:
          warningStep
        case .serverSelection:
          serverSelectionStep
        case .options:
          optionsStep
        case .safety:
          safetyStep
        case .confirmation:
          confirmationStep
        case .migration:
          migrationStep
        case .completion:
          completionStep
        }
        
        if isLoading {
          loadingOverlay
        }
      }
      .navigationTitle("Account Migration")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Cancel") {
            if let migration = currentMigration {
              Task {
                try? await migrationService.cancelMigration()
              }
            }
            dismiss()
          }
        }
        
        if currentStep != .warning && currentStep != .migration && currentStep != .completion {
          ToolbarItem(placement: .navigationBarTrailing) {
            Button("Next") {
              Task {
                await proceedToNextStep()
              }
            }
            .disabled(!canProceedToNext)
          }
        }
      }
      .alert("Migration Error", isPresented: $showError) {
        Button("OK") { }
      } message: {
        Text(error?.localizedDescription ?? "An unknown error occurred")
      }
    }
    .onAppear {
      migrationService.updateSourceClient(appState.atProtoClient)
    }
  }
  
  // MARK: - Warning Step
  
  private var warningStep: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        
        // Header with warning icon
        HStack {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.largeTitle)
            .foregroundStyle(.orange)
          
          VStack(alignment: .leading, spacing: 4) {
            Text("⚠️ EXPERIMENTAL FEATURE")
              .font(.headline)
              .fontWeight(.bold)
              .foregroundStyle(.orange)
            
            Text("Account Migration")
              .font(.title2)
              .fontWeight(.semibold)
          }
        }
        
        // Risk warnings
        VStack(alignment: .leading, spacing: 16) {
          Text("🚨 CRITICAL WARNINGS")
            .font(.headline)
            .fontWeight(.bold)
            .foregroundStyle(.red)
          
          VStack(alignment: .leading, spacing: 12) {
            riskWarning(
              icon: "xmark.circle.fill",
              title: "Potential Data Loss",
              description: "Migration may fail catastrophically, resulting in complete data loss. Always create backups first.",
              severity: .critical
            )
            
            riskWarning(
              icon: "clock.arrow.circlepath",
              title: "Interruption Risks",
              description: "If migration is interrupted, your account may be left in an unusable state requiring manual recovery.",
              severity: .high
            )
            
            riskWarning(
              icon: "server.rack",
              title: "Server Compatibility",
              description: "Different AT Protocol servers may have incompatible features, causing migration failures.",
              severity: .medium
            )
            
            riskWarning(
              icon: "arrow.triangle.2.circlepath",
              title: "Duplicate Content",
              description: "Repeated migrations may result in duplicate posts and connections.",
              severity: .medium
            )
          }
        }
        
        // What this does
        VStack(alignment: .leading, spacing: 12) {
          Text("What Account Migration Does")
            .font(.headline)
            .fontWeight(.semibold)
          
          VStack(alignment: .leading, spacing: 8) {
            migrationStep(
              number: 1,
              description: "Creates mandatory backup of your current account"
            )
            migrationStep(
              number: 2,
              description: "Exports your repository as a CAR file from source server"
            )
            migrationStep(
              number: 3,
              description: "Authenticates with destination server"
            )
            migrationStep(
              number: 4,
              description: "Imports your data to the new server"
            )
            migrationStep(
              number: 5,
              description: "Verifies migration integrity and completeness"
            )
          }
        }
        
        // Legal disclaimers
        VStack(alignment: .leading, spacing: 8) {
          Text("⚖️ Legal Disclaimers")
            .font(.headline)
            .fontWeight(.semibold)
          
          Text("• This feature is experimental and unsupported\n• Use at your own risk - no warranties provided\n• Catbird is not responsible for data loss or migration failures\n• Some servers may not support all migration features\n• Migration may violate terms of service of some servers")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        
        // Acknowledgment
        VStack(spacing: 12) {
          Toggle(isOn: $hasAcknowledgedRisks) {
            VStack(alignment: .leading, spacing: 4) {
              Text("I understand the risks")
                .fontWeight(.medium)
              Text("I acknowledge this is experimental functionality with significant risks including potential data loss")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .toggleStyle(SwitchToggleStyle())
          
          Button {
            currentStep = .serverSelection
          } label: {
            HStack {
              Image(systemName: "arrow.right")
              Text("Continue with Migration")
            }
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .disabled(!hasAcknowledgedRisks)
        }
      }
      .padding()
    }
  }
  
  // MARK: - Server Selection Step
  
  private var serverSelectionStep: some View {
    ServerSelectionView(
      selectedServer: $selectedDestinationServer,
      onServerSelected: { server in
        selectedDestinationServer = server
      }
    )
  }
  
  // MARK: - Options Step
  
  private var optionsStep: some View {
    MigrationOptionsView(
      options: $migrationOptions,
      estimatedDataSize: .constant(0)
    )
  }
  
  // MARK: - Safety Step
  
  private var safetyStep: some View {
    MigrationSafetyView(
      safetyReport: safetyReport,
      compatibilityReport: compatibilityReport,
      isLoading: isLoading
    )
  }
  
  // MARK: - Confirmation Step
  
  private var confirmationStep: some View {
    MigrationConfirmationView(
      destinationServer: selectedDestinationServer,
      options: migrationOptions,
      safetyReport: safetyReport,
      compatibilityReport: compatibilityReport,
      onConfirm: {
        Task {
          await startMigration()
        }
      }
    )
  }
  
  // MARK: - Migration Step
  
  private var migrationStep: some View {
    MigrationProgressView(
      migration: currentMigration,
      migrationService: migrationService
    )
  }
  
  // MARK: - Completion Step
  
  private var completionStep: some View {
    MigrationCompletionView(
      migration: currentMigration,
      onDismiss: {
        dismiss()
      }
    )
  }
  
  // MARK: - Helper Views
  
  private func riskWarning(icon: String, title: String, description: String, severity: SafetyLevel) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .foregroundStyle(colorForSeverity(severity))
        .font(.title3)
      
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .fontWeight(.semibold)
          .foregroundStyle(colorForSeverity(severity))
        
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }
  
  private func migrationStep(number: Int, description: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text("\(number)")
        .font(.caption)
        .fontWeight(.bold)
        .foregroundStyle(.white)
        .frame(width: 20, height: 20)
        .background(Circle().fill(.blue))
      
      Text(description)
        .font(.callout)
        .foregroundStyle(.primary)
    }
  }
  
  private var loadingOverlay: some View {
    Color.black.opacity(0.3)
      .ignoresSafeArea()
      .overlay {
        VStack(spacing: 16) {
          ProgressView()
            .scaleEffect(1.5)
          
          Text("Processing...")
            .font(.headline)
            .foregroundStyle(.white)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
      }
  }
  
  // MARK: - Computed Properties
  
  private var canProceedToNext: Bool {
    switch currentStep {
    case .warning:
      return hasAcknowledgedRisks
    case .serverSelection:
      return selectedDestinationServer != nil
    case .options:
      return true
    case .safety:
      return safetyReport?.canProceed == true
    case .confirmation:
      return true
    case .migration, .completion:
      return false
    }
  }
  
  // MARK: - Helper Functions
  
  private func colorForSeverity(_ severity: SafetyLevel) -> Color {
    switch severity {
    case .safe: return .green
    case .low: return .blue
    case .medium: return .yellow
    case .high: return .orange
    case .critical: return .red
    }
  }
  
  // MARK: - Navigation Logic
  
  private func proceedToNextStep() async {
    isLoading = true
    defer { isLoading = false }
    
    do {
      switch currentStep {
      case .warning:
        currentStep = .serverSelection
        
      case .serverSelection:
        currentStep = .options
        
      case .options:
        // Perform compatibility and safety checks
        await performSafetyAndCompatibilityChecks()
        currentStep = .safety
        
      case .safety:
        currentStep = .confirmation
        
      case .confirmation:
        // This is handled by the confirmation view's onConfirm
        break
        
      case .migration, .completion:
        break
      }
    } catch {
      self.error = error
      showError = true
    }
  }
  
  private func performSafetyAndCompatibilityChecks() async {
    guard let destinationServer = selectedDestinationServer,
          let sourceClient = appState.atProtoClient else {
      return
    }
    
    do {
      // Mock destination client for compatibility check
      let destinationOAuthConfig = OAuthConfiguration(
        clientId: "https://catbird.blue/oauth/client-metadata.json",
        redirectUri: "https://catbird.blue/oauth/callback",
        scope: "atproto transition:generic"
      )
      
      let destinationClient = await ATProtoClient(
        oauthConfig: destinationOAuthConfig,
        namespace: "blue.catbird.migration",
        userAgent: "Catbird-Migration/1.0"
      )
      
      // Perform compatibility check
      let validator = MigrationValidator()
      compatibilityReport = try await validator.validateServerCompatibility(
        source: sourceClient,
        destination: destinationClient
      )
      
      // Perform safety check
      let safetyService = MigrationSafetyService()
      let mockMigration = MigrationOperation(
        sourceServer: ServerConfiguration.bskyOfficial,
        destinationServer: destinationServer,
        options: migrationOptions
      )
      
      if let compatibility = compatibilityReport {
        safetyReport = try await safetyService.performPreMigrationSafetyCheck(
          migration: mockMigration,
          compatibilityReport: compatibility
        )
      }
      
    } catch {
      self.error = error
      showError = true
    }
  }
  
  private func startMigration() async {
    guard let destinationServer = selectedDestinationServer else {
      return
    }
    
    isLoading = true
    currentStep = .migration
    
    do {
      let migration = try await migrationService.startMigration(
        sourceConfig: ServerConfiguration.bskyOfficial,
        destinationConfig: destinationServer,
        options: migrationOptions,
        backupManager: appState.backupManager
      )
      
      currentMigration = migration
      currentStep = .completion
      
    } catch {
      self.error = error
      showError = true
      currentStep = .confirmation // Return to confirmation on error
    }
    
    isLoading = false
  }
}

// MARK: - Migration Steps Enum

enum MigrationStep: CaseIterable {
  case warning
  case serverSelection
  case options
  case safety
  case confirmation
  case migration
  case completion
  
  var title: String {
    switch self {
    case .warning: return "⚠️ Warnings"
    case .serverSelection: return "Select Server"
    case .options: return "Migration Options"
    case .safety: return "Safety Check"
    case .confirmation: return "Confirmation"
    case .migration: return "Migrating"
    case .completion: return "Complete"
    }
  }
  
  var stepNumber: Int {
    switch self {
    case .warning: return 1
    case .serverSelection: return 2
    case .options: return 3
    case .safety: return 4
    case .confirmation: return 5
    case .migration: return 6
    case .completion: return 7
    }
  }
}
