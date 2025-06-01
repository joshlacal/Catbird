import OSLog
import SwiftUI
import Petrel

/// View for displaying and managing conversation invitations
struct ConversationInvitationsView: View {
  @Environment(AppState.self) private var appState
  @State private var pendingInvitations: [ChatBskyConvoDefs.ConvoView] = []
  @State private var isLoading = false
  
  private let logger = Logger(subsystem: "blue.catbird", category: "ConversationInvitationsView")
  
  // Filter for conversations that might be invitations (could be based on status or other criteria)
  private var invitations: [ChatBskyConvoDefs.ConvoView] {
    // This would need to be adapted based on how invitations are identified in the actual API
    // For now, we'll use conversations with no last message as a proxy for invitations
    appState.chatManager.conversations.filter { conversation in
      conversation.lastMessage == nil && conversation.unreadCount == 0
    }
  }
  
  var body: some View {
    List {
      if invitations.isEmpty {
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
    .navigationBarTitleDisplayMode(.inline)
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
    // This would load pending invitations from the server
    // For now, we'll refresh the conversations list
    await appState.chatManager.loadConversations(refresh: true)
  }
  
  private func acceptInvitation(_ conversation: ChatBskyConvoDefs.ConvoView) {
    Task {
      let success = await appState.chatManager.acceptConversation(convoId: conversation.id)
      if success {
        logger.debug("Successfully accepted invitation for conversation: \(conversation.id)")
      } else {
        logger.error("Failed to accept invitation for conversation: \(conversation.id)")
      }
    }
  }
  
  private func declineInvitation(_ conversation: ChatBskyConvoDefs.ConvoView) {
    Task {
      await appState.chatManager.leaveConversation(convoId: conversation.id)
      logger.debug("Declined invitation for conversation: \(conversation.id)")
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
    conversation.members.filter { $0.did.didString() != appState.currentUserDID }
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
              
              Text("+\(otherMembers.count - 3)")
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
          Text("@\(otherMembers.first?.handle.description ?? "unknown") wants to start a conversation")
                            .appFont(AppTextRole.body)
            .fontWeight(.medium)
          
          if let displayName = otherMembers.first?.displayName {
            Text(displayName)
              .appFont(AppTextRole.subheadline)
              .foregroundColor(.secondary)
          }
        } else {
          Text("\(otherMembers.count) people want to start a group conversation")
                            .appFont(AppTextRole.body)
            .fontWeight(.medium)
          
          let names = otherMembers.prefix(2).compactMap { $0.displayName ?? "@\(otherMembers.first?.handle.description ?? "unknown")" }
          if !names.isEmpty {
            Text(names.joined(separator: ", ") + (otherMembers.count > 2 ? " and others" : ""))
              .appFont(AppTextRole.subheadline)
              .foregroundColor(.secondary)
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
  NavigationView {
    ConversationInvitationsView()
      .environment(AppState())
  }
}
