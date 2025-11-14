import SwiftUI
import OSLog
import Petrel

#if os(iOS)
import ExyteChat
#endif

// MARK: - Recovery State

/// State tracking for key package desync recovery
enum RecoveryState: Equatable {
    case none
    case needed
    case inProgress
    case success
    case failed(String)
}

// MARK: - MLS Conversation Detail View

/// Chat interface for an end-to-end encrypted MLS conversation with E2EE badge
#if os(iOS)
struct MLSConversationDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    let conversationId: String

    @State private var viewModel: MLSConversationDetailViewModel?
    @State private var conversationModel: MLSConversationModel?
    @State private var messages: [Message] = []
    @State private var embedsMap: [String: MLSEmbedData] = [:]
    @State private var isLoadingMessages = false
    @State private var memberCount: Int = 0
    @State private var members: [MLSMemberModel] = []
    @State private var isSendingMessage = false
    @State private var draftMessage = DraftMessage(
        text: "", medias: [], giphyMedia: nil, recording: nil, replyMessage: nil, createdAt: Date()
    )
    @State private var showingMemberManagement = false
    @State private var showingEncryptionInfo = false
    @State private var messageToDelete: Message?
    @State private var showingDeleteAlert = false
    @State private var eventStreamManager: MLSEventStreamManager?
    @State private var typingUsers: Set<String> = []
    @State private var serverError: String?
    @State private var hasStartedSubscription = false
    @State private var sendError: String?
    @State private var showingSendError = false
    @State private var showingLeaveConfirmation = false
    @State private var composerText = ""
    @State private var attachedEmbed: MLSEmbedData?
    @State private var showingAdminDashboard = false
    @State private var showingReportsView = false
    @State private var pendingReportsCount = 0
    @State private var isCurrentUserAdmin = false
    @State private var recoveryState: RecoveryState = .none
    @State private var showingRecoveryError = false

    private let logger = Logger(subsystem: "blue.catbird", category: "MLSConversationDetail")
    private let storage = MLSStorage.shared

    private var mainContent: some View {
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

            // Show initialization overlay when conversation is initializing
            if let state = viewModel?.conversationState, case .initializing(let progress) = state {
                initializationOverlay(progress: progress)
            }

            // Show recovery overlay when key package desync is detected
            if case .needed = recoveryState {
                recoveryOverlay()
            }
        }
    }

    @ViewBuilder
    private func initializationOverlay(progress: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Starting secure chat...")
                .font(.headline)

            Text(progress)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func recoveryOverlay() -> some View {
        VStack(spacing: 24) {
            Image(systemName: "key.fill")
                .font(.system(size: 60))
                .foregroundStyle(.orange)
                .accessibilityLabel("Security key icon")

            Text("Security Keys Need Update")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Your encryption keys were reset. Rejoin to continue chatting securely.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button {
                Task { await performRecovery() }
            } label: {
                if case .inProgress = recoveryState {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else {
                    Text("Rejoin Conversation")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(recoveryState == .inProgress)
            .frame(minWidth: 200)
            .accessibilityLabel("Rejoin conversation")
            .accessibilityHint("Tap to rejoin the conversation with updated security keys")
        }
        .padding(32)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    var body: some View {
        mainContent
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .themedNavigationBar(appState.themeManager)
            .toolbar {
            ToolbarItem(placement: .principal) {
                encryptionStatusHeader
            }

            // Admin Dashboard button (iOS 26+ only, admins only)
            if #available(iOS 26.0, *), isCurrentUserAdmin {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdminDashboard = true
                    } label: {
                        Image(systemName: "chart.bar.fill")
                            .accessibilityLabel("Admin Dashboard")
                    }
                }
            }

            // Reports button with badge (iOS 26+ only, admins only)
            if #available(iOS 26.0, *), isCurrentUserAdmin {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingReportsView = true
                    } label: {
                        Image(systemName: "doc.text.fill")
                            .overlay(alignment: .topTrailing) {
                                if pendingReportsCount > 0 {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 4, y: -4)
                                }
                            }
                            .accessibilityLabel(pendingReportsCount > 0 ? "\(pendingReportsCount) pending reports" : "Reports")
                    }
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Menu {
                    // Show member management for MLS group chats (more than 1 member)
                    if memberCount > 1 {
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
                        showingLeaveConfirmation = true
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
            // TODO: Update MLSMemberManagementView to use MLSConversationModel
            Text("Member Management")
        }
        .sheet(isPresented: $showingEncryptionInfo) {
            encryptionInfoSheet
        }
        .sheet(isPresented: $showingAdminDashboard) {
            if #available(iOS 26.0, *),
               let apiClient = viewModel?.apiClient,
               let conversationManager = viewModel?.conversationManager {
                NavigationStack {
                    MLSAdminDashboardView(
                        conversationId: conversationId,
                        apiClient: apiClient,
                        conversationManager: conversationManager
                    )
                }
            }
        }
        .sheet(isPresented: $showingReportsView) {
            if #available(iOS 26.0, *),
               let conversationManager = viewModel?.conversationManager {
                NavigationStack {
                    MLSReportsView(
                        conversationId: conversationId,
                        conversationManager: conversationManager
                    )
                }
            }
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
        .alert("Leave Conversation", isPresented: $showingLeaveConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Leave", role: .destructive) {
                leaveConversation()
            }
        } message: {
            Text("Are you sure you want to leave this conversation? You will no longer be able to send or receive messages.")
        }
        .alert("Recovery Failed", isPresented: $showingRecoveryError) {
            Button("Retry") {
                Task { await performRecovery() }
            }
            Button("Cancel", role: .cancel) {
                recoveryState = .none
            }
        } message: {
            if case .failed(let errorMessage) = recoveryState {
                Text(errorMessage)
            } else {
                Text("Failed to rejoin conversation. Please try again.")
            }
        }
        .task {
            if viewModel == nil {
                guard let database = appState.mlsDatabase,
                      let apiClient = await appState.getMLSAPIClient(),
                      let conversationManager = await appState.getMLSConversationManager() else {
                    logger.error("Cannot initialize view: dependencies not available")
                    sendError = "MLS service not available. Please restart the app."
                    showingSendError = true
                    return
                }

                viewModel = MLSConversationDetailViewModel(
                    conversationId: conversationId,
                    database: database,
                    apiClient: apiClient,
                    conversationManager: conversationManager
                )
            }

            await loadConversationAndMessages()
            await loadMemberCount()
            await checkAdminStatus()
            await loadPendingReportsCount()
        }
        .onDisappear {
            stopMessagePolling()
        }
    }

    // MARK: - Admin Status and Reports

    @MainActor
    private func checkAdminStatus() async {
        guard let viewModel = viewModel,
              let conversation = viewModel.conversation else {
            return
        }

        let currentUserDid = appState.userDID
        if let member = conversation.members.first(where: { $0.did.description == currentUserDid }) {
            isCurrentUserAdmin = member.isAdmin
            logger.debug("Admin status checked: \(self.isCurrentUserAdmin)")
        }
    }

    @MainActor
    private func loadPendingReportsCount() async {
        guard isCurrentUserAdmin,
              let conversationManager = viewModel?.conversationManager else {
            pendingReportsCount = 0
            return
        }

        do {
            let (reports, _) = try await conversationManager.loadReports(
                for: conversationId,
                limit: 50,
                cursor: nil as String?
            )
            pendingReportsCount = reports.filter { $0.status == "pending" }.count
            logger.debug("Loaded pending reports count: \(self.pendingReportsCount)")
        } catch {
            logger.error("Failed to load pending reports count: \(error.localizedDescription)")
            pendingReportsCount = 0
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
        VStack(spacing: 0) {
            // Messages ScrollView
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: DesignTokens.Spacing.sm) {
                        ForEach(messages, id: \.id) { message in
                            messageRow(for: message)
                                .id(message.id)
                                .contextMenu {
                                    messageContextMenu(for: message)
                                }
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.base)
                    .padding(.vertical, DesignTokens.Spacing.sm)
                }
                .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
                .onChange(of: messages.count) { _, _ in
                    // Scroll to bottom on new message
                    if let lastMessage = messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    // Scroll to bottom on appear
                    if let lastMessage = messages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }

            // Custom composer
            MLSMessageComposerView(
                text: $composerText,
                attachedEmbed: $attachedEmbed,
                onSend: { text, embed in
                    Task {
                        await sendMLSMessage(text: text, embed: embed)
                    }
                }
            )
        }
    }

    @ViewBuilder
    private func messageRow(for message: Message) -> some View {
        HStack {
            if message.user.isCurrentUser {
                Spacer()
            }

            // Get embed from map if available
            let embed = embedsMap[message.id]

            MLSMessageView(
                text: message.text,
                embed: embed,
                isCurrentUser: message.user.isCurrentUser,
                timestamp: message.createdAt,
                senderName: message.user.name,
                senderAvatarURL: message.user.avatarURL,
                messageState: nil, // Regular messages don't have pending states
                onRetry: nil,
                navigationPath: .constant(NavigationPath())
            )

            if !message.user.isCurrentUser {
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func messageContextMenu(for message: Message) -> some View {
        Button {
            UIPasteboard.general.string = message.text
        } label: {
            Label("Copy Text", systemImage: "doc.on.doc")
        }

        if message.user.isCurrentUser {
            Button(role: .destructive) {
                messageToDelete = message
                showingDeleteAlert = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } else {
            Button(role: .destructive) {
                // Handle report
                logger.warning("Report functionality not yet implemented")
            } label: {
                Label("Report", systemImage: "exclamationmark.triangle")
            }
        }
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
                    InfoRow(label: "Group ID", value: conversationModel?.groupID.base64EncodedString().prefix(16).description ?? "Unknown")
                    InfoRow(label: "Epoch", value: "\(conversationModel?.epoch ?? 0)")
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
        if let title = conversationModel?.title, !title.isEmpty {
            return title
        }

        // Use member count to determine if group chat or 1-on-1
        if memberCount > 1 {
            return "Secure Group Chat"
        } else {
            return "Secure Chat"
        }
    }
    
    // MARK: - Conversation Metadata

    @discardableResult
    private func ensureConversationMetadata() async -> MLSConversationModel? {
        if let cachedModel = conversationModel {
            return cachedModel
        }

        guard let database = appState.mlsDatabase,
              let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID else {
            logger.warning("Cannot resolve conversation metadata: missing database or user DID")
            return nil
        }

        if let stored = try? await storage.fetchConversation(
            conversationID: conversationId,
            currentUserDID: currentUserDID,
            database: database
        ) {
            await MainActor.run {
                conversationModel = stored
            }
            return stored
        }

        guard let conversationView = await resolveConversationView() else {
            logger.error("Failed to load conversation metadata for \(conversationId)")
            return nil
        }

        do {
            try await storage.ensureConversationExists(
                conversationID: conversationId,
                groupID: conversationView.groupId,
                database: database
            )

            if let stored = try? await storage.fetchConversation(
                conversationID: conversationId,
                currentUserDID: currentUserDID,
                database: database
            ) {
                await MainActor.run {
                    conversationModel = stored
                }
                return stored
            }

            if let groupData = Data(hexEncoded: conversationView.groupId) {
                let synthesized = MLSConversationModel(
                    conversationID: conversationView.groupId,
                    currentUserDID: currentUserDID,
                    groupID: groupData,
                    epoch: Int64(conversationView.epoch),
                    title: nil,
                    avatarURL: nil,
                    createdAt: conversationView.createdAt.date,
                    updatedAt: Date(),
                    lastMessageAt: conversationView.lastMessageAt?.date,
                    isActive: true
                )
                await MainActor.run {
                    conversationModel = synthesized
                }
                return synthesized
            }
        } catch {
            logger.error("Failed to ensure conversation metadata: \(error.localizedDescription)")
        }

        return nil
    }

    private func resolveConversationView() async -> BlueCatbirdMlsDefs.ConvoView? {
        guard let manager = await appState.getMLSConversationManager() else {
            logger.error("Cannot resolve conversation metadata: manager unavailable")
            return nil
        }

        if let cached = manager.conversations[conversationId] {
            return cached
        }

        do {
            try await manager.syncWithServer()
            return manager.conversations[conversationId]
        } catch {
            logger.error("Failed to sync conversation metadata: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Actions

    private func loadConversationAndMessages() async {
        // CRITICAL: Protect metadata fetching from task cancellation
        // Even if the view is dismissed, we need conversation metadata for subsequent operations
        // Using withTaskCancellationHandler ensures this completes before cancellation propagates
        await withTaskCancellationHandler {
            _ = await ensureConversationMetadata()
        } onCancel: {
            logger.debug("Conversation metadata fetch was cancelled, but allowing completion")
        }

        // PHASE 0: Load cached messages for instant display
        // Cache queries are fast and idempotent - safe to run on every view appearance
        await loadCachedMessages()

        // Skip expensive server fetch + decryption if already loaded
        // MLS ratchets forward on decryption - we can't decrypt the same ciphertext twice
        // But cache loading should ALWAYS happen for updated messages
        if !messages.isEmpty {
            logger.debug("Messages already populated, skipping server re-fetch to preserve ratchet state")
            // Still ensure group is initialized and start subscription if needed
            guard let manager = await appState.getMLSConversationManager() else {
                return
            }

            do {
                try await manager.ensureGroupInitialized(for: conversationId)
                if !hasStartedSubscription {
                    startMessagePolling()
                    hasStartedSubscription = true
                }
            } catch let error as MLSConversationError {
                if case .keyPackageDesyncRecoveryInitiated = error {
                    await MainActor.run {
                        recoveryState = .needed
                    }
                    logger.warning("Key package desync detected - showing recovery UI")
                    return
                }
                logger.error("Failed to initialize MLS group: \(error.localizedDescription)")
            } catch {
                logger.error("Failed to initialize MLS group: \(error.localizedDescription)")
            }
            return
        }

        isLoadingMessages = true
        defer { isLoadingMessages = false }

        guard let manager = await appState.getMLSConversationManager() else {
            logger.error("Failed to get MLS conversation manager")
            return
        }

        // Ensure the MLS group is initialized for this conversation
        // This is critical for invited users who need to process the Welcome message
        do {
            try await manager.ensureGroupInitialized(for: conversationId)
            logger.info("MLS group initialized for conversation \(conversationId)")
        } catch let error as MLSConversationError {
            if case .keyPackageDesyncRecoveryInitiated = error {
                await MainActor.run {
                    recoveryState = .needed
                }
                logger.warning("Key package desync detected - showing recovery UI")
                return
            }
            logger.error("Failed to initialize MLS group: \(error.localizedDescription)")
            sendError = "Failed to initialize secure messaging. Please try again."
            showingSendError = true
            return
        } catch {
            logger.error("Failed to initialize MLS group: \(error.localizedDescription)")
            sendError = "Failed to initialize secure messaging. Please try again."
            showingSendError = true
            return
        }

        do {
            // Get current user DID for plaintext isolation
            guard let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID else {
                logger.error("Cannot load messages: currentUserDID not available")
                return
            }

            // Fetch messages from server
            let apiClient = await appState.getMLSAPIClient()
            guard let apiClient = apiClient else {
                logger.error("Failed to get MLS API client")
                return
            }

            let (messageViews, lastSeq, gapInfo) = try await apiClient.getMessages(
                convoId: conversationId,
                limit: 50,
                sinceSeq: nil
            )

            logger.info("Fetched \(messageViews.count) encrypted messages")

            // 🔍 DEBUG: Log what server sent (sender extracted during decryption)
            for (index, msgView) in messageViews.enumerated() {
                logger.info("📨 SERVER MESSAGE [\(index)]: id=\(msgView.id)")
                logger.info("  - epoch: \(msgView.epoch)")
                logger.info("  - seq: \(msgView.seq)")
                logger.info("  - ciphertext.data.count: \(msgView.ciphertext.data.count)")
                logger.info("  - ciphertext.data (first 32 bytes): \(msgView.ciphertext.data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " "))")
                logger.info("  - sentAt: \(msgView.createdAt.date)")
            }

            // CRITICAL FIX #1: Ensure conversation exists in database before processing messages
            // This prevents foreign key constraint violations when storing decrypted messages
            if let database = appState.mlsDatabase {
                // Get groupID from manager's conversations cache
                if let convo = manager.conversations[conversationId] {
                    do {
                        try await storage.ensureConversationExists(
                            conversationID: conversationId,
                            groupID: convo.groupId,
                            database: database
                        )
                        logger.info("✅ Conversation entity verified/created for \(conversationId)")
                    } catch {
                        logger.error("❌ Failed to ensure conversation exists: \(error.localizedDescription)")
                    }
                } else {
                    logger.warning("⚠️ Conversation \(conversationId) not found in manager cache")
                }
            }

            // PHASE 1: Decrypt all messages in correct order
            // Using processMessagesInOrder() ensures proper epoch/sequence ordering and buffering
            logger.info("📊 Phase 1: Processing \(messageViews.count) messages in order (epoch/sequence)")

            // TODO: Refactor ciphertext storage for GRDB/SQLiteData
            // The new SQLiteData implementation handles ciphertext in MLSMessageModel directly
            // Old CoreData wireFormat fields are not present in new schema
            // processMessagesInOrder() already handles decryption and caching in MLSStorageHelpers

            // Process messages in correct order - this handles sorting, buffering, and decryption
            do {
                _ = try await manager.processMessagesInOrder(
                    messages: messageViews,
                    conversationID: conversationId
                )
                logger.info("✅ Phase 1 complete: All messages decrypted and cached in order")
            } catch {
                logger.error("❌ Failed to process messages in order: \(error.localizedDescription)")
                // Continue anyway - we'll use cached data where available
            }

            // PHASE 2: Build UI Message objects from cached data
            logger.info("📊 Phase 2: Building UI Message objects from cached data")
            var decryptedMessages: [Message] = []

            // Server guarantees messages are returned in (epoch ASC, seq ASC) order
            // No client-side sorting needed - use messageViews directly
            for messageView in messageViews {
                do {
                    guard let database = appState.mlsDatabase else {
                        logger.error("Cannot fetch message data: database not available")
                        continue
                    }

                    // Fetch sender DID from storage (extracted from MLS credentials during decryption)
                    guard let senderDID = try? await storage.fetchSenderForMessage(messageView.id, currentUserDID: currentUserDID, database: database) else {
                        logger.warning("⚠️ No sender found for message \(messageView.id) - skipping")
                        continue
                    }

                    logger.debug("🔍 MLS_OWNERSHIP: ====== Building UI for message \(messageView.id) ======")
                    let isCurrentUser = isMessageFromCurrentUser(senderDID: senderDID)
                    logger.info("🔍 MLS_OWNERSHIP: Result for message \(messageView.id): isCurrentUser = \(isCurrentUser)")

                    // Fetch cached plaintext (should be available after Phase 1)
                    var displayText = ""
                    var embed: MLSEmbedData?

                    if let storedPlaintext = try? await storage.fetchPlaintextForMessage(messageView.id, currentUserDID: currentUserDID, database: database) {
                        displayText = storedPlaintext
                        embed = try? await storage.fetchEmbedForMessage(messageView.id, currentUserDID: currentUserDID, database: database)
                        logger.debug("Using cached plaintext for message \(messageView.id) (hasEmbed: \(embed != nil))")
                    } else {
                        // No cached plaintext - this can happen for own messages (MLS prevents self-decryption)
                        if isCurrentUser {
                            logger.warning("⚠️ Message \(messageView.id) from current user has no cached plaintext")
                            logger.warning("   Self-decryption is impossible by MLS design - skipping message")
                            continue
                        } else {
                            // Unexpected: Phase 1 should have decrypted this
                            logger.error("❌ Message \(messageView.id) has no cached plaintext after Phase 1")
                            continue
                        }
                    }

                    // Store embed in map for later rendering
                    if let embed = embed {
                        await MainActor.run {
                            embedsMap[messageView.id] = embed
                        }
                    }

                    let message = Message(
                        id: messageView.id,
                        user: User(
                            id: senderDID,
                            name: isCurrentUser ? "You" : formatDID(senderDID),
                            avatarURL: nil,
                            isCurrentUser: isCurrentUser
                        ),
                        status: .sent,
                        createdAt: messageView.createdAt.date,
                        text: displayText
                    )

                    logger.info("🔍 MLS_OWNERSHIP: Created Message object - user.name: '\(message.user.name ?? "nil")', user.isCurrentUser: \(message.user.isCurrentUser)")
                    decryptedMessages.append(message)
                } catch {
                    logger.error("Failed to build UI for message \(messageView.id): \(error.localizedDescription)")
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
    
    private func loadCachedMessages() async {
        logger.info("PHASE 0: Loading cached messages for instant display")

        guard let database = appState.mlsDatabase,
              let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID else {
            logger.warning("Cannot load cached messages: database or userDID not available")
            return
        }

        do {
            let cachedModels = try await storage.fetchMessagesForConversation(
                conversationId,
                currentUserDID: currentUserDID,
                database: database,
                limit: 50
            )

            guard !cachedModels.isEmpty else {
                logger.debug("No cached messages found")
                return
            }

            logger.info("Found \(cachedModels.count) cached messages")

            // Convert MLSMessageModel to Message objects for display
            var cachedMessages: [Message] = []

            for model in cachedModels {
                guard let plaintext = model.plaintext, !model.plaintextExpired else {
                    logger.debug("Skipping message \(model.messageID): no plaintext or expired")
                    continue
                }

                let isCurrentUser = isMessageFromCurrentUser(senderDID: model.senderID)

                let message = Message(
                    id: model.messageID,
                    user: User(
                        id: model.senderID,
                        name: isCurrentUser ? "You" : formatDID(model.senderID),
                        avatarURL: nil,
                        isCurrentUser: isCurrentUser
                    ),
                    status: .sent,
                    createdAt: model.timestamp,
                    text: plaintext
                )

                cachedMessages.append(message)

                // Store embed in map if available
                if let embed = model.parsedEmbed {
                    await MainActor.run {
                        embedsMap[model.messageID] = embed
                    }
                }
            }

            // Update UI with cached messages
            await MainActor.run {
                messages = cachedMessages
            }

            logger.info("Displayed \(cachedMessages.count) cached messages")

        } catch {
            logger.error("Failed to load cached messages: \(error.localizedDescription)")
        }
    }

    private func loadMoreMessages() async {
        logger.debug("Loading more messages (pagination not yet implemented)")
        // TODO: Implement pagination using cursor
    }

    private func loadMemberCount() async {
        guard let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID else {
            logger.warning("Cannot load member count: currentUserDID not available")
            return
        }

        guard let database = appState.mlsDatabase else {
            logger.error("Cannot load member count: database not available")
            return
        }

        do {
            let count = try await storage.getMemberCount(
                conversationID: conversationId,
                currentUserDID: currentUserDID,
                database: database
            )
            await MainActor.run {
                memberCount = count
            }
            logger.info("Loaded member count: \(count) for conversation \(conversationId)")
        } catch {
            logger.error("Failed to load member count: \(error.localizedDescription)")
        }
    }

    private func sendMLSMessage(text: String, embed: MLSEmbedData?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || embed != nil else {
            logger.debug("Skipping empty message")
            return
        }

        // 🔒 CRITICAL: Capture sender DID at START, before any account switches
        // If user switches accounts mid-send, we need the ORIGINAL sender's DID for caching
        guard let senderDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID else {
            logger.error("Cannot send message: sender DID not available")
            return
        }

        _ = await ensureConversationMetadata()

        await MainActor.run {
            isSendingMessage = true
        }

        defer {
            Task { @MainActor in
                isSendingMessage = false
            }
        }

        logger.debug("Sending MLS message: \(trimmed.prefix(50))... with embed: \(embed != nil)")
        logger.debug("🔒 Sender DID captured: \(senderDID)")

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
                plaintext: trimmed,
                embed: embed
            )

            logger.debug("Message sent successfully: \(messageId)")

            // Extract timestamp before MainActor.run
            let timestamp = receivedAt.date

            // Ensure conversation exists in database before saving sent message
            // Use captured sender DID (not current user) in case of account switch during send
            if let database = appState.mlsDatabase {
                // Ensure conversation exists first (prevents foreign key constraint violations)
                if let convo = manager.conversations[conversationId] {
                    do {
                        try await storage.ensureConversationExists(
                            conversationID: conversationId,
                            groupID: convo.groupId,
                            database: database
                        )
                        logger.debug("✅ Conversation exists, saving sent message plaintext")
                    } catch {
                        logger.error("❌ Failed to ensure conversation exists before saving: \(error.localizedDescription)")
                    }
                }

                // Now save the plaintext (can't decrypt own messages in MLS, so we cache on send)
                do {
                    try await storage.savePlaintextForMessage(
                        messageID: messageId,
                        conversationID: conversationId,
                        plaintext: trimmed,
                        senderID: senderDID,  // ← Use captured sender DID
                        currentUserDID: senderDID,  // ← Use captured sender DID (not current user!)
                        embed: embed,
                        epoch: 0,  // Temporary - updated when actual server message arrives
                        sequenceNumber: 0,  // Temporary - updated when actual server message arrives
                        timestamp: Date(),  // Local send time, will be updated with server timestamp
                        database: database
                    )
                    logger.info("✅ Saved plaintext under sender DID: \(senderDID) for message: \(messageId)")
                } catch {
                    logger.error("Failed to save sent message plaintext: \(error.localizedDescription)")
                }
            } else {
                logger.error("Cannot save plaintext: database not available")
            }

            await MainActor.run {
                let newMessage = Message(
                    id: messageId,
                    user: User(
                        id: appState.userDID ?? "",
                        name: "You",
                        avatarURL: nil,
                        isCurrentUser: true
                    ),
                    status: .sent,
                    createdAt: timestamp,
                    text: trimmed
                    // TODO: Add embed data to Message model for rendering
                )

                // Only add if not already present (SSE might have added it)
                if !messages.contains(where: { $0.id == messageId }) {
                    messages.append(newMessage)
                    logger.debug("Added message to UI: \(messageId)")
                } else {
                    logger.debug("Message already in UI (from SSE): \(messageId)")
                }

                // Clear composer state after successful send
                composerText = ""
                attachedEmbed = nil
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
        logger.debug("Starting SSE subscription for real-time messages")

        Task {
            // Use centralized event stream manager from AppState
            guard let streamManager = await appState.getMLSEventStreamManager() else {
                logger.error("Failed to get MLS event stream manager")
                return
            }

            // Store reference for local cleanup
            await MainActor.run {
                eventStreamManager = streamManager
            }

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
                            self.logger.error("SSE error: \(error.localizedDescription)")
                        }
                    }
                )
            )
        }
    }
    
    private func stopMessagePolling() {
        logger.debug("Stopping SSE subscription for conversation: \(conversationId)")
        // Stop subscription for this conversation
        // Note: Manager is owned by AppState and shared across views
        // We only stop the subscription for THIS conversation, not all subscriptions
        eventStreamManager?.stop(conversationId)
        hasStartedSubscription = false
        // Don't nil out eventStreamManager - it's shared and owned by AppState
    }
    
    @MainActor
    private func handleNewMessage(_ event: BlueCatbirdMlsStreamConvoEvents.MessageEvent) async {
        logger.debug("🔍 MLS_OWNERSHIP: ====== Processing SSE message \(event.message.id) ======")

        _ = await ensureConversationMetadata()

        // CRITICAL FIX: Check if message is already displayed to prevent duplicate decryption
        // This prevents "No ciphertext available" errors for messages that were already processed
        if messages.contains(where: { $0.id == event.message.id }) {
            logger.debug("🔍 Message \(event.message.id) already displayed, skipping duplicate decryption")
            return
        }

        // Get current user DID for plaintext isolation
        guard let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID else {
            logger.error("Cannot process SSE message: currentUserDID not available")
            return
        }

        // CRITICAL FIX #1: Ensure conversation exists in database (SSE path)
        // This prevents foreign key constraint violations when storing decrypted messages
        if let database = appState.mlsDatabase {
            // Get groupID from manager's conversations cache (same as receive path)
            guard let manager = await appState.getMLSConversationManager() else {
                logger.error("Cannot ensure conversation exists: manager not available")
                return
            }

            if let convo = manager.conversations[conversationId] {
                do {
                    try await storage.ensureConversationExists(
                        conversationID: conversationId,
                        groupID: convo.groupId,
                        database: database
                    )
                    logger.debug("✅ Conversation verified for SSE message")
                } catch {
                    logger.error("❌ Failed to ensure conversation exists: \(error.localizedDescription)")
                    return
                }
            } else {
                logger.warning("⚠️ Conversation \(conversationId) not found in manager cache (SSE path)")
            }
        }

        // Decrypt the message
        guard let manager = await appState.getMLSConversationManager() else {
            return
        }

        do {
            guard let database = appState.mlsDatabase else {
                logger.error("Cannot process SSE message: database not available")
                return
            }

            // Fetch or decrypt to get sender DID (from MLS credentials)
            var displayText = ""
            var embed: MLSEmbedData?
            var senderDID: String

            if let storedSender = try? await storage.fetchSenderForMessage(event.message.id, currentUserDID: currentUserDID, database: database),
               let storedPlaintext = try? await storage.fetchPlaintextForMessage(event.message.id, currentUserDID: currentUserDID, database: database) {
                // Already decrypted and cached
                senderDID = storedSender
                displayText = storedPlaintext
                embed = try? await storage.fetchEmbedForMessage(event.message.id, currentUserDID: currentUserDID, database: database)
                logger.debug("Using stored data for SSE message \(event.message.id) (hasEmbed: \(embed != nil))")
            } else {
                // Need to decrypt - this extracts sender from MLS credentials
                logger.debug("No cached data for SSE message \(event.message.id), decrypting from server")
                let decryptedMessage = try await manager.decryptMessage(event.message)
                senderDID = decryptedMessage.senderDID
                displayText = decryptedMessage.text
                embed = decryptedMessage.embed

                logger.debug("Decrypted SSE message \(event.message.id) from \(senderDID) (hasEmbed: \(embed != nil))")
            }

            let isCurrentUser = isMessageFromCurrentUser(senderDID: senderDID)
            logger.info("🔍 MLS_OWNERSHIP: SSE result for message \(event.message.id): isCurrentUser = \(isCurrentUser)")

            // CRITICAL: Check if this is from current user AFTER decryption
            if isCurrentUser && displayText.isEmpty {
                logger.warning("⚠️ SSE message \(event.message.id) is from current user but has no plaintext")
                logger.warning("   Self-decryption is impossible by MLS design - skipping SSE processing")
                logger.warning("   This message will be added by sendMLSMessage with cached plaintext")
                return
            }

            // Store embed in map for later rendering
            if let embed = embed {
                embedsMap[event.message.id] = embed
            }

            let newMessage = Message(
                id: event.message.id,
                user: User(
                    id: senderDID,
                    name: isCurrentUser ? "You" : formatDID(senderDID),
                    avatarURL: nil,
                    isCurrentUser: isCurrentUser
                ),
                status: .sent,
                createdAt: event.message.createdAt.date,
                text: displayText
            )

            logger.info("🔍 MLS_OWNERSHIP: Created SSE Message object - user.name: '\(newMessage.user.name ?? "nil")', user.isCurrentUser: \(newMessage.user.isCurrentUser)")

            // Add to messages if not already present
            if !messages.contains(where: { $0.id == newMessage.id }) {
                messages.append(newMessage)
                logger.debug("🔍 MLS_OWNERSHIP: Added new message from SSE to UI")
            } else {
                logger.debug("🔍 MLS_OWNERSHIP: SSE message already in UI, skipping")
            }

        } catch {
            logger.error("Failed to process SSE message: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    private func handleReaction(_ event: BlueCatbirdMlsStreamConvoEvents.ReactionEvent) async {
        logger.debug("Received reaction via SSE: \(event.action) \(event.reaction) on \(event.messageId)")
        
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
        logger.info("Leaving conversation: \(conversationId)")

        Task {
            do {
                guard let manager = await appState.getMLSConversationManager() else {
                    await MainActor.run {
                        logger.error("Failed to get MLS conversation manager")
                        sendError = "MLS service not available. Please try restarting the app."
                        showingSendError = true
                    }
                    return
                }

                try await manager.leaveConversation(convoId: conversationId)

                await MainActor.run {
                    logger.info("Successfully left conversation: \(conversationId)")

                    // Remove conversation from AppState
                    appState.mlsConversations.removeAll { $0.id == conversationId }

                    // Navigate back to conversation list
                    // Try dismissing as a sheet first, then fall back to popping navigation
                    appState.navigationManager.navigate(to: .chatTab)
                }
            } catch {
                await MainActor.run {
                    logger.error("Failed to leave conversation: \(error.localizedDescription)")
                    sendError = "Failed to leave conversation: \(error.localizedDescription)"
                    showingSendError = true
                }
            }
        }
    }

    /// Perform key package desync recovery by generating fresh key package and requesting rejoin
    @MainActor
    private func performRecovery() async {
        logger.info("Starting key package desync recovery for conversation: \(conversationId)")
        recoveryState = .inProgress

        guard let manager = await appState.getMLSConversationManager(),
              let apiClient = await appState.getMLSAPIClient() else {
            logger.error("Recovery failed: MLS services unavailable")
            recoveryState = .failed("MLS service unavailable. Please restart the app.")
            showingRecoveryError = true
            return
        }

        do {
            // Step 1: Generate fresh key package
            logger.debug("Generating fresh key package for recovery...")
            let keyPackageData = try await manager.createKeyPackage()
            logger.info("Generated fresh key package (\(keyPackageData.count) bytes)")

            // Step 2: Request rejoin from server
            logger.debug("Requesting rejoin from server...")
            let (requestId, pending) = try await apiClient.requestRejoin(
                convoId: conversationId,
                keyPackageData: keyPackageData,
                reason: "Key package desync recovery"
            )

            logger.info("Rejoin request submitted - ID: \(requestId), pending: \(pending)")

            // Step 3: Mark success
            recoveryState = .success
            logger.info("Recovery successful - reinitializing conversation")

            // Step 4: Reload conversation and messages
            await loadConversationAndMessages()

            // Reset recovery state after successful reload
            recoveryState = .none

        } catch {
            logger.error("Recovery failed: \(error.localizedDescription)")
            recoveryState = .failed(error.localizedDescription)
            showingRecoveryError = true
        }
    }

    private func isMessageFromCurrentUser(senderDID: String) -> Bool {
        logger.debug("🔍 MLS_OWNERSHIP: Checking message ownership")
        logger.debug("🔍 MLS_OWNERSHIP: Sender DID raw = '\(senderDID)'")
        
        // Use auth state DID as source of truth (currentUserDID may not be set yet)
        let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID
        logger.debug("🔍 MLS_OWNERSHIP: Current DID raw = '\(currentUserDID ?? "NIL")'")

        guard let currentUserDID = currentUserDID else {
            logger.warning("🔍 MLS_OWNERSHIP: ❌ currentUserDID is nil, returning false")
            return false
        }

        // Normalize DIDs for comparison (trim whitespace, case-insensitive)
        let normalizedSender = senderDID.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased()
        let normalizedCurrent = currentUserDID.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased()

        logger.debug("🔍 MLS_OWNERSHIP: Sender DID normalized = '\(normalizedSender)'")
        logger.debug("🔍 MLS_OWNERSHIP: Current DID normalized = '\(normalizedCurrent)'")

        let isMatch = normalizedSender == normalizedCurrent
        logger.info("🔍 MLS_OWNERSHIP: \(isMatch ? "✅ MATCH" : "❌ NO MATCH") - isCurrentUser = \(isMatch)")

        return isMatch
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
    @Previewable @Environment(AppState.self) var appState
    NavigationStack {
        MLSConversationDetailView(conversationId: "test-conversation-id")
            .environment(AppStateManager.shared)
    }
}

#endif
