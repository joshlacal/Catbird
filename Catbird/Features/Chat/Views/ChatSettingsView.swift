import OSLog
import Petrel
import SwiftUI

#if os(iOS)

/// Settings view for chat-related options and actions
struct ChatSettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  
  @State private var showingExportData = false
  @State private var showingDeleteAccountAlert = false
  @State private var showingMarkAllReadAlert = false
  @State private var isExporting = false
  @State private var isDeleting = false
  @State private var isMarkingAllRead = false
  @State private var exportedData: Data?
  @State private var errorMessage: String?
  @State private var isOptedIn = false
  @State private var isLoadingOptInStatus = true  // Start as true to prevent onChange during init
  @State private var isTogglingOptIn = false
  @State private var hasAdminAccess = false
  @State private var isCheckingAdminAccess = true

  private let logger = Logger(subsystem: "blue.catbird", category: "ChatSettingsView")
  
  var body: some View {
    NavigationView {
      List {
        Section {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text("MLS Chat")
                .font(.body)
              Text("Enable end-to-end encrypted messaging")
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer()
            if isLoadingOptInStatus || isTogglingOptIn {
              ProgressView()
                .scaleEffect(0.8)
            } else {
              Toggle("", isOn: $isOptedIn)
                .labelsHidden()
                .onChange(of: isOptedIn) { oldValue, newValue in
                  toggleOptInStatus(newValue)
                }
            }
          }
        } header: {
          Text("Privacy")
        } footer: {
          Text("When enabled, you can use end-to-end encrypted MLS chat. Only opted-in users will be visible in chat typeahead.")
        }

        Section {
          Button {
            markAllConversationsAsRead()
          } label: {
            HStack {
              Image(systemName: "envelope.open")
                .foregroundColor(.blue)
              Text("Mark All Conversations as Read")
              Spacer()
              if isMarkingAllRead {
                ProgressView()
                  .scaleEffect(0.8)
              }
            }
          }
          .disabled(isMarkingAllRead)
        } header: {
          Text("Quick Actions")
        }
        
        Section {
          Button {
            exportChatData()
          } label: {
            HStack {
              Image(systemName: "square.and.arrow.up")
                .foregroundColor(.blue)
              Text("Export Chat Data")
              Spacer()
              if isExporting {
                ProgressView()
                  .scaleEffect(0.8)
              }
            }
          }
          .disabled(isExporting)

          if isCheckingAdminAccess {
            HStack {
              ProgressView()
                .scaleEffect(0.8)
              Text("Checking admin access…")
                .foregroundColor(.secondary)
            }
          } else if hasAdminAccess {
            NavigationLink {
              ChatModerationView()
            } label: {
              HStack {
                Image(systemName: "shield")
                  .foregroundColor(.orange)
                Text("Moderation Tools")
              }
            }
          } else {
            HStack {
              Image(systemName: "lock.fill")
                .foregroundColor(.secondary)
              VStack(alignment: .leading, spacing: 2) {
                Text("Moderation Tools")
                  .foregroundColor(.secondary)
                Text("Visible only to conversation admins")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }
          }
        } header: {
          Text("Data & Moderation")
        }
        
        Section {
          Button {
            showingDeleteAccountAlert = true
          } label: {
            HStack {
              Image(systemName: "trash")
                .foregroundColor(.red)
              Text("Delete Chat Account")
              Spacer()
              if isDeleting {
                ProgressView()
                  .scaleEffect(0.8)
              }
            }
          }
          .disabled(isDeleting)
        } header: {
          Text("Danger Zone")
        } footer: {
          Text("This will permanently delete all your chat data including conversations, messages, and settings. This action cannot be undone.")
        }
      }
      .navigationTitle("Chat Settings")
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
      .alert("Mark All as Read", isPresented: $showingMarkAllReadAlert) {
        Button("Cancel", role: .cancel) { }
        Button("Mark All Read") {
          markAllConversationsAsRead()
        }
      } message: {
        Text("This will mark all conversations as read. Continue?")
      }
      .alert("Delete Chat Account", isPresented: $showingDeleteAccountAlert) {
        Button("Cancel", role: .cancel) { }
        Button("Delete", role: .destructive) {
          deleteChatAccount()
        }
      } message: {
        Text("Are you sure you want to permanently delete your chat account? This will remove all conversations, messages, and chat history. This action cannot be undone.")
      }
      .sheet(isPresented: $showingExportData) {
        ChatDataExportView(exportedData: $exportedData)
      }
      .alert("Error", isPresented: .constant(errorMessage != nil)) {
        Button("OK") {
          errorMessage = nil
        }
      } message: {
        Text(errorMessage ?? "An unknown error occurred")
      }
      .task {
        await loadOptInStatus()
        await refreshAdminAccess()
      }
    }
  }

  private func loadOptInStatus() async {
     let userDID = appState.userDID
    await MainActor.run {
      isLoadingOptInStatus = true
      // Load from local per-account setting
      isOptedIn = ExperimentalSettings.shared.isMLSChatEnabled(for: userDID)
      isLoadingOptInStatus = false
    }
  }

  private func toggleOptInStatus(_ optIn: Bool) {
    // Prevent re-entrancy: if already toggling or still loading, ignore the change
    guard !isTogglingOptIn && !isLoadingOptInStatus else {
      logger.debug("Ignoring toggle - already in progress or still loading")
      return
    }
    
    Task {
      let userDID = appState.userDID 
      
      guard let mlsClient = await appState.getMLSAPIClient() else {
        logger.error("MLS client not available")
        await MainActor.run {
          errorMessage = "MLS chat is not available"
          isOptedIn = !optIn // Revert
        }
        return
      }

      await MainActor.run {
        isTogglingOptIn = true
      }

      do {
        if optIn {
          // CRITICAL FIX: Initialize MLS (device registration + key packages) BEFORE calling optIn
          // This ensures other users can find and add this user to conversations
          logger.info("Initializing MLS before opt-in (device registration + key packages)...")
          try await appState.initializeMLS()
          
          // CRITICAL: Wait for key packages to be uploaded before marking as opted-in
          // This prevents the "no active keypackages" issue where optIn is called
          // but key packages are still being uploaded in a detached task
          if let conversationManager = await appState.getMLSConversationManager() {
            logger.info("Uploading key packages synchronously before opt-in...")
            try await conversationManager.uploadKeyPackageBatchSmart(count: 100)
            logger.info("Key packages uploaded successfully")
          }
          
          // Now call optIn to mark the user as available on the server
          _ = try await mlsClient.optIn()
          ExperimentalSettings.shared.enableMLSChat(for: userDID)
          logger.info("Successfully opted in to MLS chat for account: \(userDID.prefix(20))...")
        } else {
          _ = try await mlsClient.optOut()
          ExperimentalSettings.shared.disableMLSChat(for: userDID)
          logger.info("Successfully opted out of MLS chat for account: \(userDID.prefix(20))...")
        }
        await MainActor.run {
          isTogglingOptIn = false
        }
      } catch {
        logger.error("Failed to toggle opt-in status: \(error.localizedDescription)")
        await MainActor.run {
          isOptedIn = !optIn // Revert the toggle
          isTogglingOptIn = false
          errorMessage = "Failed to update MLS chat settings: \(error.localizedDescription)"
        }
      }
    }
  }

  private func refreshAdminAccess() async {
    await MainActor.run {
      isCheckingAdminAccess = true
    }

    guard let conversationManager = await appState.getMLSConversationManager() else {
      await MainActor.run {
        hasAdminAccess = false
        isCheckingAdminAccess = false
      }
      return
    }

    let isAdmin = await conversationManager.isCurrentUserAdminInAnyConversation()

    await MainActor.run {
      hasAdminAccess = isAdmin
      isCheckingAdminAccess = false
    }
  }
  
  private func markAllConversationsAsRead() {
    Task {
      isMarkingAllRead = true
      let success = await appState.chatManager.markAllConversationsAsRead()
      await MainActor.run {
        isMarkingAllRead = false
        if !success {
          errorMessage = "Failed to mark all conversations as read"
        }
      }
    }
  }
  
  private func exportChatData() {
    Task {
      isExporting = true
      let data = await appState.chatManager.exportChatAccountData()
      await MainActor.run {
        isExporting = false
        if let data = data {
          exportedData = data
          showingExportData = true
        } else {
          errorMessage = "Failed to export chat data"
        }
      }
    }
  }
  
  private func deleteChatAccount() {
    Task {
      isDeleting = true
      let result = await appState.chatManager.deleteChatAccount()
      await MainActor.run {
        isDeleting = false
        if result.success {
          // Optionally save export data before dismissing
          if let exportData = result.exportData {
            exportedData = exportData
            showingExportData = true
          }
          dismiss()
        } else {
          errorMessage = "Failed to delete chat account"
        }
      }
    }
  }
}

/// View for displaying and sharing exported chat data
struct ChatDataExportView: View {
  @Binding var exportedData: Data?
  @Environment(\.dismiss) private var dismiss
  @State private var showingShareSheet = false
  
  var body: some View {
    NavigationView {
      VStack(spacing: 20) {
        Image(systemName: "square.and.arrow.up.circle")
          .appFont(size: 64)
          .foregroundColor(.blue)
        
        Text("Chat Data Exported")
          .appFont(AppTextRole.title2)
          .fontWeight(.semibold)
        
        Text("Your chat data has been exported successfully. You can share or save this file.")
          .multilineTextAlignment(.center)
          .foregroundColor(.secondary)
        
        if let data = exportedData {
          VStack(spacing: 12) {
            Text("File Size: \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
              .appFont(AppTextRole.caption)
              .foregroundColor(.secondary)
            
            Button {
              showingShareSheet = true
            } label: {
              HStack {
                Image(systemName: "square.and.arrow.up")
                Text("Share Export File")
              }
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
          }
        }
        
        Spacer()
      }
      .padding()
      .navigationTitle("Export Complete")
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
      .sheet(isPresented: $showingShareSheet) {
        if let data = exportedData {
          ChatShareSheet(items: [data])
        }
      }
    }
  }
}

#Preview {
    @Previewable @Environment(AppState.self) var appState
  ChatSettingsView()
    .environment(AppStateManager.shared)
}
#endif
