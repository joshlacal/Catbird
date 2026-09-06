import SwiftUI
import Petrel
import CatbirdMLSCore


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

/// Context menu plus its confirmation alerts/sheet for conversation rows.
///
/// A `ViewModifier` on purpose: SwiftUI tears down `.contextMenu` content the
/// moment a menu item is tapped, so state and `.alert`/`.sheet` modifiers
/// living inside the menu content can never present. Attaching them to the
/// row keeps the presentation state in a hierarchy that survives dismissal.
struct ConversationContextMenu: ViewModifier {
  @Environment(AppState.self) private var appState
  let conversation: ChatBskyConvoDefs.ConvoView
  @State private var showingSettings = false
  @State private var showingDeleteAlert = false
  @State private var showingOwnerLeaveAlert = false

  /// Group owners can't leave until the group is locked (`OwnerCannotLeave`),
  /// so they get the lock-then-leave confirmation instead.
  private var isOwnedGroup: Bool {
    conversation.isOwnedGroupConversation(currentUserDID: appState.userDID)
  }

  func body(content: Content) -> some View {
    content
      .contextMenu {
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
          if isOwnedGroup {
            showingOwnerLeaveAlert = true
          } else {
            showingDeleteAlert = true
          }
        } label: {
          Label(isOwnedGroup ? "Lock & Leave Group" : "Leave Conversation", systemImage: "trash")
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
      .alert("Lock & Leave Group", isPresented: $showingOwnerLeaveAlert) {
        Button("Cancel", role: .cancel) { }
        Button("Lock & Leave", role: .destructive) {
          Task {
            await appState.chatManager.lockAndLeaveConversation(convoId: conversation.id)
          }
        }
      } message: {
        Text("As the owner, you must lock this group before leaving. Your messages will be deleted for you, but not for the other participants.")
      }
  }
}

/// Button to show message requests with badge for unread count
struct MessageRequestsButton: View {
  @Environment(AppState.self) private var appState
  @State private var requestProvider: MessageRequestProvider?
  @State private var pendingCatbirdCount = 0
  @State private var countGeneration = UUID()
  
  private var requestsCount: Int {
    appState.chatManager.messageRequestsCount + pendingCatbirdCount
  }
  
  private var unreadRequestsCount: Int {
    appState.chatManager.unreadMessageRequestsCount
  }
  
  var body: some View {
    Button {
      Task { @MainActor in
        let userDID = appState.userDID
        await refreshCatbirdCount()
        guard !Task.isCancelled, appState.userDID == userDID else { return }
        requestProvider = .initial(pendingCatbirdCount: pendingCatbirdCount)
      }
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
    .accessibilityLabel(requestsCount == 0 ? "Message requests" : "Message requests, \(requestsCount) pending")
    .modifier(MessageRequestSheet(provider: $requestProvider, onDismiss: {
      Task { await refreshCatbirdCount() }
    }, sheetContent: { provider in
      UnifiedMessageRequestsView(initialProvider: provider)
    }))
    .task(id: appState.userDID) {
      requestProvider = nil
      pendingCatbirdCount = 0
      let bus = appState.stateInvalidationBus
      let stream = AsyncStream<Void> { continuation in
        let observer = MessageRequestsChangeObserver(continuation: continuation)
        bus.subscribe(observer)
        continuation.onTermination = { _ in bus.unsubscribe(observer) }
      }
      await refreshCatbirdCount()
      for await _ in stream {
        guard !Task.isCancelled else { return }
        await refreshCatbirdCount()
      }
    }
  }

  @MainActor
  private func refreshCatbirdCount() async {
    let generation = UUID()
    countGeneration = generation
    let userDID = appState.userDID
    guard let manager = await appState.getMLSConversationManager(),
          manager.currentUserDID == userDID, !manager.isShuttingDown else { return }
    do {
      let count = try await manager.fetchPendingRequestConversations().count
      guard !Task.isCancelled, countGeneration == generation, appState.userDID == userDID,
            appState.mlsConversationManager === manager, !manager.isShuttingDown else { return }
      pendingCatbirdCount = count
    } catch {
      // Keep the last known badge; the Inbox shows actionable load failures.
    }
  }
}

private final class MessageRequestsChangeObserver: StateInvalidationSubscriber {
  let continuation: AsyncStream<Void>.Continuation
  init(continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
  func isInterestedIn(_ event: StateInvalidationEvent) -> Bool {
    if case .mlsConversationListChanged = event { return true }
    return false
  }
  func handleStateInvalidation(_ event: StateInvalidationEvent) async { continuation.yield() }
}

#Preview("ChatToolbarMenu") {
  NavigationStack {
    Text("Chat")
      .toolbar {
        #if os(iOS)
        ToolbarItem(placement: .topBarTrailing) {
          ChatToolbarMenu()
        }
        #else
        ToolbarItem(placement: .automatic) {
          ChatToolbarMenu()
        }
        #endif
      }
  }
  .previewWithAuthenticatedState()
}
