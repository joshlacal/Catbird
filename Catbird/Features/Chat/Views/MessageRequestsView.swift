import OSLog
import SwiftUI
import Petrel

#if os(iOS)
/// View for managing message requests (conversations with status "request")
struct MessageRequestsView: View {
  @Environment(AppState.self) private var appState
  @State private var selectedFilter: RequestFilter = .all
  @State private var showingBulkActions = false
  
  private let logger = Logger(subsystem: "blue.catbird", category: "MessageRequestsView")
  
  enum RequestFilter: String, CaseIterable {
    case all = "All"
    case unread = "Unread"
    
    var systemImage: String {
      switch self {
      case .all: return "tray"
      case .unread: return "tray.fill"
      }
    }
  }
  
  private var filteredRequests: [ChatBskyConvoDefs.ConvoView] {
    let requests = appState.chatManager.messageRequests
    switch selectedFilter {
    case .all:
      return requests
    case .unread:
      return requests.filter { $0.unreadCount > 0 }
    }
  }
  
  var body: some View {
    NavigationView {
      VStack(spacing: 0) {
        // Filter picker
        if !appState.chatManager.messageRequests.isEmpty {
          FilterPickerView(selectedFilter: $selectedFilter)
            .padding(.horizontal)
            .padding(.top, 8)
        }
        
        // Main content
        if filteredRequests.isEmpty {
          EmptyRequestsView(filter: selectedFilter)
        } else {
          RequestsListView(
            requests: filteredRequests,
            onAccept: { request in
              acceptRequest(request)
            },
            onDecline: { request in
              declineRequest(request)
            }
          )
        }
      }
      .navigationTitle("Message Requests")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          RequestsToolbarMenu(
            hasRequests: !appState.chatManager.messageRequests.isEmpty,
            onAcceptAll: acceptAllRequests,
            onDeclineAll: declineAllRequests
          )
        }
      }
      .refreshable {
        await loadRequests()
      }
      .onAppear {
        Task {
          await loadRequests()
        }
      }
    }
  }
  
  private func loadRequests() async {
    await appState.chatManager.loadMessageRequests(refresh: true)
  }
  
  private func acceptRequest(_ request: ChatBskyConvoDefs.ConvoView) {
    Task {
      let success = await appState.chatManager.acceptMessageRequest(convoId: request.id)
      if success {
        logger.debug("Successfully accepted message request: \(request.id)")
      } else {
        logger.error("Failed to accept message request: \(request.id)")
      }
    }
  }
  
  private func declineRequest(_ request: ChatBskyConvoDefs.ConvoView) {
    Task {
      let success = await appState.chatManager.declineMessageRequest(convoId: request.id)
      if success {
        logger.debug("Successfully declined message request: \(request.id)")
      } else {
        logger.error("Failed to decline message request: \(request.id)")
      }
    }
  }
  
  private func acceptAllRequests() {
    Task {
      for request in filteredRequests {
        await appState.chatManager.acceptMessageRequest(convoId: request.id)
      }
    }
  }
  
  private func declineAllRequests() {
    Task {
      for request in filteredRequests {
        await appState.chatManager.declineMessageRequest(convoId: request.id)
      }
    }
  }
}

/// Filter picker for requests
struct FilterPickerView: View {
  @Binding var selectedFilter: MessageRequestsView.RequestFilter
  
  var body: some View {
    Picker("Filter", selection: $selectedFilter) {
      ForEach(MessageRequestsView.RequestFilter.allCases, id: \.self) { filter in
        Text(filter.rawValue)
          .tag(filter)
      }
    }
    .pickerStyle(.segmented)
  }
}

/// Main list of message requests
struct RequestsListView: View {
  let requests: [ChatBskyConvoDefs.ConvoView]
  let onAccept: (ChatBskyConvoDefs.ConvoView) -> Void
  let onDecline: (ChatBskyConvoDefs.ConvoView) -> Void
  
  var body: some View {
    List {
      ForEach(requests) { request in
        MessageRequestRow(
          request: request,
          onAccept: { onAccept(request) },
          onDecline: { onDecline(request) }
        )
        .listRowSeparator(.visible)
      }
    }
    .listStyle(.plain)
  }
}

/// Individual message request row
struct MessageRequestRow: View {
  @Environment(AppState.self) private var appState
  let request: ChatBskyConvoDefs.ConvoView
  let onAccept: () -> Void
  let onDecline: () -> Void
  
  @State private var isProcessing = false
  @State private var showingPreview = false
  
  private var otherMembers: [ChatBskyActorDefs.ProfileViewBasic] {
    request.members.filter { $0.did.didString() != appState.currentUserDID }
  }
  
  private var primaryMember: ChatBskyActorDefs.ProfileViewBasic? {
    otherMembers.first
  }
  
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Header with profile info
      HStack {
        // Profile picture
        ChatProfileAvatarView(profile: primaryMember, size: 48)
        
        VStack(alignment: .leading, spacing: 4) {
          // Name and handle
          HStack {
            Text(primaryMember?.displayName ?? "Unknown User")
              .appFont(AppTextRole.headline)
              .fontWeight(.semibold)
            
            if request.unreadCount > 0 {
              Circle()
                .fill(Color.blue)
                .frame(width: 8, height: 8)
            }
          }
          
          Text("@\(primaryMember?.handle.description ?? "unknown")")
            .appFont(AppTextRole.subheadline)
            .foregroundColor(.secondary)
          
          // Additional members for group chats
          if otherMembers.count > 1 {
            Text("and \(otherMembers.count - 1) other\(otherMembers.count > 2 ? "s" : "")")
              .appFont(AppTextRole.caption)
              .foregroundColor(.secondary)
          }
        }
        
        Spacer()
        
        // Timestamp
        VStack(alignment: .trailing, spacing: 4) {
          Text("Rev: \(request.rev)")
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
          
          if request.unreadCount > 0 {
            Text("\(request.unreadCount)")
              .appFont(AppTextRole.caption2)
              .fontWeight(.bold)
              .foregroundColor(.white)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.blue)
              .clipShape(Capsule())
          }
        }
      }
      
      // Preview message if available
      if let lastMessage = request.lastMessage {
        MessagePreviewView(lastMessage: lastMessage)
          .padding(.leading, 56) // Align with text above
      }
      
      // Action buttons
      HStack(spacing: 8) {
        Button {
          isProcessing = true
          onDecline()
          isProcessing = false
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "xmark")
              .imageScale(.small)
            Text("Decline")
              .lineLimit(1)
              .minimumScaleFactor(0.8)
          }
          .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .disabled(isProcessing)
        
        Button {
          showingPreview = true
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "eye")
              .imageScale(.small)
            Text("Preview")
              .lineLimit(1)
              .minimumScaleFactor(0.8)
          }
          .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .disabled(isProcessing)
        
        Button {
          isProcessing = true
          onAccept()
          isProcessing = false
        } label: {
          HStack(spacing: 4) {
            if isProcessing {
              ProgressView()
                .scaleEffect(0.8)
            } else {
              Image(systemName: "checkmark")
                .imageScale(.small)
            }
            Text("Accept")
              .lineLimit(1)
              .minimumScaleFactor(0.8)
          }
          .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isProcessing)
      }
      .padding(.leading, 56) // Align with text above
    }
    .padding(.vertical, 8)
    .sheet(isPresented: $showingPreview) {
      MessageRequestPreviewView(request: request)
    }
  }
}

/// Preview of the last message in a request
struct MessagePreviewView: View {
  let lastMessage: ChatBskyConvoDefs.ConvoViewLastMessageUnion
  
  var body: some View {
    Group {
      switch lastMessage {
      case .chatBskyConvoDefsMessageView(let messageView):
        VStack(alignment: .leading, spacing: 4) {
          Text("Message:")
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
          
          Text(messageView.text)
                            .appFont(AppTextRole.body)
            .lineLimit(nil)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.gray.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        
      case .chatBskyConvoDefsDeletedMessageView:
        HStack {
          Image(systemName: "trash")
            .foregroundColor(.secondary)
          Text("Message was deleted")
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
            .italic()
        }
        
      case .unexpected:
        Text("Unsupported message type")
          .appFont(AppTextRole.caption)
          .foregroundColor(.secondary)
          .italic()
      }
    }
  }
}

/// Empty state for when there are no requests
struct EmptyRequestsView: View {
  let filter: MessageRequestsView.RequestFilter
  
  var body: some View {
    ContentUnavailableView {
      Label("No Message Requests", systemImage: "tray")
    } description: {
      switch filter {
      case .all:
        Text("You don't have any pending message requests.")
      case .unread:
        Text("You don't have any unread message requests.")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Toolbar menu for bulk actions
struct RequestsToolbarMenu: View {
  let hasRequests: Bool
  let onAcceptAll: () -> Void
  let onDeclineAll: () -> Void
  
  @State private var showingAcceptAllAlert = false
  @State private var showingDeclineAllAlert = false
  
  var body: some View {
    Menu {
      Button {
        showingAcceptAllAlert = true
      } label: {
        Label("Accept All", systemImage: "checkmark.circle")
      }
      .disabled(!hasRequests)
      
      Button {
        showingDeclineAllAlert = true
      } label: {
        Label("Decline All", systemImage: "xmark.circle")
      }
      .disabled(!hasRequests)
    } label: {
      Image(systemName: "ellipsis.circle")
    }
    .alert("Accept All Requests", isPresented: $showingAcceptAllAlert) {
      Button("Cancel", role: .cancel) { }
      Button("Accept All") {
        onAcceptAll()
      }
    } message: {
      Text("Are you sure you want to accept all message requests?")
    }
    .alert("Decline All Requests", isPresented: $showingDeclineAllAlert) {
      Button("Cancel", role: .cancel) { }
      Button("Decline All", role: .destructive) {
        onDeclineAll()
      }
    } message: {
      Text("Are you sure you want to decline all message requests? This action cannot be undone.")
    }
  }
}

/// Full preview of a message request
struct MessageRequestPreviewView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  
  let request: ChatBskyConvoDefs.ConvoView
  
  @State private var isProcessing = false
  
  private var otherMembers: [ChatBskyActorDefs.ProfileViewBasic] {
    request.members.filter { $0.did.didString() != appState.currentUserDID }
  }
  
  var body: some View {
    NavigationView {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          // Header
          VStack(spacing: 16) {
            // Profile pictures
            HStack(spacing: -8) {
              ForEach(otherMembers.prefix(3), id: \.did) { member in
                ChatProfileAvatarView(profile: member, size: 60)
                  .overlay(
                    Circle()
                      .stroke(Color.systemBackground, lineWidth: 2)
                  )
              }
              
              if otherMembers.count > 3 {
                ZStack {
                  Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 60, height: 60)
                  
                  Text("+\(otherMembers.count - 3)")
                    .appFont(AppTextRole.headline)
                    .fontWeight(.medium)
                }
                .overlay(
                  Circle()
                    .stroke(Color.systemBackground, lineWidth: 2)
                )
              }
            }
            
            Text("Message Request")
              .appFont(AppTextRole.title2)
              .fontWeight(.semibold)
            
            if otherMembers.count == 1 {
              Text("@\(otherMembers.first?.handle.description ?? "unknown") wants to send you a message")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            } else {
              Text("\(otherMembers.count) people want to start a group conversation with you")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            }
          }
          
          // Members list
          VStack(alignment: .leading, spacing: 12) {
            Text("Participants")
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
          .padding()
          .background(Color.gray.opacity(0.1))
          .clipShape(RoundedRectangle(cornerRadius: 12))
          
          // Message preview if available
          if let lastMessage = request.lastMessage {
            VStack(alignment: .leading, spacing: 12) {
              Text("Last Message")
                .appFont(AppTextRole.headline)
              
              MessagePreviewView(lastMessage: lastMessage)
            }
          }
          
          Spacer(minLength: 20)
          
          // Action buttons
          VStack(spacing: 12) {
            Button {
              acceptRequest()
            } label: {
              HStack {
                if isProcessing {
                  ProgressView()
                    .scaleEffect(0.8)
                } else {
                  Image(systemName: "checkmark")
                }
                Text("Accept Request")
              }
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isProcessing)
            
            Button {
              declineRequest()
            } label: {
              HStack {
                Image(systemName: "xmark")
                Text("Decline Request")
              }
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isProcessing)
          }
        }
        .padding()
      }
      .navigationTitle("Request Preview")
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
    }
  }
  
  private func acceptRequest() {
    Task {
      isProcessing = true
      let success = await appState.chatManager.acceptMessageRequest(convoId: request.id)
      await MainActor.run {
        isProcessing = false
        if success {
          dismiss()
        }
      }
    }
  }
  
  private func declineRequest() {
    Task {
      isProcessing = true
      await appState.chatManager.declineMessageRequest(convoId: request.id)
      await MainActor.run {
        isProcessing = false
        dismiss()
      }
    }
  }
}

#Preview {
  MessageRequestsView()
    .environment(AppState.shared)
}

#endif
