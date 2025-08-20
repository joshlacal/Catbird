import SwiftUI
import Petrel
#if os(iOS)


// MARK: - Toolbar and Context Menu Components

/// Toolbar menu for the main chat list
struct ChatToolbarMenu: View {
  @Environment(AppState.self) private var appState
  @State private var showingSettings = false
  @State private var showingBatchMessage = false
  
  var body: some View {
    Menu {
      Button {
        showingBatchMessage = true
      } label: {
        Label("Send to Multiple", systemImage: "envelope.badge")
      }
      
      Button {
        Task {
          await appState.chatManager.markAllConversationsAsRead()
        }
      } label: {
        Label("Mark All as Read", systemImage: "envelope.open")
      }
      
      Divider()
      
      Button {
        showingSettings = true
      } label: {
        Label("Chat Settings", systemImage: "gear")
      }
    } label: {
      Image(systemName: "ellipsis.circle")
    }
    .sheet(isPresented: $showingSettings) {
      ChatSettingsView()
    }
    .sheet(isPresented: $showingBatchMessage) {
      BatchMessageView()
    }
  }
}

/// Toolbar menu for individual conversations
struct ConversationToolbarMenu: View {
  @Environment(AppState.self) private var appState
  let conversation: ChatBskyConvoDefs.ConvoView?
  @State private var showingSettings = false
  
  var body: some View {
    Menu {
      if let convo = conversation {
        Button {
          Task {
            await appState.chatManager.markConversationAsRead(convoId: convo.id)
          }
        } label: {
          Label("Mark as Read", systemImage: "envelope.open")
        }
        .disabled(convo.unreadCount == 0)
        
        Button {
          if convo.muted {
            Task { await appState.chatManager.unmuteConversation(convoId: convo.id) }
          } else {
            Task { await appState.chatManager.muteConversation(convoId: convo.id) }
          }
        } label: {
          Label(convo.muted ? "Unmute" : "Mute", systemImage: convo.muted ? "bell" : "bell.slash")
        }
        
        Divider()
        
        Button {
          showingSettings = true
        } label: {
          Label("Conversation Info", systemImage: "info.circle")
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
    }
    .sheet(isPresented: $showingSettings) {
      if let convo = conversation {
        ConversationManagementView(conversation: convo)
      }
    }
  }
}

/// Context menu for conversation rows
struct ConversationContextMenu: View {
  @Environment(AppState.self) private var appState
  let conversation: ChatBskyConvoDefs.ConvoView
  @State private var showingSettings = false
  @State private var showingDeleteAlert = false
  
  var body: some View {
    Group {
      Button {
        Task {
          await appState.chatManager.markConversationAsRead(convoId: conversation.id)
        }
      } label: {
        Label("Mark as Read", systemImage: "envelope.open")
      }
      .disabled(conversation.unreadCount == 0)
      
      Button {
        if conversation.muted {
          Task { await appState.chatManager.unmuteConversation(convoId: conversation.id) }
        } else {
          Task { await appState.chatManager.muteConversation(convoId: conversation.id) }
        }
      } label: {
        Label(conversation.muted ? "Unmute" : "Mute", systemImage: conversation.muted ? "bell" : "bell.slash")
      }
      
      Divider()
      
      Button {
        showingSettings = true
      } label: {
        Label("Conversation Info", systemImage: "info.circle")
      }
      
      Button(role: .destructive) {
        showingDeleteAlert = true
      } label: {
        Label("Leave Conversation", systemImage: "trash")
      }
    }
    .sheet(isPresented: $showingSettings) {
      ConversationManagementView(conversation: conversation)
    }
    .alert("Leave Conversation", isPresented: $showingDeleteAlert) {
      Button("Cancel", role: .cancel) { }
      Button("Leave", role: .destructive) {
        Task {
          await appState.chatManager.leaveConversation(convoId: conversation.id)
        }
      }
    } message: {
      Text("Are you sure you want to leave this conversation?")
    }
  }
}

/// Button to show message requests with badge for unread count
struct MessageRequestsButton: View {
  @Environment(AppState.self) private var appState
  @State private var showingRequests = false
  
  private var requestsCount: Int {
    appState.chatManager.messageRequestsCount
  }
  
  private var unreadRequestsCount: Int {
    appState.chatManager.unreadMessageRequestsCount
  }
  
  var body: some View {
    Button {
      showingRequests = true
    } label: {
      ZStack {
        Image(systemName: "tray")
          .appBody()
        
        if requestsCount > 0 {
          // Badge for total requests count
          Text("\(requestsCount)")
            .appCaption()
            .fontWeight(.bold)
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(unreadRequestsCount > 0 ? Color.red : Color.blue)
            .clipShape(Capsule())
            .offset(x: 12, y: -8)
        }
      }
    }
    .sheet(isPresented: $showingRequests) {
      MessageRequestsView()
    }
  }
}#endif
