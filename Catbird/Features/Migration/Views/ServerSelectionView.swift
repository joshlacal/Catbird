import SwiftUI
import OSLog

/// View for selecting destination AT Protocol server
struct ServerSelectionView: View {
  @Binding var selectedServer: ServerConfiguration?
  let onServerSelected: (ServerConfiguration) -> Void
  
  @State private var customServerHostname = ""
  @State private var isValidatingCustomServer = false
  @State private var customServerValidation: ServerValidationResult?
  @State private var showingCustomServerSheet = false
  
  private let logger = Logger(subsystem: "blue.catbird", category: "ServerSelection")
  
  // Predefined server options
  private let knownServers: [ServerConfiguration] = [
    ServerConfiguration.bskyOfficial,
    ServerConfiguration(
      id: UUID(),
      hostname: "staging.bsky.dev",
      displayName: "Bluesky Staging",
      description: "Development staging environment",
      version: "0.3.0",
      capabilities: ["posts", "follows", "media"],
      rateLimit: RateLimit(requestsPerMinute: 1000, dataPerHour: 1024 * 1024 * 50),
      maxAccountSize: 1024 * 1024 * 200,
      supportsMigration: true
    ),
    ServerConfiguration(
      id: UUID(),
      hostname: "bsky.network",
      displayName: "Community Instance",
      description: "Community-run AT Protocol instance",
      version: "0.2.8",
      capabilities: ["posts", "follows"],
      rateLimit: RateLimit(requestsPerMinute: 500, dataPerHour: 1024 * 1024 * 25),
      maxAccountSize: 1024 * 1024 * 100,
      supportsMigration: false
    )
  ]
  
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        
        // Header
        VStack(alignment: .leading, spacing: 8) {
          Text("Select Destination Server")
            .font(.title2)
            .fontWeight(.semibold)
          
          Text("Choose the AT Protocol server where you want to migrate your account. Each server has different capabilities and limitations.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        
        // Current server info
        VStack(alignment: .leading, spacing: 8) {
          Text("Current Server")
            .font(.headline)
            .fontWeight(.medium)
          
          ServerCardView(
            server: ServerConfiguration.bskyOfficial,
            isSelected: false,
            isCurrent: true,
            onSelect: { }
          )
        }
        
        // Available servers
        VStack(alignment: .leading, spacing: 12) {
          Text("Available Servers")
            .font(.headline)
            .fontWeight(.medium)
          
          ForEach(knownServers.filter { $0.hostname != "bsky.social" }, id: \.hostname) { server in
            ServerCardView(
              server: server,
              isSelected: selectedServer?.hostname == server.hostname,
              isCurrent: false,
              onSelect: {
                selectedServer = server
                onServerSelected(server)
              }
            )
          }
          
          // Custom server option
          customServerCard
        }
        
        // Information section
        migrationInfoSection
      }
      .padding()
    }
    .sheet(isPresented: $showingCustomServerSheet) {
      CustomServerSheet(
        hostname: $customServerHostname,
        onValidate: validateCustomServer,
        onConfirm: { server in
          selectedServer = server
          onServerSelected(server)
          showingCustomServerSheet = false
        }
      )
    }
  }
  
  // MARK: - Custom Server Card
  
  private var customServerCard: some View {
    VStack(spacing: 0) {
      Button {
        showingCustomServerSheet = true
      } label: {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Image(systemName: "plus.circle.fill")
                .foregroundStyle(.blue)
              
              Text("Add Custom Server")
                .fontWeight(.medium)
                .foregroundStyle(.primary)
            }
            
            Text("Connect to a custom AT Protocol instance")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          
          Spacer()
          
          Image(systemName: "chevron.right")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .stroke(.quaternary, lineWidth: 1)
        )
      }
      .buttonStyle(PlainButtonStyle())
    }
  }
  
  // MARK: - Migration Info Section
  
  private var migrationInfoSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Migration Information")
        .font(.headline)
        .fontWeight(.medium)
      
      VStack(alignment: .leading, spacing: 8) {
        migrationInfoItem(
          icon: "checkmark.circle.fill",
          title: "Supported Features",
          description: "Posts, follows, profile data, and media"
        )
        
        migrationInfoItem(
          icon: "xmark.circle.fill",
          title: "Not Migrated",
          description: "Followers (they must re-follow you), notifications history"
        )
        
        migrationInfoItem(
          icon: "clock.circle.fill",
          title: "Migration Time",
          description: "Typically 5-30 minutes depending on account size"
        )
        
        migrationInfoItem(
          icon: "exclamationmark.triangle.fill",
          title: "Server Compatibility",
          description: "Some features may not work if servers have different capabilities"
        )
      }
    }
    .padding()
    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
  }
  
  private func migrationInfoItem(icon: String, title: String, description: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .foregroundStyle(.blue)
        .frame(width: 20)
      
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.callout)
          .fontWeight(.medium)
        
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
  
  // MARK: - Custom Server Validation
  
  private func validateCustomServer(_ hostname: String) async -> ServerValidationResult {
    logger.info("Validating custom server: \(hostname)")
    
    guard !hostname.isEmpty else {
      return ServerValidationResult(
        isValid: false,
        error: "Hostname cannot be empty"
      )
    }
    
    // Basic hostname validation
    guard hostname.contains(".") && !hostname.contains(" ") else {
      return ServerValidationResult(
        isValid: false,
        error: "Invalid hostname format"
      )
    }
    
    // Mock server validation - would implement actual server connectivity check
    do {
      try await Task.sleep(nanoseconds: 2_000_000_000) // 2 second delay
    } catch {
      // Handle task cancellation
      return ServerValidationResult(
        isValid: false,
        error: "Validation cancelled"
      )
    }
    
    // For demo, assume server is valid but with limited capabilities
    let serverConfig = ServerConfiguration(
      id: UUID(),
      hostname: hostname,
      displayName: "Custom Server",
      description: "Custom AT Protocol instance",
      version: "0.3.0",
      capabilities: ["posts", "follows"],
      rateLimit: RateLimit(requestsPerMinute: 1000, dataPerHour: 1024 * 1024 * 50),
      maxAccountSize: 1024 * 1024 * 100,
      supportsMigration: true
    )
    
    return ServerValidationResult(
      isValid: true,
      serverConfig: serverConfig
    )
  }
}

// MARK: - Server Card View

struct ServerCardView: View {
  let server: ServerConfiguration
  let isSelected: Bool
  let isCurrent: Bool
  let onSelect: () -> Void
  
  var body: some View {
    Button {
      if !isCurrent {
        onSelect()
      }
    } label: {
      VStack(alignment: .leading, spacing: 12) {
        
        // Header
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(server.displayName)
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
              
              if isCurrent {
                Text("CURRENT")
                  .font(.caption2)
                  .fontWeight(.bold)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 2)
                  .background(.blue.opacity(0.2))
                  .foregroundStyle(.blue)
                  .clipShape(Capsule())
              }
              
              if isSelected {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(.green)
              }
            }
            
            Text(server.hostname)
              .font(.callout)
              .foregroundStyle(.secondary)
            
            if let description = server.description {
              Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          
          Spacer()
          
          migrationSupportBadge
        }
        
        // Capabilities
        if !server.capabilities.isEmpty {
          HStack {
            Text("Features:")
              .font(.caption)
              .foregroundStyle(.secondary)
            
            ForEach(server.capabilities.prefix(4), id: \.self) { capability in
              Text(capability.capitalized)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.2))
                .foregroundStyle(.secondary)
                .clipShape(Capsule())
            }
            
            if server.capabilities.count > 4 {
              Text("+\(server.capabilities.count - 4)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
        
        // Limits info
        HStack {
          if let maxSize = server.maxAccountSize {
            limitInfo(
              icon: "internaldrive",
              label: "Max Size",
              value: ByteCountFormatter().string(fromByteCount: Int64(maxSize))
            )
          }
          
          if let rateLimit = server.rateLimit {
            limitInfo(
              icon: "speedometer",
              label: "Rate Limit",
              value: "\(rateLimit.requestsPerMinute)/min"
            )
          }
        }
      }
      .padding()
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(backgroundColor)
          .overlay(
            RoundedRectangle(cornerRadius: 12)
              .stroke(borderColor, lineWidth: strokeWidth)
          )
      )
    }
    .buttonStyle(PlainButtonStyle())
    .disabled(isCurrent)
  }
  
  private var migrationSupportBadge: some View {
    Group {
      if server.supportsMigration {
        Label("Supported", systemImage: "checkmark.shield.fill")
          .font(.caption)
          .foregroundStyle(.green)
      } else {
        Label("Limited", systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }
  
  private func limitInfo(icon: String, label: String, value: String) -> some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
        .font(.caption2)
        .foregroundStyle(.secondary)
      
      Text("\(label): \(value)")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }
  
  private var backgroundColor: Color {
    if isCurrent {
      return .blue.opacity(0.1)
    } else if isSelected {
      return .green.opacity(0.1)
    } else {
      return Color(UIColor.quaternaryLabel).opacity(0.3)
    }
  }
  
  private var borderColor: Color {
    if isCurrent {
      return .blue.opacity(0.5)
    } else if isSelected {
      return .green
    } else {
      return Color(UIColor.quaternaryLabel)
    }
  }
  
  private var strokeWidth: CGFloat {
    if isSelected || isCurrent {
      return 2
    } else {
      return 1
    }
  }
}

// MARK: - Custom Server Sheet

struct CustomServerSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var hostname: String
  let onValidate: (String) async -> ServerValidationResult
  let onConfirm: (ServerConfiguration) -> Void
  
  @State private var isValidating = false
  @State private var validationResult: ServerValidationResult?
  
  var body: some View {
    NavigationView {
      Form {
        Section("Server Details") {
          TextField("Server Hostname", text: $hostname)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.URL)
          
          Text("Enter the hostname of an AT Protocol server (e.g., my-server.com)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        
        if let result = validationResult {
          Section("Validation Result") {
            if result.isValid {
              if let server = result.serverConfig {
                Label("Server is valid and supports migration", systemImage: "checkmark.circle.fill")
                  .foregroundStyle(.green)
                
                VStack(alignment: .leading, spacing: 8) {
                  Text("Server: \(server.displayName)")
                  Text("Version: \(server.version ?? "Unknown")")
                  Text("Capabilities: \(server.capabilities.joined(separator: ", "))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
              }
            } else {
              Label(result.error ?? "Server validation failed", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
            }
          }
        }
        
        Section {
          Button {
            Task {
              await validateServer()
            }
          } label: {
            HStack {
              if isValidating {
                ProgressView()
                  .scaleEffect(0.8)
                Text("Validating...")
              } else {
                Text("Validate Server")
              }
            }
          }
          .disabled(hostname.isEmpty || isValidating)
        }
        
        if let result = validationResult, result.isValid, let server = result.serverConfig {
          Section {
            Button("Use This Server") {
              onConfirm(server)
            }
            .foregroundStyle(.blue)
          }
        }
      }
      .navigationTitle("Custom Server")
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Cancel") {
            dismiss()
          }
        }
      }
    }
  }
  
  private func validateServer() async {
    isValidating = true
    validationResult = await onValidate(hostname)
    isValidating = false
  }
}

// MARK: - Validation Result

struct ServerValidationResult {
  let isValid: Bool
  let serverConfig: ServerConfiguration?
  let error: String?
  
  init(isValid: Bool, serverConfig: ServerConfiguration? = nil, error: String? = nil) {
    self.isValid = isValid
    self.serverConfig = serverConfig
    self.error = error
  }
}
