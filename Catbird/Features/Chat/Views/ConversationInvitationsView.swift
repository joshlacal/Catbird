import OSLog
import SwiftUI
import Petrel

/// View for displaying and managing conversation invitations
struct ConversationInvitationsView: View {
  @Environment(AppState.self) private var appState
  @State private var pendingInvitations: [ChatBskyConvoDefs.ConvoView] = []
  @State private var isLoading = false
  
  private let logger = Logger(subsystem: "blue.catbird", category: "ConversationInvitationsView")
  
  // Filter for conversations that are actual invitations based on their status
  private var invitations: [ChatBskyConvoDefs.ConvoView] {
    // Use the proper message requests from ChatManager
    // Message requests are invitations that haven't been accepted yet
    return appState.chatManager.messageRequests
  }
  
  var body: some View {
    List {
      if isLoading && invitations.isEmpty {
        HStack {
          Spacer()
          ProgressView("Loading invitations…")
          Spacer()
        }
        .listRowSeparator(.hidden)
      } else if invitations.isEmpty {
        ContentUnavailableView {
          Label("No Pending Invitations", systemImage: "tray")
        } description: {
          Text("You don't have any pending conversation invitations.")
        }
      } else {
        ForEach(invitations) { invitation in
          ConversationInvitationRow(
            conversation: invitation,
            onAccept: { convo in
              acceptInvitation(convo)
            },
            onDecline: { convo in
              declineInvitation(convo)
            }
          )
        }
      }
    }
    .navigationTitle("Invitations")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .refreshable {
      await loadInvitations()
    }
    .onAppear {
      Task {
        await loadInvitations()
      }
    }
  }
  
  private func loadInvitations() async {
    // Load pending invitations (message requests) from the server
    isLoading = true
    defer { isLoading = false }
    
    // Load message requests specifically - these are conversation invitations
    await appState.chatManager.loadMessageRequests(refresh: true)
    
    logger.debug("Loaded \(appState.chatManager.messageRequests.count) conversation invitations")
  }
  
  private func acceptInvitation(_ conversation: ChatBskyConvoDefs.ConvoView) {
    Task {
      // Use the dedicated message request acceptance method
      let success = await appState.chatManager.acceptMessageRequest(convoId: conversation.id)
      if success {
        logger.debug("Successfully accepted invitation for conversation: \(conversation.id)")
        
        // Refresh invitations list to remove the accepted one
        await loadInvitations()
      } else {
        logger.error("Failed to accept invitation for conversation: \(conversation.id)")
      }
    }
  }
  
  private func declineInvitation(_ conversation: ChatBskyConvoDefs.ConvoView) {
    Task {
      // Use the dedicated message request decline method
      let success = await appState.chatManager.declineMessageRequest(convoId: conversation.id)
      if success {
        logger.debug("Successfully declined invitation for conversation: \(conversation.id)")
        
        // Refresh invitations list to remove the declined one
        await loadInvitations()
      } else {
        logger.error("Failed to decline invitation for conversation: \(conversation.id)")
      }
    }
  }
}

/// Row view for individual conversation invitations
struct ConversationInvitationRow: View {
  @Environment(AppState.self) private var appState
  let conversation: ChatBskyConvoDefs.ConvoView
  let onAccept: (ChatBskyConvoDefs.ConvoView) -> Void
  let onDecline: (ChatBskyConvoDefs.ConvoView) -> Void
  
  @State private var isProcessing = false
  
  private var otherMembers: [ChatBskyActorDefs.ProfileViewBasic] {
    conversation.members.filter { $0.did.didString() != appState.userDID }
  }
  
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        // Profile pictures
        HStack {
          ForEach(otherMembers.prefix(3), id: \.did) { member in
            ChatProfileAvatarView(profile: member, size: 32)
          }
          
          if otherMembers.count > 3 {
            ZStack {
              Circle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 32, height: 32)
              
              Text(verbatim: "+\(otherMembers.count - 3)")
                .appFont(AppTextRole.caption)
                .fontWeight(.medium)
            }
          }
        }
        
        Spacer()
        
//        // Timestamp
//          Text(conversation.createdAt.date.formatted(date: .abbreviated, time: .shortened))
//          .appFont(AppTextRole.caption)
//          .foregroundColor(.secondary)
      }
      
      // Invitation text
      VStack(alignment: .leading, spacing: 4) {
        if otherMembers.count == 1 {
          if let handle = otherMembers.first?.handle.description {
            Text(
              "@\(handle) wants to start a conversation",
              comment: "Invitation row title when one user invites you (%@ = sender handle without @)"
            )
            .appFont(AppTextRole.body)
            .fontWeight(.medium)
          } else {
            Text(
              "Someone wants to start a conversation",
              comment: "Fallback invitation row title when sender handle is unavailable"
            )
            .appFont(AppTextRole.body)
            .fontWeight(.medium)
          }
          
          if let displayName = otherMembers.first?.displayName {
            Text(verbatim: displayName)
              .appFont(AppTextRole.subheadline)
              .foregroundColor(.secondary)
          }
        } else {
          Text(
            "\(otherMembers.count) people want to start a group conversation",
            comment: "Invitation row title for a group chat (%lld = participant count)"
          )
          .appFont(AppTextRole.body)
          .fontWeight(.medium)
          
          let names = otherMembers.prefix(2).map { $0.chatDisplayName }
          if !names.isEmpty {
            if otherMembers.count > 2, names.count >= 2 {
              let remaining = otherMembers.count - 2
              Text(
                "\(names[0]), \(names[1]), and \(remaining) others",
                comment: "Group invitation participant preview (%1$@ = first person, %2$@ = second person, %3$lld = remaining count)"
              )
              .appFont(AppTextRole.subheadline)
              .foregroundColor(.secondary)
            } else {
              Text(verbatim: names.joined(separator: ", "))
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.secondary)
            }
          }
        }
      }
      
      // Action buttons
      HStack(spacing: 12) {
        Button {
          isProcessing = true
          onDecline(conversation)
          isProcessing = false
        } label: {
          Text("Decline")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(isProcessing)
        
        Button {
          isProcessing = true
          onAccept(conversation)
          isProcessing = false
        } label: {
          HStack {
            if isProcessing {
              ProgressView()
                .scaleEffect(0.8)
            }
            Text("Accept")
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isProcessing)
      }
    }
    .padding(.vertical, 8)
  }
}

#Preview {
  AsyncPreviewContent { appState in
    NavigationStack {
        ConversationInvitationsView()
          .environment(AppStateManager.shared)
      }
  }
}
