import SwiftUI
import OSLog
import Petrel

#if os(iOS)
import ExyteChat
#endif

// MARK: - MLS Conversation Detail View

/// Chat interface for an end-to-end encrypted MLS conversation with E2EE badge
#if os(iOS)
struct MLSConversationDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    
    let conversationId: String
    
    @State private var messages: [Message] = []
    @State private var isLoadingMessages = false
    @State private var isSendingMessage = false
    @State private var draftMessage = DraftMessage(
        text: "", medias: [], giphyMedia: nil, recording: nil, replyMessage: nil, createdAt: Date()
    )
    @State private var showingMemberManagement = false
    @State private var showingEncryptionInfo = false
    @State private var conversation: MLSConversationViewModel?
    @State private var messageToDelete: Message?
    @State private var showingDeleteAlert = false
    @State private var eventStreamManager: MLSEventStreamManager?
    @State private var typingUsers: Set<String> = []
    @State private var serverError: String?
    @State private var hasStartedSubscription = false
    @State private var sendError: String?
    @State private var showingSendError = false

    private let logger = Logger(subsystem: "blue.catbird", category: "MLSConversationDetail")
    private let storage = MLSStorage.shared
    
    var body: some View {
        ZStack {
            VStack(spacing: DesignTokens.Spacing.none) {
                #if os(iOS)
                chatView
                #endif
            }
            
            if isLoadingMessages && messages.isEmpty {
                ProgressView("Loading messages...")
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .themedNavigationBar(appState.themeManager)
        .toolbar {
            ToolbarItem(placement: .principal) {
                encryptionStatusHeader
            }
            
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if conversation?.isGroupChat == true {
                        Button {
                            showingMemberManagement = true
                        } label: {
                            Label("Manage Members", systemImage: "person.2")
                        }
                    }
                    
                    Button {
                        showingEncryptionInfo = true
                    } label: {
                        Label("Encryption Info", systemImage: "info.circle")
                    }
                    
                    Divider()
                    
                    Button(role: .destructive) {
                        leaveConversation()
                    } label: {
                        Label("Leave Conversation", systemImage: "arrow.right.square")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("Conversation options")
                }
            }
        }
        .sheet(isPresented: $showingMemberManagement) {
            if let conversation = conversation {
                MLSMemberManagementView(conversation: conversation)
            }
        }
        .sheet(isPresented: $showingEncryptionInfo) {
            encryptionInfoSheet
        }
        .alert("Delete Message", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let message = messageToDelete {
                    deleteMessage(message)
                }
            }
        } message: {
            Text("This will delete the message locally. Others will still be able to see it.")
        }
        .alert("Send Failed", isPresented: $showingSendError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(sendError ?? "Failed to send message. Please try again.")
        }
        .task {
            await loadConversationAndMessages()
        }
        // Start subscription after initial load completes
        .onDisappear {
            // Stop polling when leaving
            stopMessagePolling()
        }
    }
    
    // MARK: - Encryption Status Header
    
    @ViewBuilder
    private var encryptionStatusHeader: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            VStack(spacing: 2) {
                Text(navigationTitle)
                    .designCallout()
                    .lineLimit(1)
                
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                    
                    Text("End-to-End Encrypted")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
        }
        .onTapGesture {
            showingEncryptionInfo = true
        }
        .accessibilityLabel("End-to-end encrypted conversation")
        .accessibilityHint("Tap to view encryption details")
    }
    
    // MARK: - Chat View
    
    #if os(iOS)
    @ViewBuilder
    private var chatView: some View {
        ChatView<EmptyView, EmptyView, CustomMessageMenuAction>(
            messages: messages,
            chatType: .conversation,
            replyMode: .answer,
            didSendMessage: { (draft: DraftMessage) in
                Task {
                    await sendMLSMessage(text: draft.text)
                }
            },
            messageMenuAction: { (action: CustomMessageMenuAction, _, message: Message) in
                handleMessageMenuAction(action: action, message: message)
            }
        )
        .setAvailableInputs([.text])
        .showMessageMenuOnLongPress(true)
        .enableLoadMore(pageSize: 20) { _ in
            Task {
                await loadMoreMessages()
            }
        }
        .chatTheme(accentColor: .blue)
        .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
    }
    #endif
    
    // MARK: - Encryption Info Sheet
    
    @ViewBuilder
    private var encryptionInfoSheet: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.green)
                            .frame(width: 60)
                        
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                            Text("End-to-End Encrypted")
                                .designCallout()
                            Text("Messages are secured with MLS protocol")
                                .designFootnote()
                                .foregroundColor(.secondary)
                        }
                    }
                    .spacingSM(.vertical)
                }
                
                Section("Encryption Details") {
                    InfoRow(label: "Protocol", value: "MLS (RFC 9420)")
                    InfoRow(label: "Group ID", value: conversation?.groupId ?? "Unknown")
                    InfoRow(label: "Key Rotation", value: "Automatic")
                    InfoRow(label: "Forward Secrecy", value: "Enabled")
                    InfoRow(label: "Post-Compromise Security", value: "Enabled")
                }
                
                Section {
                    Text("This conversation uses the Messaging Layer Security (MLS) protocol, providing end-to-end encryption with forward secrecy and post-compromise security.")
                        .designFootnote()
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Encryption Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showingEncryptionInfo = false
                    }
                }
            }
        }
    }
    
    // MARK: - Helper Views
    
    private struct InfoRow: View {
        let label: String
        let value: String
        
        var body: some View {
            HStack {
                Text(label)
                    .designFootnote()
                    .foregroundColor(.secondary)
                Spacer()
                Text(value)
                    .designFootnote()
                    .foregroundColor(.primary)
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var navigationTitle: String {
        if let name = conversation?.name {
            return name
        }
        
        if let conversation = conversation, conversation.isGroupChat {
            let names = conversation.participants.prefix(3).map { $0.displayName ?? $0.handle }
            if conversation.participants.count > 3 {
                return names.joined(separator: ", ") + "..."
            }
            return names.joined(separator: ", ")
        }
        
        return conversation?.participants.first?.displayName ?? "Secure Chat"
    }
    
    // MARK: - Actions
    
    private func loadConversationAndMessages() async {
        isLoadingMessages = true
        defer { isLoadingMessages = false }
        
        // Load conversation details from AppState
        conversation = appState.mlsConversations.first { $0.id == conversationId }
        
        guard let manager = await appState.getMLSConversationManager() else {
            logger.error("Failed to get MLS conversation manager")
            return
        }
        
        // Ensure the MLS group is initialized for this conversation
        // This is critical for invited users who need to process the Welcome message
        do {
            try await manager.ensureGroupInitialized(for: conversationId)
            logger.info("MLS group initialized for conversation \(conversationId)")
        } catch {
            logger.error("Failed to initialize MLS group: \(error.localizedDescription)")
            sendError = "Failed to initialize secure messaging. Please try again."
            showingSendError = true
            return
        }
        
        do {
            // Fetch messages from server
            let apiClient = await appState.getMLSAPIClient()
            guard let apiClient = apiClient else {
                logger.error("Failed to get MLS API client")
                return
            }
            
            let (messageViews, _) = try await apiClient.getMessages(
                convoId: conversationId,
                limit: 50,
                sinceMessage: nil
            )
            
            logger.info("Fetched \(messageViews.count) encrypted messages")
            
            // Decrypt and convert messages
            var decryptedMessages: [Message] = []
            for messageView in messageViews.reversed() {
                do {
                    let isCurrentUser = messageView.sender.description == appState.currentUserDID

                    // Check Core Data for stored plaintext first (for self-sent messages)
                    let plaintext: String
                    if let storedPlaintext = try? storage.fetchPlaintextForMessage(messageID: messageView.id) {
                        plaintext = storedPlaintext
                        logger.debug("Using stored plaintext from Core Data for message \(messageView.id)")
                    } else if !isCurrentUser {
                        // Only decrypt messages from other users
                        plaintext = try await manager.decryptMessage(messageView)
                        logger.debug("Decrypted message from other user \(messageView.id)")
                    } else {
                        // Self-sent message with no stored plaintext (shouldn't happen)
                        logger.warning("No stored plaintext for self-sent message \(messageView.id), skipping")
                        continue
                    }

                    let message = Message(
                        id: messageView.id,
                        user: User(
                            id: messageView.sender.description,
                            name: isCurrentUser ? "You" : formatDID(messageView.sender.description),
                            avatarURL: nil,
                            isCurrentUser: isCurrentUser
                        ),
                        status: .sent,
                        createdAt: messageView.createdAt.date,
                        text: plaintext
                    )

                    decryptedMessages.append(message)
                } catch {
                    logger.error("Failed to decrypt message \(messageView.id): \(error.localizedDescription)")
                }
            }
            
            messages = decryptedMessages
            logger.info("Loaded and decrypted \(messages.count) messages")
            // Start live updates after initial load
            if !hasStartedSubscription {
                startMessagePolling()
                hasStartedSubscription = true
            }
            
        } catch {
            logger.error("Failed to load messages: \(error.localizedDescription)")
        }
    }
    
    private func loadMoreMessages() async {
        logger.debug("Loading more messages (pagination not yet implemented)")
        // TODO: Implement pagination using cursor
    }
    
    private func sendMLSMessage(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { 
            logger.debug("Skipping empty message")
            return 
        }

        await MainActor.run {
            isSendingMessage = true
        }
        
        defer {
            Task { @MainActor in
                isSendingMessage = false
            }
        }
        
        logger.debug("Sending MLS message: \(trimmed.prefix(50))...")
        
        do {
            guard let manager = await appState.getMLSConversationManager() else {
                await MainActor.run {
                    logger.error("Failed to get MLS conversation manager")
                    sendError = "MLS service not available. Please try restarting the app."
                    showingSendError = true
                }
                return
            }
            
            let (messageId, receivedAt) = try await manager.sendMessage(
                convoId: conversationId,
                plaintext: trimmed
            )

            logger.debug("Message sent successfully: \(messageId)")

            // Store plaintext to Core Data for later retrieval (can't decrypt own messages in MLS)
            do {
                try storage.savePlaintextForMessage(
                    messageID: messageId,
                    conversationID: conversationId,
                    plaintext: trimmed,
                    senderID: appState.currentUserDID ?? ""
                )
                logger.debug("Saved plaintext to Core Data for message: \(messageId)")
            } catch {
                logger.error("Failed to save plaintext to Core Data: \(error.localizedDescription)")
            }

            await MainActor.run {
                let newMessage = Message(
                    id: messageId,
                    user: User(
                        id: appState.currentUserDID ?? "",
                        name: "You",
                        avatarURL: nil,
                        isCurrentUser: true
                    ),
                    status: .sent,
                    createdAt: receivedAt.date,
                    text: trimmed
                )

                // Only add if not already present (WebSocket might have added it)
                if !messages.contains(where: { $0.id == messageId }) {
                    messages.append(newMessage)
                    logger.debug("Added message to UI: \(messageId)")
                } else {
                    logger.debug("Message already in UI (from WebSocket): \(messageId)")
                }
            }
        } catch {
            await MainActor.run {
                logger.error("Failed to send message: \(error.localizedDescription)")
                sendError = "Failed to send message: \(error.localizedDescription)"
                showingSendError = true
            }
        }
    }
    
    // MARK: - Real-Time Events
    
    private func startMessagePolling() {
        logger.debug("Starting WebSocket subscription for real-time messages")
        
        Task {
            guard let apiClient = await appState.getMLSAPIClient() else {
                logger.error("Failed to get MLS API client for WebSocket")
                return
            }
            
            let streamManager = MLSEventStreamManager(apiClient: apiClient)
            eventStreamManager = streamManager
            
            // Subscribe to conversation events
            streamManager.subscribe(
                to: conversationId,
                handler: MLSEventStreamManager.EventHandler(
                    onMessage: { messageEvent in
                        Task { @MainActor in
                            await self.handleNewMessage(messageEvent)
                        }
                    },
                    onReaction: { reactionEvent in
                        Task { @MainActor in
                            await self.handleReaction(reactionEvent)
                        }
                    },
                    onTyping: { typingEvent in
                        Task { @MainActor in
                            await self.handleTypingIndicator(typingEvent)
                        }
                    },
                    onInfo: { infoEvent in
                        // Handle info/heartbeat events
                    },
                    onError: { error in
                        Task { @MainActor in
                            self.logger.error("WebSocket error: \(error.localizedDescription)")
                        }
                    }
                )
            )
        }
    }
    
    private func stopMessagePolling() {
        logger.debug("Stopping WebSocket subscription")
        eventStreamManager?.stop(conversationId)
        eventStreamManager = nil
        hasStartedSubscription = false
    }
    
    @MainActor
    private func handleNewMessage(_ event: BlueCatbirdMlsStreamConvoEvents.MessageEvent) async {
        logger.debug("Received new message via WebSocket: \(event.message.id)")

        // Decrypt the message
        guard let manager = await appState.getMLSConversationManager() else {
            return
        }

        do {
            let isCurrentUser = event.message.sender.description == appState.currentUserDID

            // Check Core Data for stored plaintext first (for self-sent messages)
            let plaintext: String
            if let storedPlaintext = try? storage.fetchPlaintextForMessage(messageID: event.message.id) {
                plaintext = storedPlaintext
                logger.debug("Using stored plaintext from Core Data for WebSocket message \(event.message.id)")
            } else if !isCurrentUser {
                // Only decrypt messages from other users
                plaintext = try await manager.decryptMessage(event.message)
                logger.debug("Decrypted WebSocket message from other user")
            } else {
                // Self-sent message with no stored plaintext, skip
                logger.warning("No stored plaintext for self-sent WebSocket message \(event.message.id)")
                return
            }

            let newMessage = Message(
                id: event.message.id,
                user: User(
                    id: event.message.sender.description,
                    name: isCurrentUser ? "You" : formatDID(event.message.sender.description),
                    avatarURL: nil,
                    isCurrentUser: isCurrentUser
                ),
                status: .sent,
                createdAt: event.message.createdAt.date,
                text: plaintext
            )
            
            // Add to messages if not already present
            if !messages.contains(where: { $0.id == newMessage.id }) {
                messages.append(newMessage)
                logger.debug("Added new message from WebSocket")
            }
            
        } catch {
            logger.error("Failed to decrypt WebSocket message: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    private func handleReaction(_ event: BlueCatbirdMlsStreamConvoEvents.ReactionEvent) async {
        logger.debug("Received reaction via WebSocket: \(event.action) \(event.reaction) on \(event.messageId)")
        
        // TODO: Update message reactions in UI
        // This would require extending the Message model to support reactions
    }
    
    @MainActor
    private func handleTypingIndicator(_ event: BlueCatbirdMlsStreamConvoEvents.TypingEvent) async {
        let did = event.did.description
        
        if event.isTyping {
            typingUsers.insert(did)
            logger.debug("User started typing: \(did)")
        } else {
            typingUsers.remove(did)
            logger.debug("User stopped typing: \(did)")
        }
        
        // TODO: Display typing indicator in UI
        // This would show "Alice is typing..." below the message list
    }
    
    private func handleMessageMenuAction(action: CustomMessageMenuAction, message: Message) {
        switch action {
        case .copy:
            UIPasteboard.general.string = message.text
        case .report:
            // TODO: Implement reporting for MLS messages
            logger.info("Report action not yet implemented for MLS")
        case .deleteForMe:
            messageToDelete = message
            showingDeleteAlert = true
        }
    }
    
    private func deleteMessage(_ message: Message) {
        messages.removeAll { $0.id == message.id }
        logger.info("Deleted message locally: \(message.id)")
    }
    
    private func leaveConversation() {
        // TODO: Implement leaving MLS group
        logger.info("Leave conversation not yet implemented: \(conversationId)")
    }
    
    private func formatDID(_ did: String) -> String {
        // Extract handle or last part of DID for display
        if let lastPart = did.split(separator: ":").last {
            return String(lastPart.prefix(12))
        }
        return did
    }
    
    private func formatMessageTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Custom Message Menu Action


// MARK: - Preview

#Preview {
    NavigationStack {
        MLSConversationDetailView(conversationId: "test-conversation-id")
            .environment(AppState.shared)
    }
}

#endif
