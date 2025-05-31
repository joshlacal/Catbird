import ExyteChat
import MCEmojiPicker
import Nuke
import NukeUI
import OSLog
import Petrel
import SwiftUI

// MARK: - Chat Tab View

struct ChatTabView: View {
  @Environment(AppState.self) private var appState
  @Binding var selectedTab: Int
  @Binding var lastTappedTab: Int?
  @State private var selectedConvoId: String?  // Track navigation state locally if needed
  @State private var searchText = ""
  fileprivate let logger = Logger(subsystem: "blue.catbird", category: "ChatUI")

  // Ensure NavigationManager path binding uses the correct tab index (4)
  private var chatNavigationPath: Binding<NavigationPath> {
    appState.navigationManager.pathBinding(for: 4)
  }

  var body: some View {
    ZStack {
      NavigationStack(path: chatNavigationPath) {
        ConversationListView(
          // Pass the ChatManager instance directly
          chatManager: appState.chatManager,
          searchText: searchText,
          onSelectConvo: { id in
            selectedConvoId = id  // Keep track if needed
            // Use the correct tab index (4) for navigation
            appState.navigationManager.navigate(
              to: .conversation(id),
              in: 4  // Explicitly navigate within the chat tab
            )
          },
          onSelectSearchResult: { profile in
            startConversation(with: profile)
          }
        )
        .navigationTitle("Direct Messages")
        .searchable(text: $searchText, prompt: "Search")
        .onChange(of: searchText) { _, newValue in
          Task {
            await MainActor.run {
              appState.chatManager.searchLocal(searchTerm: newValue, currentUserDID: appState.currentUserDID)
            }
          }
        }
        .toolbar {
          ToolbarItem(placement: .navigationBarLeading) {
            MessageRequestsButton()
          }
          
          ToolbarItem(placement: .navigationBarTrailing) {
            ChatToolbarMenu()
          }
        }
        .navigationDestination(for: NavigationDestination.self) { destination in
          // Ensure NavigationHandler uses the correct path and tab index
          NavigationHandler.viewForDestination(
            destination,
            path: chatNavigationPath,  
            appState: appState,
            selectedTab: $selectedTab  
          )
        }
      }
      .onAppear {
        // Load conversations when the tab appears
        Task {
          // Check if conversations are already loaded or loading to avoid redundant calls
          if appState.chatManager.acceptedConversations.isEmpty && !appState.chatManager.loadingConversations {
            logger.debug("ChatTabView appeared, loading conversations.")
            await appState.chatManager.loadConversations(refresh: true)
          } else {
            logger.debug("ChatTabView appeared, conversations already loaded or loading.")
          }
        }
        // Start polling for conversation updates
        appState.chatManager.startConversationsPolling()
      }
      .onDisappear {
        // Stop polling when leaving the chat tab
        appState.chatManager.stopConversationsPolling()
      }
      // Handle potential errors from ChatManager
      .alert(
        isPresented: Binding(
          get: { appState.chatManager.errorState != nil },
          set: { _ in appState.chatManager.errorState = nil }  // Clear error on dismiss
        )
      ) {
        Alert(
          title: Text("Chat Error"),
          message: Text(
            appState.chatManager.errorState?.localizedDescription ?? "An unknown error occurred."),
          dismissButton: .default(Text("OK"))
        )
      }

//      // Add the ChatFAB with a new message action, but only if we're not already in a conversation
//      if chatNavigationPath.wrappedValue.isEmpty {
//        ChatFAB(newMessageAction: {
//          showingNewMessageSheet = true
//        })
//        .offset(y: -80)  // Match the offset of the main FAB
//      }
    }
  }

  // Search is now handled by ChatManager's searchLocal method

  private func startConversation(with profile: ProfileDisplayable) {
    Task {
      logger.debug("Starting conversation with user: \(profile.handle.description)")

      if let convoId = await appState.chatManager.startConversationWith(userDID: profile.did.didString()) {
        logger.debug("Successfully started conversation with ID: \(convoId)")

        await MainActor.run {
          // Navigate to the conversation
          appState.navigationManager.navigate(
            to: .conversation(convoId),
            in: 4  // Chat tab index
          )
        }
      } else {
        logger.error("Failed to start conversation with user: \(profile.handle.description)")
      }
    }
  }
}

// MARK: - Conversation List View

struct ConversationListView: View {
  @Environment(AppState.self) private var appState
  @State var chatManager: ChatManager
  var searchText: String = ""
  var onSelectConvo: (String) -> Void
  var onSelectSearchResult: ((ProfileDisplayable) -> Void)?

  private let logger = Logger(subsystem: "blue.catbird", category: "ConversationListView")

  var body: some View {
    List {
      if !searchText.isEmpty {
        searchResultsContent
      } else {
        conversationListContent
      }
    }
    .listStyle(.plain)
    .refreshable {
      logger.debug("Pull-to-refresh triggered on conversation list.")
      await chatManager.loadConversations(refresh: true)
    }
    .overlay {
      loadingOverlay
    }
  }
  
  // MARK: - View Components
  
  @ViewBuilder
  private var searchResultsContent: some View {
    if !chatManager.filteredProfiles.isEmpty {
      contactsSection
    }
    
    if !chatManager.filteredConversations.isEmpty {
      filteredConversationsSection
    }
    
    if chatManager.filteredProfiles.isEmpty && chatManager.filteredConversations.isEmpty && !searchText.isEmpty {
      noResultsMessage
    }
  }
  
  @ViewBuilder
  private var conversationListContent: some View {
    ForEach(chatManager.acceptedConversations) { convo in
      conversationRowView(for: convo, showMuteOption: true)
    }
    
    paginationContent
    emptyStateContent
  }
  
  @ViewBuilder
  private var contactsSection: some View {
    Section("Contacts") {
      ForEach(chatManager.filteredProfiles, id: \.did) { profileBasic in
        contactRowButton(for: profileBasic)
      }
    }
  }
  
  @ViewBuilder
  private var filteredConversationsSection: some View {
    Section("Conversations") {
      ForEach(chatManager.filteredConversations) { convo in
        conversationRowView(for: convo, showMuteOption: false)
      }
    }
  }
  
  @ViewBuilder
  private var noResultsMessage: some View {
    Text("No matching contacts or conversations")
      .foregroundColor(.secondary)
      .frame(maxWidth: .infinity, alignment: .center)
      .listRowSeparator(.hidden)
      .padding()
  }
  
  @ViewBuilder
  private var paginationContent: some View {
    let shouldShowLoadMore = !chatManager.acceptedConversations.isEmpty && 
                            chatManager.conversationsCursor != nil && 
                            !chatManager.loadingConversations
    
    let shouldShowProgress = chatManager.loadingConversations && 
                            !chatManager.acceptedConversations.isEmpty
    
    if shouldShowLoadMore {
      ProgressView("Loading more...")
        .frame(maxWidth: .infinity)
        .padding()
        .onAppear {
          Task {
            logger.debug("Reached end of conversation list, loading more.")
            await chatManager.loadConversations(refresh: false)
          }
        }
    } else if shouldShowProgress {
      ProgressView()
        .frame(maxWidth: .infinity)
        .padding()
    }
  }
  
  @ViewBuilder
  private var emptyStateContent: some View {
    if chatManager.acceptedConversations.isEmpty && !chatManager.loadingConversations {
      ContentUnavailableView {
        Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
      } description: {
        emptyStateDescription
      }
      .padding()
    }
  }
  
  @ViewBuilder
  private var emptyStateDescription: some View {
    VStack(spacing: 8) {
      Text("You haven't started any chats yet.")
      if appState.chatManager.messageRequestsCount > 0 {
        Text("Check your message requests above to see if anyone wants to chat with you.")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
  }
  
  @ViewBuilder
  private var loadingOverlay: some View {
    if chatManager.loadingConversations && chatManager.acceptedConversations.isEmpty && searchText.isEmpty {
      ProgressView("Loading Chats...")
    }
  }
  
  // MARK: - Helper Methods
  
  private func contactRowButton(for profileBasic: ChatBskyActorDefs.ProfileViewBasic) -> some View {
    Button {
      onSelectSearchResult?(profileBasic)
    } label: {
      HStack {
        ChatProfileAvatarView(profile: profileBasic, size: 40)
        VStack(alignment: .leading) {
          Text(profileBasic.displayName ?? "")
            .font(.headline)
            .foregroundColor(.primary)
          Text("@\(profileBasic.handle.description)")
            .font(.subheadline)
            .foregroundColor(.secondary)
        }
      }
    }
    .buttonStyle(.plain)
    .padding(.vertical, 4)
  }
  
  private func conversationRowView(for convo: ChatBskyConvoDefs.ConvoView, showMuteOption: Bool) -> some View {
    ConversationRow(
      convo: convo,
      did: appState.currentUserDID ?? ""
    )
    .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
    .contentShape(Rectangle())
    .onTapGesture {
      onSelectConvo(convo.id)
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      swipeActionsContent(for: convo, showMuteOption: showMuteOption)
    }
    .contextMenu {
      ConversationContextMenu(conversation: convo)
    }
  }
  
  @ViewBuilder
  private func swipeActionsContent(for convo: ChatBskyConvoDefs.ConvoView, showMuteOption: Bool) -> some View {
    Button(role: .destructive) {
      Task { await chatManager.leaveConversation(convoId: convo.id) }
    } label: {
      Label("Delete", systemImage: "trash")
    }
    
    if showMuteOption {
      Button {
        if convo.muted {
          Task { await chatManager.unmuteConversation(convoId: convo.id) }
        } else {
          Task { await chatManager.muteConversation(convoId: convo.id) }
        }
      } label: {
        Label(convo.muted ? "Unmute" : "Mute", systemImage: convo.muted ? "bell" : "bell.slash")
      }
      .tint(convo.muted ? .blue : .orange)
    } else {
      Button {
        Task { await chatManager.muteConversation(convoId: convo.id) }
      } label: {
        Label("Mute", systemImage: "bell.slash")
      }
    }
  }
}

// MARK: - Conversation Row

struct ConversationRow: View {
  let convo: ChatBskyConvoDefs.ConvoView
  let did: String  // Needed to identify the other member

  // Use @State for properties loaded asynchronously
  @State private var avatarImage: Image?  // Managed by ProfileAvatarView now
  @State private var displayName: String = ""
  @State private var handle: String = ""

  // Determine the other member involved in the conversation
  private var otherMember: ChatBskyActorDefs.ProfileViewBasic? {
    // Find the first member whose DID does not match the current user's DID
    return convo.members.first(where: { $0.did.didString() != did }) ?? nil
  }

  var body: some View {
    HStack(spacing: 12) {
      ChatProfileAvatarView(profile: otherMember, size: 50)

      VStack(alignment: .leading, spacing: 4) {
        Text(displayName.isEmpty ? handle : displayName)  // Show handle if display name is empty
          .font(.headline)
          .lineLimit(1)

        // Last message preview
        if let lastMessage = convo.lastMessage {
          LastMessagePreview(lastMessage: lastMessage)
        } else {
          Text("No messages yet")
            .font(.subheadline)
            .foregroundColor(.gray)
        }
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 6) {
        // Timestamp of the last message
        if let lastMessage = convo.lastMessage, let date = lastMessageDate(lastMessage) {
          Text(formatDate(date))
            .font(.caption)
            .foregroundColor(.gray)
        }

        // Unread message count badge
        if convo.unreadCount > 0 {
          Text("\(convo.unreadCount)")
            .font(.caption.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.blue)
            .clipShape(Capsule())
        } else {
          // Keep alignment consistent even when no badge
          Spacer().frame(height: 20)  // Adjust height to match badge approx
        }
      }
    }
    .padding(.vertical, 8)
    .onAppear {
      // Load profile details when the row appears
      loadProfileDetails()
    }
    // Consider adding context menu for mute/leave actions
  }

  // Helper to extract date from the last message union type
  private func lastMessageDate(_ lastMessage: ChatBskyConvoDefs.ConvoViewLastMessageUnion?) -> Date? {
    guard let message = lastMessage else { return nil }
    switch message {
    case .chatBskyConvoDefsMessageView(let msg):
      return msg.sentAt.date
    case .chatBskyConvoDefsDeletedMessageView(let deletedMsg):
      // Deleted messages might not have a useful timestamp for display,
      // or you might want to show when it was deleted if available.
      // For now, returning nil.
      return nil
    case .unexpected:
      return nil
    }
  }

  // Load display name and handle from the other member's profile
  private func loadProfileDetails() {
    guard let profile = otherMember else {
      displayName = "Unknown User"
      handle = ""
      return
    }

    displayName = profile.displayName ?? ""  // Use empty string if nil
    handle = "@\(profile.handle.description)"
  }

  // Date formatting helper
  private func formatDate(_ date: Date) -> String {
    let calendar = Calendar.current
    let now = Date()

    if calendar.isDateInToday(date) {
      return date.formatted(date: .omitted, time: .shortened)
    } else if calendar.isDateInYesterday(date) {
      return "Yesterday"
    } else if let daysAgo = calendar.dateComponents([.day], from: date, to: now).day, daysAgo < 7 {
      // Show day name for dates within the last week
      let formatter = DateFormatter()
      formatter.dateFormat = "EEEE"  // e.g., "Monday"
      return formatter.string(from: date)
    } else {
      // Show short date for older dates
      return date.formatted(date: .numeric, time: .omitted)
    }
  }
}

// MARK: - Last Message Preview Helper View

struct LastMessagePreview: View {
    @Environment(AppState.self) private var appState
  let lastMessage: ChatBskyConvoDefs.ConvoViewLastMessageUnion

  var body: some View {
    Group {
      switch lastMessage {
      case .chatBskyConvoDefsMessageView(let messageView):
          Text(messageView.sender.did.didString() == appState.currentUserDID ? "You: \(messageView.text)" : messageView.text)
          .font(.subheadline)
          .foregroundColor(.gray)
          .lineLimit(2)
      case .chatBskyConvoDefsDeletedMessageView:
        Text("Message deleted")
          .font(.subheadline)
          .foregroundColor(.gray)
          .italic()
      case .unexpected:
        Text("Unsupported message")
          .font(.subheadline)
          .foregroundColor(.gray)
          .italic()
      }
    }
  }
}

// MARK: - Profile Avatar View (Using NukeUI LazyImage)

struct ChatProfileAvatarView: View {
  let profile: ChatBskyActorDefs.ProfileViewBasic?
  let size: CGFloat

  // No need for @State imageLoaded, LazyImage handles its state

  var body: some View {
    let avatarURL = profile?.avatar?.url

    LazyImage(url: avatarURL) { state in
      if let image = state.image {
        image
          .resizable()
          .scaledToFill()
      } else {
        // Placeholder view
        ZStack {
          Circle().fill(Color.gray.opacity(0.2))
          if state.error != nil {
            Image(systemName: "exclamationmark.circle")  // Error indicator
              .foregroundColor(.red)
          } else {
            Text(initials)
              .font(.system(size: size * 0.4))
              .foregroundColor(.secondary)
          }
          // NukeUI doesn't expose isLoading directly in the builder like this,
          // but the placeholder is shown during loading.
        }
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    // Add a subtle border/overlay if desired
    .overlay(Circle().stroke(Color.gray.opacity(0.1), lineWidth: 1))
  }

  // Helper to generate initials from profile display name or handle
  private var initials: String {
    guard let profile = profile else { return "?" }

    if let displayName = profile.displayName,
      !displayName.trimmingCharacters(in: .whitespaces).isEmpty {
      let components = displayName.components(separatedBy: .whitespacesAndNewlines).filter {
        !$0.isEmpty
      }
      if components.count > 1, let first = components.first?.first,
        let last = components.last?.first {
        return String(first).uppercased() + String(last).uppercased()
      } else if let first = displayName.trimmingCharacters(in: .whitespaces).first {
        return String(first).uppercased()
      }
    }

    // Fallback to handle
    return String(profile.handle.description).uppercased()

  }
}

// MARK: - Conversation View (Using ExyteChat)

struct ConversationView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme
  let convoId: String

  // Get messages directly from ChatManager's map
  private var messages: [Message] {
    appState.chatManager.messagesMap[convoId] ?? []
  }
    
    private var chatNavigationPath: Binding<NavigationPath> {
      appState.navigationManager.pathBinding(for: 4)
    }

  @State private var isLoadingMessages: Bool = false
  @State private var draftMessage: DraftMessage = .init(
    text: "", medias: [], giphyMedia: nil, recording: nil, replyMessage: nil, createdAt: Date())
  @State private var showingReportSheet = false
  @State private var messageToReport: Message?
  @State private var showingDeleteAlert = false
  @State private var messageToDelete: Message?

  // Access the specific ChatManager instance
  private var chatManager: ChatManager {
    appState.chatManager
  }

  var body: some View {
    ZStack {  // Use ZStack to overlay loading indicator
      VStack(spacing: 0) {  // Use VStack to prevent content overlap
        VStack(spacing: 0) {
          ChatView<AnyView, EmptyView, CustomMessageMenuAction>(
            messages: messages,
            chatType: .conversation,
            replyMode: .answer,
            didSendMessage: { draft in
              Task {
                await sendMessage(text: draft.text)
              }
            },
            reactionDelegate: BlueskyMessageReactionDelegate(
              chatManager: chatManager, convoId: convoId),
            messageBuilder: { message, positionInUserGroup, _, _, _, _, _ in
              buildMessageView(message: message, positionInUserGroup: positionInUserGroup)
            },
          messageMenuAction: {
            (
              selectedAction: CustomMessageMenuAction,
              _: @escaping (Message, DefaultMessageMenuAction) -> Void,
              message: Message
            ) in
            switch selectedAction {
            case .copy:
              UIPasteboard.general.string = message.text
//            case .reply:
//              defaultActionClosure(message, .reply)
            case .deleteForMe:
              messageToDelete = message
              showingDeleteAlert = true
            case .report:
              messageToReport = message
              showingReportSheet = true
            }
          },
//          localization: ChatLocalization(inputPlaceholder: <#String#>, signatureText: <#String#>, cancelButtonText: <#String#>, recentToggleText: <#String#>, waitingForNetwork: <#String#>, recordingText: <#String#>, replyToText: <#String#>)
          )
          .setAvailableInputs([.text])
          .showMessageMenuOnLongPress(true)
          .messageReactionDelegate(
            BlueskyMessageReactionDelegate(chatManager: chatManager, convoId: convoId)
          )
          // Custom menu items are handled through the messageMenuAction parameter above
          .enableLoadMore(pageSize: 20) { _ in
            Task {
              logger.debug("Load more triggered for convo \(convoId)")
              await chatManager.loadMessages(convoId: convoId, refresh: false)
            }
          }
          .chatTheme(accentColor: .blue)
          
          // Typing indicator at the bottom
          TypingIndicatorView(convoId: convoId)
        }
      }

      // Loading overlay
      if isLoadingMessages {
        ProgressView("Loading Messages...")
          .padding()
          .background(.regularMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 10))
          .shadow(radius: 5)
      }
    }
    .scrollDismissesKeyboard(.interactively)
    .navigationTitle(conversationTitle)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .navigationBarTrailing) {
        ConversationToolbarMenu(conversation: chatManager.conversations.first { $0.id == convoId })
      }
    }
    .onAppear {
      // Load initial messages if map is empty for this convo
      if chatManager.messagesMap[convoId] == nil {
        loadInitialMessages()
      } else {
        // If messages exist, ensure the convo is marked as read
        Task {
          await chatManager.markConversationAsRead(convoId: convoId)
        }
      }
      // Start polling for new messages in this conversation
      chatManager.startMessagePolling(for: convoId)
    }
    .onDisappear {
      // Stop polling when leaving the conversation
      chatManager.stopMessagePolling(for: convoId)
    }
    // Handle potential errors specific to this conversation view
    .alert(
      "Error Loading Messages",
      isPresented: Binding(
        get: { chatManager.errorState != nil && chatManager.loadingMessages[convoId] == false },  // Show if error exists and not loading
        set: { _ in chatManager.errorState = nil }
      )
    ) {
      Button("OK") {}
    } message: {
      Text(chatManager.errorState?.localizedDescription ?? "Could not load messages.")
    }
    .alert("Delete Message", isPresented: $showingDeleteAlert) {
      Button("Cancel", role: .cancel) { }
      Button("Delete", role: .destructive) {
        if let message = messageToDelete {
          Task {
            let success = await chatManager.deleteMessageForSelf(convoId: convoId, messageId: message.id)
            if !success {
              // Handle error - could show another alert
              logger.error("Failed to delete message \(message.id)")
            }
          }
        }
      }
    } message: {
      Text("This will delete the message for you. Others will still be able to see it.")
    }
    .sheet(isPresented: $showingReportSheet) {
      if let message = messageToReport,
         let originalMessage = chatManager.originalMessagesMap[convoId]?[message.id] {
        ReportChatMessageView(
          message: originalMessage,
          onDismiss: { showingReportSheet = false }
        )
      }
    }
  }

    private func extractPostURI(from text: String) -> String? {
      let pattern = #"at://[a-zA-Z0-9:\.\-]+/app\.bsky\.feed\.post/[a-zA-Z0-9]+(?:\?[^\s]*)?"#
      if let match = text.range(of: pattern, options: .regularExpression) {
        return String(text[match])
      }
      return nil
    }

    // Helper: Looks up the post record in your app state or cache
    private func getPostRecord(for uri: String) -> AppBskyEmbedRecord.ViewRecordUnion? {
      // TODO: Implement lookup logic, e.g. from a cache or by fetching if needed
      return nil
    }
    
  // Function to load initial messages
  private func loadInitialMessages() {
    Task {
      isLoadingMessages = true
      await chatManager.loadMessages(convoId: convoId, refresh: true)
      isLoadingMessages = false
    }
  }
  
  // Helper method to build message view - extracted from complex messageBuilder closure
  private func buildMessageView(message: Message, positionInUserGroup: PositionInUserGroup) -> AnyView {
    let convoMessages = chatManager.originalMessagesMap[convoId]
    let originalMessageView = convoMessages?[message.id]
    
    let record: AppBskyEmbedRecord.ViewRecordUnion?
    switch originalMessageView?.embed {
    case .appBskyEmbedRecordView(let recordView):
      record = recordView.record
    default:
      record = nil
    }
    
    return AnyView(
      VStack(alignment: message.user.isCurrentUser ? .trailing : .leading, spacing: 2) {
        MessageBubble(message: message, embed: record, position: positionInUserGroup, path: chatNavigationPath)
          .padding(1)
        
        // Show reactions if available
        if let originalMessage = originalMessageView,
           let reactions = originalMessage.reactions,
           !reactions.isEmpty {
          MessageReactionsView(
            convoId: convoId,
            messageId: message.id,
            messageView: originalMessage
          )
          .padding(.horizontal)
          .padding(.bottom, 4)
        }
      }
    )
  }

  // Function to send a message
  private func sendMessage(text: String) async {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

    // Optionally provide optimistic update here by creating a temporary message

    let success = await chatManager.sendMessage(convoId: convoId, text: text)

    if success {
      // Clear draft text? ExyteChat might handle this.
      // draftMessage = .init() // Reset draft message if needed
      logger.debug("Message sent successfully for convo \(convoId)")
    } else {
      // Handle send failure (e.g., show an alert)
      logger.error("Failed to send message for convo \(convoId)")
      // Consider showing an error to the user
    }
  }

  // Compute conversation title based on the other member
  private var conversationTitle: String {
    guard let convo = chatManager.conversations.first(where: { $0.id == convoId }) else {
      return "Chat"  // Fallback title
    }

    guard let clientDid = appState.currentUserDID else {
      return "Chat"  // Fallback if client info unavailable
    }

    // Find the other member
    if let otherMember = convo.members.first(where: { $0.did.didString() != clientDid }) {
      return otherMember.displayName ?? "@\(otherMember.handle.description)"
    }

    // If it's a chat with self? Or group chat? Handle accordingly.
    return convo.members.first?.displayName ?? "Chat"  // Fallback
  }

  // Helper to create ChatTheme
  private func createChatTheme() -> ChatTheme {
    // Customize colors and images based on your app's theme
    let colors = ChatTheme.Colors(
        mainBG: Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme), 
        mainTint: Color.dynamicText(appState.themeManager, currentScheme: colorScheme), 
        mainText: Color.dynamicText(appState.themeManager, currentScheme: colorScheme),
        mainCaptionText: .accentColor, 
        messageMyBG: .accentColor)

    let images = ChatTheme.Images(
      //            camera: Image(systemName: "camera.fill"),
      arrowSend: Image(systemName: "arrow.up.circle.fill"),
      //             attach: Image(systemName: "paperclip")
      // ... other image customizations
    )

    return ChatTheme(colors: colors, images: images)
  }

  // Helper to find the original MessageView for a given message ID
  private func getOriginalMessageForId(messageId: String) -> ChatBskyConvoDefs.MessageView? {
    chatManager.originalMessagesMap[convoId]?[messageId]
  }
}

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
          .font(.body)
        
        if requestsCount > 0 {
          // Badge for total requests count
          Text("\(requestsCount)")
            .font(.caption2)
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
}

// Add Identifiable conformance to ChatBskyConvoDefs.ConvoView if it doesn't have it
extension ChatBskyConvoDefs.ConvoView: @retroactive Identifiable {}

// MARK: - Custom Message Menu Action

enum CustomMessageMenuAction: String, CaseIterable, MessageMenuAction {
  case copy
//  case reply
  case deleteForMe
  case report
  
    func title() -> String {
    switch self {
    case .copy:
      return "Copy"
//    case .reply:
//      return "Reply"
    case .deleteForMe:
      return "Delete for me"
    case .report:
      return "Report"
    }
  }
  
    func icon() -> Image {
    switch self {
    case .copy:
      return Image(systemName: "doc.on.doc")
//    case .reply:
//      return Image(systemName: "arrowshape.turn.up.left")
    case .deleteForMe:
      return Image(systemName: "trash")
    case .report:
      return Image(systemName: "exclamationmark.triangle")
    }
  }
}

// MARK: - Report Chat Message View

struct ReportChatMessageView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  
  let message: ChatBskyConvoDefs.MessageView
  let onDismiss: () -> Void
  
  @State private var selectedReason: ComAtprotoModerationDefs.ReasonType = .comatprotomoderationdefsreasonspam
  @State private var additionalDetails: String = ""
  @State private var isSubmitting = false
  @State private var showingError = false
  @State private var errorMessage = ""
  
  private var reportingService: ReportingService? {
    guard let client = appState.atProtoClient else { return nil }
    return ReportingService(client: client)
  }
  
  var body: some View {
    NavigationView {
      Form {
        Section("Message to Report") {
          Text(message.text)
            .font(.callout)
            .foregroundColor(.secondary)
            .padding(.vertical, 4)
        }
        
        Section("Report Reason") {
          Picker("Reason", selection: $selectedReason) {
              Text("Spam").tag(ComAtprotoModerationDefs.ReasonType.comatprotomoderationdefsreasonspam)
              Text("Harassment").tag(ComAtprotoModerationDefs.ReasonType.comatprotomoderationdefsreasonrude)
              Text("Violation").tag(ComAtprotoModerationDefs.ReasonType.comatprotomoderationdefsreasonviolation)
              Text("Misleading").tag(ComAtprotoModerationDefs.ReasonType.comatprotomoderationdefsreasonmisleading)
              Text("Sexual Content").tag(ComAtprotoModerationDefs.ReasonType.comatprotomoderationdefsreasonsexual)
              Text("Other").tag(ComAtprotoModerationDefs.ReasonType.comatprotomoderationdefsreasonother)
          }
        }
        
        Section("Additional Details (Optional)") {
          TextEditor(text: $additionalDetails)
            .frame(minHeight: 100)
        }
        
        Section {
          Text("This report will be sent to the moderation team for review. False reports may result in action against your account.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
      .navigationTitle("Report Message")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Cancel") {
            onDismiss()
          }
          .disabled(isSubmitting)
        }
        
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Submit") {
            submitReport()
          }
          .disabled(isSubmitting)
        }
      }
      .disabled(isSubmitting)
      .overlay {
        if isSubmitting {
          ProgressView("Submitting report...")
            .padding()
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
      }
      .alert("Report Error", isPresented: $showingError) {
        Button("OK") { }
      } message: {
        Text(errorMessage)
      }
    }
  }
  
  private func submitReport() {
    Task {
      isSubmitting = true
      defer { isSubmitting = false }
      
      guard let reportingService = reportingService else {
        await MainActor.run {
          errorMessage = "Reporting service is not available"
          showingError = true
        }
        return
      }
      
      do {
        // For chat messages, we'll report the sender's account
        let subject = reportingService.createUserSubject(did: message.sender.did)
        
        let reason = additionalDetails.isEmpty ? "Inappropriate message in chat" : additionalDetails
        
        let success = try await reportingService.submitReport(
          subject: subject,
          reasonType: selectedReason,
          reason: reason
        )
        
        if success {
          await MainActor.run {
            onDismiss()
          }
        } else {
          await MainActor.run {
            errorMessage = "Failed to submit report. Please try again."
            showingError = true
          }
        }
      } catch {
        await MainActor.run {
          errorMessage = error.localizedDescription
          showingError = true
        }
      }
    }
  }
}
