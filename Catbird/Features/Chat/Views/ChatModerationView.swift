import OSLog
import Petrel
import SwiftUI

#if os(iOS)

/// Moderation tools for chat administrators
struct ChatModerationView: View {
  @Environment(AppState.self) private var appState
  @State private var selectedTab = 0
  @State private var hasAdminAccess = false
  @State private var isCheckingAccess = true
  
  var body: some View {
    Group {
      if isCheckingAccess {
        VStack(spacing: 12) {
          ProgressView()
          Text("Verifying admin access…")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      } else if hasAdminAccess {
        TabView(selection: $selectedTab) {
          ActorMetadataView()
            .tabItem {
              Image(systemName: "person.circle")
              Text("User Stats")
            }
            .tag(0)
          
          MessageContextView()
            .tabItem {
              Image(systemName: "message.circle")
              Text("Message Context")
            }
            .tag(1)
          
          AccessControlView()
            .tabItem {
              Image(systemName: "key")
              Text("Access Control")
            }
            .tag(2)
        }
      } else {
        VStack(spacing: 12) {
          Image(systemName: "lock.shield")
            .font(.largeTitle)
            .foregroundColor(.secondary)
          Text("Admin tools are limited to conversation admins.")
            .font(.callout)
            .multilineTextAlignment(.center)
            .foregroundColor(.secondary)
        }
        .padding()
      }
    }
    .navigationTitle("Moderation Tools")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .task {
      await checkAdminAccess()
    }
  }

  private func checkAdminAccess() async {
    guard let conversationManager = await appState.getMLSConversationManager() else {
      await MainActor.run {
        hasAdminAccess = false
        isCheckingAccess = false
      }
      return
    }

    let isAdmin = await conversationManager.isCurrentUserAdminInAnyConversation()

    await MainActor.run {
      hasAdminAccess = isAdmin
      isCheckingAccess = false
    }
  }
}

/// View for checking user chat statistics
struct ActorMetadataView: View {
  @Environment(AppState.self) private var appState
  @State private var userDID = ""
  @State private var metadata: ChatBskyModerationGetActorMetadata.Output?
  @State private var isLoading = false
  @State private var errorMessage: String?
  
  private let logger = Logger(subsystem: "blue.catbird", category: "ActorMetadataView")
  
  var body: some View {
    Form {
      Section {
        TextField("User DID or Handle", text: $userDID)
          .textFieldStyle(.roundedBorder)
          #if os(iOS)
          .autocapitalization(.none)
          #endif
          .autocorrectionDisabled(true)
        
        Button {
          fetchMetadata()
        } label: {
          HStack {
            if isLoading {
              ProgressView()
                .scaleEffect(0.8)
            }
            Text("Get User Statistics")
          }
        }
        .disabled(userDID.isEmpty || isLoading)
      } header: {
        Text("User Lookup")
      } footer: {
        Text("Enter a user's DID (did:plc:...) or handle (@username) to view their chat usage statistics.")
      }
      
      if let metadata = metadata {
        Section("Usage Statistics") {
          StatRow(title: "Messages Sent (24h)", value: "\(metadata.day.messagesSent)")
          StatRow(title: "Messages Received (24h)", value: "\(metadata.day.messagesReceived)")
          StatRow(title: "Conversations (24h)", value: "\(metadata.day.convos)")
          StatRow(title: "Conversations Started (24h)", value: "\(metadata.day.convosStarted)")
          
          StatRow(title: "Messages Sent (30d)", value: "\(metadata.month.messagesSent)")
          StatRow(title: "Messages Received (30d)", value: "\(metadata.month.messagesReceived)")
          StatRow(title: "Conversations (30d)", value: "\(metadata.month.convos)")
          StatRow(title: "Conversations Started (30d)", value: "\(metadata.month.convosStarted)")
          
          StatRow(title: "Total Messages Sent", value: "\(metadata.all.messagesSent)")
          StatRow(title: "Total Messages Received", value: "\(metadata.all.messagesReceived)")
          StatRow(title: "Total Conversations", value: "\(metadata.all.convos)")
          StatRow(title: "Total Conversations Started", value: "\(metadata.all.convosStarted)")
        }
      }
    }
    .alert("Error", isPresented: .constant(errorMessage != nil)) {
      Button("OK") {
        errorMessage = nil
      }
    } message: {
      Text(errorMessage ?? "An unknown error occurred")
    }
  }
  
  private func fetchMetadata() {
    Task {
      isLoading = true
      let result = await appState.chatManager.getActorMetadata(actor: userDID)
      await MainActor.run {
        isLoading = false
        if let result = result {
          metadata = result
          errorMessage = nil
        } else {
          metadata = nil
          errorMessage = "Failed to fetch user metadata. Please check the DID/handle and try again."
        }
      }
    }
  }
}

/// View for checking message context around a specific message
struct MessageContextView: View {
  @Environment(AppState.self) private var appState
  @State private var conversationId = ""
  @State private var messageId = ""
  @State private var beforeCount = 5
  @State private var afterCount = 5
  @State private var context: ChatBskyModerationGetMessageContext.Output?
  @State private var isLoading = false
  @State private var errorMessage: String?
  
  var body: some View {
    Form {
      Section {
        TextField("Conversation ID", text: $conversationId)
          .textFieldStyle(.roundedBorder)
          #if os(iOS)
          .autocapitalization(.none)
          #endif
          .autocorrectionDisabled(true)
        
        TextField("Message ID", text: $messageId)
          .textFieldStyle(.roundedBorder)
          #if os(iOS)
          .autocapitalization(.none)
          #endif
          .autocorrectionDisabled(true)
        
        Stepper("Messages before: \(beforeCount)", value: $beforeCount, in: 0...20)
        Stepper("Messages after: \(afterCount)", value: $afterCount, in: 0...20)
        
        Button {
          fetchContext()
        } label: {
          HStack {
            if isLoading {
              ProgressView()
                .scaleEffect(0.8)
            }
            Text("Get Message Context")
          }
        }
        .disabled(conversationId.isEmpty || messageId.isEmpty || isLoading)
      } header: {
        Text("Message Context Lookup")
      } footer: {
        Text("Get messages before and after a specific message for moderation review.")
      }
      
      if let context = context {
        Section("Message Context") {
          Text("Found \(context.messages.count) messages in context")
            .foregroundColor(.secondary)
          
          // Display messages in context
          ForEach(Array(context.messages.enumerated()), id: \.offset) { _, messageUnion in
            switch messageUnion {
            case .chatBskyConvoDefsMessageView(let messageView):
              MessageContextRow(
                messageView: messageView,
                isTargetMessage: messageView.id == messageId
              )
            case .chatBskyConvoDefsDeletedMessageView(let deletedView):
              HStack {
                Image(systemName: "trash")
                  .foregroundColor(.red)
                Text("Deleted message")
                  .italic()
                Spacer()
                Text(deletedView.sentAt.date.formatted(date: .abbreviated, time: .shortened))
                  .appFont(AppTextRole.caption)
                  .foregroundColor(.secondary)
              }
            case .unexpected:
              Text("Unknown message type")
                .foregroundColor(.secondary)
                .italic()
            }
          }
        }
      }
    }
    .alert("Error", isPresented: .constant(errorMessage != nil)) {
      Button("OK") {
        errorMessage = nil
      }
    } message: {
      Text(errorMessage ?? "An unknown error occurred")
    }
  }
  
  private func fetchContext() {
    Task {
      isLoading = true
      let result = await appState.chatManager.getMessageContext(
        convoId: conversationId,
        messageId: messageId,
        before: beforeCount,
        after: afterCount
      )
      await MainActor.run {
        isLoading = false
        if let result = result {
          context = result
          errorMessage = nil
        } else {
          context = nil
          errorMessage = "Failed to fetch message context. Please check the IDs and try again."
        }
      }
    }
  }
}

/// View for managing user access to chat
struct AccessControlView: View {
  @Environment(AppState.self) private var appState
  @State private var userDID = ""
  @State private var allowAccess = true
  @State private var reference = ""
  @State private var isUpdating = false
  @State private var errorMessage: String?
  @State private var successMessage: String?
  
  var body: some View {
    Form {
      Section {
        TextField("User DID or Handle", text: $userDID)
          .textFieldStyle(.roundedBorder)
          #if os(iOS)
          .autocapitalization(.none)
          #endif
          .autocorrectionDisabled(true)
        
        Toggle("Allow Chat Access", isOn: $allowAccess)
        
        TextField("Reference (optional)", text: $reference)
          .textFieldStyle(.roundedBorder)
          #if os(iOS)
          .autocapitalization(.none)
          #endif
        
        Button {
          updateAccess()
        } label: {
          HStack {
            if isUpdating {
              ProgressView()
                .scaleEffect(0.8)
            }
            Text("Update Access")
          }
        }
        .disabled(userDID.isEmpty || isUpdating)
      } header: {
        Text("User Access Control")
      } footer: {
        Text("Enable or disable chat access for specific users. Reference field can be used for moderation case tracking.")
      }
    }
    .alert("Success", isPresented: .constant(successMessage != nil)) {
      Button("OK") {
        successMessage = nil
      }
    } message: {
      Text(successMessage ?? "")
    }
    .alert("Error", isPresented: .constant(errorMessage != nil)) {
      Button("OK") {
        errorMessage = nil
      }
    } message: {
      Text(errorMessage ?? "An unknown error occurred")
    }
  }
  
  private func updateAccess() {
    Task {
      isUpdating = true
      let success = await appState.chatManager.updateActorAccess(
        actor: userDID,
        allowAccess: allowAccess,
        ref: reference.isEmpty ? nil : reference
      )
      await MainActor.run {
        isUpdating = false
        if success {
          successMessage = "Successfully updated chat access for user"
          // Clear form
          userDID = ""
          reference = ""
          allowAccess = true
        } else {
          errorMessage = "Failed to update chat access. Please check the DID/handle and try again."
        }
      }
    }
  }
}

/// Helper view for displaying statistics
struct StatRow: View {
  let title: String
  let value: String
  
  var body: some View {
    HStack {
      Text(title)
      Spacer()
      Text(value)
        .fontWeight(.medium)
        .foregroundColor(.primary)
    }
  }
}

/// Helper view for displaying message context
struct MessageContextRow: View {
  @Environment(AppState.self) private var appState
  let messageView: ChatBskyConvoDefs.MessageView
  let isTargetMessage: Bool
  @State private var senderHandle: String = ""
  
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("@\(senderHandle.isEmpty ? messageView.sender.did.didString() : senderHandle)")
          .appFont(AppTextRole.caption)
          .fontWeight(.medium)
          .foregroundColor(isTargetMessage ? .white : .primary)
        
        if isTargetMessage {
          Text("TARGET")
            .appFont(AppTextRole.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.red)
            .foregroundColor(.white)
            .clipShape(Capsule())
        }
        
        Spacer()
        
        Text(messageView.sentAt.date.formatted(date: .abbreviated, time: .shortened))
          .appFont(AppTextRole.caption)
          .foregroundColor(isTargetMessage ? .white : .secondary)
      }
      
      Text(messageView.text)
                        .appFont(AppTextRole.body)
        .foregroundColor(isTargetMessage ? .white : .primary)
    }
    .padding()
    .background(isTargetMessage ? Color.red.opacity(0.8) : Color.gray.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .task {
      await resolveHandle()
    }
  }
  
  private func resolveHandle() async {
    // Try to resolve the DID to a handle using the chat manager
    do {
      if let client = appState.atProtoClient {
          let params = AppBskyActorGetProfile.Parameters(actor: try ATIdentifier(string: messageView.sender.did.didString()))
        let (_, profile) = try await client.app.bsky.actor.getProfile(input: params)
          senderHandle = profile?.handle.description ?? messageView.sender.did.didString()
      }
    } catch {
      // If resolution fails, keep using the DID
      senderHandle = messageView.sender.did.didString()
    }
  }
}

#Preview {
    @Previewable @Environment(AppState.self) var appState
  NavigationStack {
    ChatModerationView()
      .environment(AppStateManager.shared)
  }
}
#endif
