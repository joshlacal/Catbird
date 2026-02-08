#if os(iOS)

import OSLog
import SwiftUI
import Petrel

/// View for managing conversation settings and actions
struct ConversationManagementView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  
  let conversation: ChatBskyConvoDefs.ConvoView
  
  @State private var showingLeaveAlert = false
  @State private var isProcessing = false
  @State private var errorMessage: String?
  
  private let logger = Logger(subsystem: "blue.catbird", category: "ConversationManagementView")
  
  var body: some View {
    NavigationStack {
      List {
        // Conversation info section
        Section {
          ConversationInfoRow(conversation: conversation)
        } header: {
          Text("Conversation Info")
        }
        
        // Quick actions section
        Section {
          if conversation.muted {
            Button {
              unmuteConversation()
            } label: {
              HStack {
                Image(systemName: "bell")
                  .foregroundColor(.blue)
                Text("Unmute Conversation")
              }
            }
            .disabled(isProcessing)
          } else {
            Button {
              muteConversation()
            } label: {
              HStack {
                Image(systemName: "bell.slash")
                  .foregroundColor(.orange)
                Text("Mute Conversation")
              }
            }
            .disabled(isProcessing)
          }
          
          Button {
            markAsRead()
          } label: {
            HStack {
              Image(systemName: "envelope.open")
                .foregroundColor(.blue)
              Text("Mark as Read")
            }
          }
          .disabled(isProcessing || conversation.unreadCount == 0)
        } header: {
          Text("Actions")
        }
        
        // Danger zone
        Section {
          Button {
            showingLeaveAlert = true
          } label: {
            HStack {
              Image(systemName: "rectangle.portrait.and.arrow.right")
                .foregroundColor(.red)
              Text("Leave Conversation")
            }
          }
          .disabled(isProcessing)
        } header: {
          Text("Danger Zone")
        } footer: {
          Text("Leaving this conversation will remove it from your chat list. You won't receive new messages unless someone starts a new conversation with you.")
        }
      }
      .navigationTitle("Conversation Settings")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", systemImage: "xmark") {
            dismiss()
          }
        }
        
        ToolbarItem(placement: .primaryAction) {
          if isProcessing {
            ProgressView()
              .scaleEffect(0.8)
          }
        }
      }
      .alert("Leave Conversation", isPresented: $showingLeaveAlert) {
        Button("Cancel", role: .cancel) { }
        Button("Leave", role: .destructive) {
          leaveConversation()
        }
      } message: {
        Text("Are you sure you want to leave this conversation? You will no longer receive messages from this conversation.")
      }
      .alert("Error", isPresented: .constant(errorMessage != nil)) {
        Button("OK") {
          errorMessage = nil
        }
      } message: {
        Text(errorMessage ?? "An unknown error occurred")
      }
    }
  }
  
  private func muteConversation() {
    Task {
      isProcessing = true
      await appState.chatManager.muteConversation(convoId: conversation.id)
      await MainActor.run {
        isProcessing = false
        dismiss()
      }
    }
  }
  
  private func unmuteConversation() {
    Task {
      isProcessing = true
      await appState.chatManager.unmuteConversation(convoId: conversation.id)
      await MainActor.run {
        isProcessing = false
        dismiss()
      }
    }
  }
  
  private func markAsRead() {
    Task {
      isProcessing = true
      await appState.chatManager.markConversationAsRead(convoId: conversation.id)
      await MainActor.run {
        isProcessing = false
        dismiss()
      }
    }
  }
  
  private func leaveConversation() {
    Task {
      isProcessing = true
      await appState.chatManager.leaveConversation(convoId: conversation.id)
      await MainActor.run {
        isProcessing = false
        dismiss()
      }
    }
  }
}

/// View for displaying conversation information
struct ConversationInfoRow: View {
  @Environment(AppState.self) private var appState
  let conversation: ChatBskyConvoDefs.ConvoView
  
  private var otherMembers: [ChatBskyActorDefs.ProfileViewBasic] {
    conversation.members.filter { $0.did.didString() != appState.userDID }
  }
  
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Members
      VStack(alignment: .leading, spacing: 8) {
        Text("Members")
          .appFont(AppTextRole.headline)
        
        ForEach(otherMembers, id: \.did) { member in
          HStack {
            ChatProfileAvatarView(profile: member, size: 32)
            
            VStack(alignment: .leading, spacing: 2) {
              Text(member.displayName ?? "Unknown")
                                .appFont(AppTextRole.body)
                .fontWeight(.medium)
              Text("@\(member.handle.description)")
                .appFont(AppTextRole.caption)
                .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if member.chatDisabled == true {
              Text("Chat Disabled")
                .appFont(AppTextRole.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.2))
                .foregroundColor(.red)
                .clipShape(Capsule())
            }
          }
        }
      }
      
      Divider()
      
      // Conversation details
      VStack(alignment: .leading, spacing: 8) {
        Text("Details")
          .appFont(AppTextRole.headline)
        
        DetailRow(label: "Conversation ID", value: conversation.id)
        DetailRow(label: "Revision", value: conversation.rev)
        DetailRow(label: "Unread Messages", value: "\(conversation.unreadCount)")
        DetailRow(label: "Status", value: conversation.muted ? "Muted" : "Active")
      }
    }
    .padding(.vertical, 8)
  }
}

/// Helper view for displaying detail rows
private struct DetailRow: View {
  let label: String
  let value: String
  
  var body: some View {
    HStack {
      Text(label)
        .foregroundColor(.secondary)
      Spacer()
      Text(value)
        .fontWeight(.medium)
        .multilineTextAlignment(.trailing)
    }
    .appFont(AppTextRole.caption)
  }
}

/// View for accepting conversation invitations
struct ConversationInvitationView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  
  let conversation: ChatBskyConvoDefs.ConvoView
  
  @State private var isAccepting = false
  @State private var isDeclining = false
  @State private var errorMessage: String?
  
  private var otherMembers: [ChatBskyActorDefs.ProfileViewBasic] {
    conversation.members.filter { $0.did.didString() != appState.userDID }
  }
  
  var body: some View {
    VStack(spacing: 24) {
      // Header
      VStack(spacing: 12) {
        Image(systemName: "message.circle")
          .appFont(size: 64)
          .foregroundColor(.blue)
        
        Text("New Conversation")
          .appFont(AppTextRole.title2)
          .fontWeight(.semibold)
        
        if otherMembers.count == 1 {
          Text("@\(otherMembers.first?.handle.description ?? "unknown") wants to start a conversation with you")
            .multilineTextAlignment(.center)
            .foregroundColor(.secondary)
        } else {
          Text("\(otherMembers.count) people want to start a group conversation with you")
            .multilineTextAlignment(.center)
            .foregroundColor(.secondary)
        }
      }
      
      // Members preview
      VStack(alignment: .leading, spacing: 12) {
        Text("Participants")
          .appFont(AppTextRole.headline)
        
        ForEach(otherMembers.prefix(3), id: \.did) { member in
          HStack {
            ChatProfileAvatarView(profile: member, size: 40)
            
            VStack(alignment: .leading, spacing: 2) {
              Text(member.displayName ?? "Unknown")
                                .appFont(AppTextRole.body)
                .fontWeight(.medium)
              Text("@\(member.handle.description)")
                .appFont(AppTextRole.caption)
                .foregroundColor(.secondary)
            }
            
            Spacer()
          }
        }
        
        if otherMembers.count > 3 {
          Text("and \(otherMembers.count - 3) more...")
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
        }
      }
      .padding()
      .background(Color.gray.opacity(0.1))
      .clipShape(RoundedRectangle(cornerRadius: 12))
      
      Spacer()
      
      // Action buttons
      VStack(spacing: 12) {
        Button {
          acceptInvitation()
        } label: {
          HStack {
            if isAccepting {
              ProgressView()
                .scaleEffect(0.8)
            }
            Text("Accept")
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isAccepting || isDeclining)
        
        Button {
          declineInvitation()
        } label: {
          HStack {
            if isDeclining {
              ProgressView()
                .scaleEffect(0.8)
            }
            Text("Decline")
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(isAccepting || isDeclining)
      }
    }
    .padding()
    .alert("Error", isPresented: .constant(errorMessage != nil)) {
      Button("OK") {
        errorMessage = nil
      }
    } message: {
      Text(errorMessage ?? "An unknown error occurred")
    }
  }
  
  private func acceptInvitation() {
    Task {
      isAccepting = true
      let success = await appState.chatManager.acceptConversation(convoId: conversation.id)
      await MainActor.run {
        isAccepting = false
        if success {
          dismiss()
        } else {
          errorMessage = "Failed to accept conversation invitation"
        }
      }
    }
  }
  
  private func declineInvitation() {
    Task {
      isDeclining = true
      await appState.chatManager.leaveConversation(convoId: conversation.id)
      await MainActor.run {
        isDeclining = false
        dismiss()
      }
    }
  }
}

#Preview {
    @Previewable @Environment(AppState.self) var appState
  // Mock conversation for preview
  let mockConversation = ChatBskyConvoDefs.ConvoView(
    id: "mock-convo-id",
    rev: "1",
    members: [],
    lastMessage: nil,
    lastReaction: nil,
    muted: false,
    status: "accepted",
    unreadCount: 5
  )
  
  ConversationManagementView(conversation: mockConversation)
    .environment(AppStateManager.shared)
}

#endif
