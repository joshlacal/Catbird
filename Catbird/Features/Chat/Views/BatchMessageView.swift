import SwiftUI
import OSLog
import Petrel

#if os(iOS)

struct BatchMessageView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  
  @State private var messageText = ""
  @State private var selectedConversations: Set<String> = []
  @State private var searchText = ""
  @State private var isSending = false
  @State private var showingError = false
  @State private var errorMessage = ""
  @State private var successCount = 0
  @State private var showingSuccess = false
  
  private let logger = Logger(subsystem: "blue.catbird", category: "BatchMessage")
  
  private var filteredConversations: [ChatBskyConvoDefs.ConvoView] {
    let conversations = appState.chatManager.acceptedConversations
    
    if searchText.isEmpty {
      return conversations
    }
    
    return conversations.filter { convo in
      convo.members.contains { member in
        let nameMatch = member.displayName?.localizedCaseInsensitiveContains(searchText) ?? false
        let handleMatch = member.handle.description.localizedCaseInsensitiveContains(searchText)
        return nameMatch || handleMatch
      }
    }
  }
  
  var body: some View {
    NavigationView {
      VStack(spacing: 0) {
        // Message input
        VStack(alignment: .leading, spacing: 8) {
          Text("Message")
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
          
          TextEditor(text: $messageText)
            .frame(minHeight: 80)
            .padding(8)
            .background(Color.gray.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding()
        
        Divider()
        
        // Recipients selection
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Recipients")
              .appFont(AppTextRole.caption)
              .foregroundColor(.secondary)
            
            Spacer()
            
            if !selectedConversations.isEmpty {
              Text("\(selectedConversations.count) selected")
                .appFont(AppTextRole.caption)
                .foregroundColor(.blue)
            }
          }
          .padding(.horizontal)
          .padding(.top, 8)
          
          // Search bar
          HStack {
            Image(systemName: "magnifyingglass")
              .foregroundColor(.secondary)
            TextField("Search conversations", text: $searchText)
            if !searchText.isEmpty {
              Button {
                searchText = ""
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundColor(.secondary)
              }
            }
          }
          .padding(8)
          .background(Color.gray.opacity(0.1))
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .padding(.horizontal)
          
          // Conversation list
          List {
            ForEach(filteredConversations) { convo in
              ConversationSelectionRow(
                conversation: convo,
                isSelected: selectedConversations.contains(convo.id),
                currentUserDID: appState.currentUserDID ?? ""
              ) {
                if selectedConversations.contains(convo.id) {
                  selectedConversations.remove(convo.id)
                } else {
                  selectedConversations.insert(convo.id)
                }
              }
            }
          }
          .listStyle(.plain)
        }
      }
      .navigationTitle("Send to Multiple")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", systemImage: "xmark") {
            dismiss()
          }
          .disabled(isSending)
        }
        
        ToolbarItem(placement: .primaryAction) {
          Button("Send") {
            sendBatchMessages()
          }
          .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedConversations.isEmpty || isSending)
        }
      }
      .disabled(isSending)
      .overlay {
        if isSending {
          ProgressView("Sending messages...")
            .padding()
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
      }
      .alert("Error", isPresented: $showingError) {
        Button("OK") { }
      } message: {
        Text(errorMessage)
      }
      .alert("Messages Sent", isPresented: $showingSuccess) {
        Button("OK") {
          dismiss()
        }
      } message: {
        Text("Successfully sent message to \(successCount) conversation\(successCount == 1 ? "" : "s")")
      }
    }
  }
  
  private func sendBatchMessages() {
    Task {
      isSending = true
      defer { isSending = false }
      
      let items = selectedConversations.map { convoId in
        (convoId: convoId, text: messageText)
      }
      
      let results = await appState.chatManager.sendMessageBatch(items: items)
      
      let successfulSends = results.compactMap { $0 }.count
      
      await MainActor.run {
        if successfulSends == 0 {
          errorMessage = "Failed to send messages"
          showingError = true
        } else if successfulSends < items.count {
          errorMessage = "Sent to \(successfulSends) of \(items.count) conversations. Some messages failed."
          showingError = true
        } else {
          successCount = successfulSends
          showingSuccess = true
        }
      }
    }
  }
}

// MARK: - Conversation Selection Row

struct ConversationSelectionRow: View {
  let conversation: ChatBskyConvoDefs.ConvoView
  let isSelected: Bool
  let currentUserDID: String
  let onTap: () -> Void
  
  private var otherMember: ChatBskyActorDefs.ProfileViewBasic? {
    conversation.members.first { $0.did.didString() != currentUserDID }
  }
  
  var body: some View {
    Button {
      onTap()
    } label: {
      HStack(spacing: 12) {
        // Checkbox
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundColor(isSelected ? .blue : .gray)
          .appFont(AppTextRole.title3)
        
        // Avatar
        ChatProfileAvatarView(profile: otherMember, size: 40)
        
        // Name and handle
        VStack(alignment: .leading, spacing: 2) {
          Text(otherMember?.displayName ?? "Unknown")
            .appFont(AppTextRole.headline)
            .foregroundColor(.primary)
          
          Text("@\(otherMember?.handle.description ?? "unknown")")
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
        }
        
        Spacer()
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
#endif
