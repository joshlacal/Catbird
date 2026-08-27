import OSLog
import Petrel
import SwiftUI

/// Bluesky chat declaration privacy options
enum ChatPrivacyOption: String, CaseIterable, Identifiable, Sendable {
  case all = "all"
  case following = "following"
  case none = "none"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all:
      return "Everyone"
    case .following:
      return "People I follow"
    case .none:
      return "No one"
    }
  }
}

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
  @State private var hasLoadedInitialState = false  // Track if we've completed initial load
  @State private var messagesFrom: ChatPrivacyOption = .following
  @State private var groupInvitesFrom: ChatPrivacyOption = .following
  @State private var isLoadingDeclaration = true
  @State private var declarationLoadError: String?
  @State private var isSavingDeclaration = false
  @State private var declarationCid: CID?
  private let logger = Logger(subsystem: "blue.catbird", category: "ChatSettingsView")
  
  var body: some View {
    NavigationStack {
      List {
        Section {
          if isLoadingDeclaration {
            HStack {
              Text("Loading chat privacy settings…")
                .foregroundStyle(.secondary)
              Spacer()
              ProgressView()
                .scaleEffect(0.8)
            }
          } else if let declarationLoadError {
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                  .foregroundStyle(.orange)
                Text("Failed to load privacy settings")
                  .font(.subheadline)
                  .foregroundStyle(.primary)
              }
              Text(declarationLoadError)
                .font(.caption)
                .foregroundStyle(.secondary)
              Button("Retry") {
                Task {
                  await loadDeclaration()
                }
              }
              .font(.subheadline)
            }
            .padding(.vertical, 4)
          } else {
            Picker("Messages from", selection: Binding(
              get: { messagesFrom },
              set: { newValue in
                guard !isSavingDeclaration, newValue != messagesFrom else { return }
                let previous = messagesFrom
                messagesFrom = newValue
                Task {
                  await updateDeclaration(
                    messagesFrom: newValue,
                    groupInvitesFrom: groupInvitesFrom,
                    previousMessagesFrom: previous,
                    previousGroupInvitesFrom: groupInvitesFrom
                  )
                }
              }
            )) {
              ForEach(ChatPrivacyOption.allCases) { option in
                Text(option.title).tag(option)
              }
            }
            .disabled(isSavingDeclaration)

            Picker("Group chat invites from", selection: Binding(
              get: { groupInvitesFrom },
              set: { newValue in
                guard !isSavingDeclaration, newValue != groupInvitesFrom else { return }
                let previous = groupInvitesFrom
                groupInvitesFrom = newValue
                Task {
                  await updateDeclaration(
                    messagesFrom: messagesFrom,
                    groupInvitesFrom: newValue,
                    previousMessagesFrom: messagesFrom,
                    previousGroupInvitesFrom: previous
                  )
                }
              }
            )) {
              ForEach(ChatPrivacyOption.allCases) { option in
                Text(option.title).tag(option)
              }
            }
            .disabled(isSavingDeclaration)
            
            if isSavingDeclaration {
              HStack {
                Text("Saving privacy settings…")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Spacer()
                ProgressView()
                  .scaleEffect(0.8)
              }
            }
          }
        } header: {
          Text("Bluesky Chat Privacy")
        } footer: {
          Text("Choose who can send you direct messages and invite you to group chats on Bluesky.")
        }

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
              Toggle("", isOn: Binding(
                get: { isOptedIn },
                set: { newValue in
                  // Only process if we've loaded initial state and value actually changed
                  guard hasLoadedInitialState, newValue != isOptedIn else { return }
                  toggleOptInStatus(newValue)
                }
              ))
                .labelsHidden()
            }
          }
          
          // Show MLS privacy settings link when opted in
          #if os(iOS)
          if isOptedIn && !isLoadingOptInStatus {
            NavigationLink {
              MLSChatSettingsView()
            } label: {
              HStack {
                Image(systemName: "lock.shield")
                  .foregroundColor(.blue)
                Text("MLS Privacy Settings")
              }
            }
          }
          #endif
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

          // chat.bsky.moderation.* requires chat-service admin auth no user session has;
          // the entry point exists for internal debug builds only.
          #if DEBUG
            NavigationLink {
              ChatModerationView()
            } label: {
              HStack {
                Image(systemName: "shield")
                  .foregroundColor(.orange)
                Text("Moderation Tools")
              }
            }
          #endif
        } header: {
          #if DEBUG
            Text("Data & Moderation")
          #else
            Text("Data")
          #endif
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
        async let optIn: () = loadOptInStatus()
        async let declaration: () = loadDeclaration()
        _ = await (optIn, declaration)
      }
      .onAppear {
        // Refresh opt-in status when returning from MLSChatSettingsView (user may have opted out)
        if hasLoadedInitialState {
          let currentStatus = ExperimentalSettings.shared.isMLSChatEnabled(for: appState.userDID)
          if currentStatus != isOptedIn {
            isOptedIn = currentStatus
          }
        }
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
      hasLoadedInitialState = true
    }
  }

  private func loadDeclaration() async {
    guard let client = appState.atProtoClient else {
      await MainActor.run {
        self.declarationLoadError = "Not authenticated"
        self.isLoadingDeclaration = false
      }
      return
    }

    await MainActor.run {
      self.isLoadingDeclaration = true
      self.declarationLoadError = nil
    }

    do {
      let params = ComAtprotoRepoGetRecord.Parameters(
        repo: try ATIdentifier(string: appState.userDID),
        collection: try NSID(nsidString: "chat.bsky.actor.declaration"),
        rkey: try RecordKey(keyString: "self")
      )
      let (code, recordOutput) = try await client.com.atproto.repo.getRecord(input: params)
      if code == 200, let recordOutput {
        let cid = recordOutput.cid
        if let decl = recordOutput.value.decoded(ChatBskyActorDeclaration.self) {
          let incoming = ChatPrivacyOption(rawValue: decl.allowIncoming) ?? .following
          let groupInvites = decl.allowGroupInvites.flatMap(ChatPrivacyOption.init(rawValue:)) ?? incoming
          await MainActor.run {
            self.declarationCid = cid
            self.messagesFrom = incoming
            self.groupInvitesFrom = groupInvites
            self.isLoadingDeclaration = false
            self.declarationLoadError = nil
          }
          return
        } else {
          logger.error("Failed to decode ChatBskyActorDeclaration from successful response")
          await MainActor.run {
            self.declarationLoadError = "Failed to parse chat privacy settings."
            self.isLoadingDeclaration = false
          }
          return
        }
      } else {
        logger.warning("Failed to load chat declaration: status \(code)")
        await MainActor.run {
          self.declarationLoadError = "Server returned status \(code)."
          self.isLoadingDeclaration = false
        }
      }
    } catch let atprotoError as ATProtoError<ComAtprotoRepoGetRecord.Error> where atprotoError.error == .recordNotFound {
      await MainActor.run {
        self.declarationCid = nil
        self.messagesFrom = .following
        self.groupInvitesFrom = .following
        self.isLoadingDeclaration = false
        self.declarationLoadError = nil
      }
    } catch let xrpcError as ATProtoXRPCError where xrpcError.error == "RecordNotFound" {
      await MainActor.run {
        self.declarationCid = nil
        self.messagesFrom = .following
        self.groupInvitesFrom = .following
        self.isLoadingDeclaration = false
        self.declarationLoadError = nil
      }
    } catch {
      logger.warning("No existing chat declaration record or failed to load: \(error.localizedDescription)")
      await MainActor.run {
        self.declarationLoadError = error.localizedDescription
        self.isLoadingDeclaration = false
      }
    }
  }

  private func updateDeclaration(
    messagesFrom: ChatPrivacyOption,
    groupInvitesFrom: ChatPrivacyOption,
    previousMessagesFrom: ChatPrivacyOption,
    previousGroupInvitesFrom: ChatPrivacyOption
  ) async {
    guard let client = appState.atProtoClient else {
      await MainActor.run {
        self.messagesFrom = previousMessagesFrom
        self.groupInvitesFrom = previousGroupInvitesFrom
        self.errorMessage = "Not authenticated"
      }
      return
    }

    await MainActor.run {
      self.isSavingDeclaration = true
    }

    do {
      let declaration = ChatBskyActorDeclaration(
        allowIncoming: messagesFrom.rawValue,
        allowGroupInvites: groupInvitesFrom.rawValue
      )
      let input = ComAtprotoRepoPutRecord.Input(
        repo: try ATIdentifier(string: appState.userDID),
        collection: try NSID(nsidString: "chat.bsky.actor.declaration"),
        rkey: try RecordKey(keyString: "self"),
        record: .knownType(declaration),
        swapRecord: declarationCid
      )
      let (code, output) = try await client.com.atproto.repo.putRecord(input: input)
      guard code == 200, let output else {
        throw NSError(domain: "ChatSettings", code: code, userInfo: [NSLocalizedDescriptionKey: "Failed to update chat privacy settings (\(code))."])
      }
      await MainActor.run {
        self.declarationCid = output.cid
        self.isSavingDeclaration = false
      }
    } catch {
      logger.error("Failed to update chat declaration: \(error.localizedDescription)")
      await MainActor.run {
        self.messagesFrom = previousMessagesFrom
        self.groupInvitesFrom = previousGroupInvitesFrom
        self.isSavingDeclaration = false
        self.errorMessage = "Failed to update chat privacy settings: \(error.localizedDescription)"
      }
    }
  }

  private func toggleOptInStatus(_ optIn: Bool) {
    // Prevent re-entrancy: if already toggling, ignore the change
    guard !isTogglingOptIn else {
      logger.debug("Ignoring toggle - already in progress")
      return
    }
    
    Task {
      let userDID = appState.userDID 
      
      guard let mlsClient = await appState.getMLSAPIClient() else {
        logger.error("MLS client not available")
        await MainActor.run {
          errorMessage = "MLS chat is not available"
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

          if let conversationManager = await appState.getMLSConversationManager() {
            do {
              try await conversationManager.ensureDeviceRecordPublished()
            } catch {
              logger.error("Device record publish after opt-in failed: \(error.localizedDescription)")
            }
          }

          ExperimentalSettings.shared.enableMLSChat(for: userDID)
          logger.info("Successfully opted in to MLS chat for account: \(userDID.prefix(20))...")
        } else {
          _ = try await mlsClient.optOut()
          if let conversationManager = await appState.getMLSConversationManager() {
            try? await conversationManager.removeCurrentDeviceRecord()
          }
          ExperimentalSettings.shared.disableMLSChat(for: userDID)
          logger.info("Successfully opted out of MLS chat for account: \(userDID.prefix(20))...")
        }
        await MainActor.run {
          isOptedIn = optIn  // Update state to reflect successful change
          isTogglingOptIn = false
        }
      } catch {
        logger.error("Failed to toggle opt-in status: \(error.localizedDescription)")
        await MainActor.run {
          // State remains unchanged since we didn't update isOptedIn during the toggle
          isTogglingOptIn = false
          errorMessage = "Failed to update MLS chat settings: \(error.localizedDescription)"
        }
      }
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
    NavigationStack {
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
      #if os(iOS)
      .sheet(isPresented: $showingShareSheet) {
        if let data = exportedData {
          ChatShareSheet(items: [data])
        }
      }
      #endif
    }
  }
}

#Preview {
  AsyncPreviewContent { appState in
    ChatSettingsView()
        .environment(AppStateManager.shared)
  }
}
