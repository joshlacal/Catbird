import CatbirdMLSCore
import GRDB
import OSLog
import Petrel
import SwiftUI

#if os(iOS)
  //import MCEmojiPicker
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

// MARK: - Message Error Info

/// Information about message processing errors
struct MessageErrorInfo: Equatable {
  let processingError: String?
  let processingAttempts: Int
  let validationFailureReason: String?
}

// MARK: - MLS Conversation Detail View

/// Chat interface for an end-to-end encrypted MLS conversation with E2EE badge
struct MLSConversationDetailView: View {
  @Environment(AppState.self) var appState
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dismiss) var dismiss
  @Environment(\.scenePhase) private var scenePhase

  let conversationId: String

  @State private var viewModel: MLSConversationDetailViewModel?
  @State private var conversationModel: MLSConversationModel?
  @State private var isLoadingMessages = false
  @State private var isLoadingProfiles = true
  @State private var memberCount: Int = 0
  @State private var members: [MLSMemberModel] = []
  @State var participantProfiles: [String: MLSProfileEnricher.ProfileData] = [:]
  @State private var isSendingMessage = false
  @State private var showingMemberManagement = false
  @State private var showingEncryptionInfo = false
  @State private var eventStreamManager: MLSEventStreamManager?
  @State private var stateObserver: MLSStateObserver?  // Observer for encrypted MLS events (reactions, read receipts, typing)
  @State private var typingUsers: Set<String> = []
  @State private var serverError: String?
  @State private var hasStartedSubscription = false
  @State var sendError: String?
  @State var showingSendError = false
  @State private var showingLeaveConfirmation = false
  @State private var showingAdminDashboard = false
  @State private var showingReportsView = false
  @State private var pendingReportsCount = 0
  @State private var isCurrentUserAdmin = false
  @State private var recoveryState: RecoveryState = .none
  @State private var showingRecoveryError = false
  @State private var showingReportSheet = false
  @State private var reportMessageId: String?
  @State private var reportMemberDID: String?
  @State private var reportMemberName: String?
  @State private var isViewActive = false
  @State private var unifiedDataSource: MLSConversationDataSource?
  @State private var showingEmojiPicker = false
  @State private var selectedEmoji = ""
  @State private var emojiPickerMessageID: String?

  // Message state management
  @State private var messages: [Message] = []
  @State private var messageOrdering: [String: MessageOrderKey] = [:]
  @State private var embedsMap: [String: MLSEmbedData] = [:]
  @State private var messageErrorsMap: [String: MessageErrorInfo] = [:]
  @State private var messageReactionsMap: [String: [MLSMessageReaction]] = [:]
  @State private var messageReadByMap: [String: Set<String>] = [:]  // messageId -> set of DIDs who read it
  @State private var isLoadingMoreMessages = false
  @State private var hasMoreMessages = true

  // Composer state
  @State private var composerText = ""
  @State private var attachedEmbed: MLSEmbedData?

  // Delete/Report state
  @State private var messageToReport: Message?
  @State private var messageToDelete: Message?
  @State private var showingDeleteAlert = false

  // Polling timer for fallback when SSE is silent (every 10 seconds)
  private let messagePollingTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSConversationDetail")
  private let storage = MLSStorage.shared

  private struct MessageOrderKey: Equatable, Comparable {
    let epoch: Int
    let sequence: Int
    let timestamp: Date

    static func < (lhs: MessageOrderKey, rhs: MessageOrderKey) -> Bool {
      if lhs.epoch != rhs.epoch {
        return lhs.epoch < rhs.epoch
      }
      if lhs.sequence != rhs.sequence {
        return lhs.sequence < rhs.sequence
      }
      return lhs.timestamp < rhs.timestamp
    }
  }

  // MLS conversations are presented inside the Chat tab's NavigationStack.
  // Use that shared path so embeds can navigate to posts/threads.
  private var chatNavigationPath: Binding<NavigationPath> {
    appState.navigationManager.pathBinding(for: 4)
  }

  private var mainContent: some View {
    ZStack {
      // Use unified UICollectionView-based chat
      if #available(iOS 16.0, *), let dataSource = unifiedDataSource {
        VStack(spacing: 0) {
          ChatCollectionViewBridge(
            dataSource: dataSource,
            navigationPath: chatNavigationPath,
            onMessageLongPress: { message in
              handleMessageLongPress(message)
            },
            onRequestEmojiPicker: { messageID in
              emojiPickerMessageID = messageID
              showingEmojiPicker = true
            }
          )
          .ignoresSafeArea()
          .onChange(of: selectedEmoji) { _, newEmoji in
            guard let messageID = emojiPickerMessageID, !newEmoji.isEmpty else { return }
            dataSource.addReaction(messageID: messageID, emoji: newEmoji)
            showingEmojiPicker = false
            selectedEmoji = ""
            emojiPickerMessageID = nil
          }
          .onChange(of: showingEmojiPicker) { _, isPresented in
            if !isPresented {
              selectedEmoji = ""
              emojiPickerMessageID = nil
            }
          }
          .task {
            await dataSource.loadMessages()
          }

          // Input bar at bottom with keyboard avoidance
          mlsInputBar
        }
        .customEmojiPicker(isPresented: $showingEmojiPicker) { emoji in
          selectedEmoji = emoji
        }
      } else {
        // Fallback for iOS < 16
        VStack(spacing: DesignTokens.Spacing.base) {
          Image(systemName: "message.fill")
            .font(.system(size: 48))
            .foregroundColor(.secondary)
          Text("Please update to iOS 16 or later for the full chat experience.")
            .designBody()
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      if isLoadingMessages && !isLoadingProfiles {
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

  /// Loading placeholder shown while profiles are loading to avoid DID flicker
  @ViewBuilder
  private var chatLoadingPlaceholder: some View {
    ScrollView {
      VStack(spacing: 16) {
        ForEach(0..<5, id: \.self) { index in
          HStack(alignment: .top, spacing: 12) {
            // Avatar placeholder
            Circle()
              .fill(Color.gray.opacity(0.2))
              .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 6) {
              // Name placeholder
              RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.2))
                .frame(width: CGFloat.random(in: 60...100), height: 12)

              // Message bubble placeholder
              RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.15))
                .frame(width: CGFloat.random(in: 120...240), height: CGFloat.random(in: 32...64))
            }

            Spacer()
          }
          .padding(.horizontal)
          // Alternate alignment for visual variety
          .scaleEffect(x: index % 2 == 0 ? 1 : -1, y: 1)
        }
      }
      .padding(.vertical)
    }
    .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
  }

  // MARK: - MLS Input Bar for Unified Chat

  @available(iOS 16.0, *)
  @ViewBuilder
  private var mlsInputBar: some View {
    MLSMessageComposerView(
      text: Binding(
        get: { unifiedDataSource?.draftText ?? "" },
        set: { unifiedDataSource?.draftText = $0 }
      ),
      attachedEmbed: Binding(
        get: { unifiedDataSource?.attachedEmbed },
        set: { unifiedDataSource?.attachedEmbed = $0 }
      ),
      conversationId: conversationId,
      onSend: { text, embed in
        Task {
          if let dataSource = unifiedDataSource {
            dataSource.attachedEmbed = embed
            await dataSource.sendMessage(text: text)
          }
        }
      }
    )
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  // MARK: - Message Long Press Handler

  private func handleMessageLongPress(_ message: MLSMessageAdapter) {
    let generator = UIImpactFeedbackGenerator(style: .soft)
    generator.impactOccurred()

    // Store for potential report action
    reportMessageId = message.id
    reportMemberDID = message.senderID
    reportMemberName = message.senderDisplayName
  }

  // MARK: - Native MLS Message List

  @ViewBuilder
  private var mlsMessageList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 4) {
          // Pagination loader at top
          if hasMoreMessages && !messages.isEmpty {
            ProgressView()
              .padding()
              .onAppear {
                Task { await loadMoreMessages() }
              }
          }

          // Messages in chronological order (oldest first, newest at bottom)
          ForEach(messages) { message in
            MLSMessageRowView(
              message: message,
              conversationID: conversationId,
              reactions: messageReactionsMap[message.id] ?? [],
              readByCount: message.user.isCurrentUser
                ? messageReadByMap[message.id]?.count ?? 0 : 0,
              currentUserDID: appState.userDID,
              participantProfiles: participantProfiles,
              onAddReaction: { messageId, emoji in
                addReaction(messageId: messageId, emoji: emoji)
              },
              onRemoveReaction: { messageId, emoji in
                removeReaction(messageId: messageId, emoji: emoji)
              },
              navigationPath: chatNavigationPath
            )
            .id(message.id)
            .padding(.horizontal)
          }
        }
        .padding(.vertical, 8)
      }
      .defaultScrollAnchor(.bottom)
      .onChange(of: messages.count) { _, _ in
        // Scroll to newest message when new messages arrive
        if let lastMessage = messages.last {
          withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(lastMessage.id, anchor: .bottom)
          }
        }
      }
    }
    .safeAreaInset(edge: .bottom) {
      VStack(spacing: 0) {
        // Typing indicator
        if !typingUsers.isEmpty {
          typingIndicatorView
        }

        MLSMessageComposerView(
          text: $composerText,
          attachedEmbed: $attachedEmbed,
          conversationId: conversationId,
          onSend: { text, embed in
            Task { await sendMLSMessage(text: text, embed: embed) }
          }
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
      }
    }
    .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
  }

  /// Typing indicator view showing which users are currently typing
  @ViewBuilder
  private var typingIndicatorView: some View {
    let typingNames =
      typingUsers
      .filter { $0 != appState.userDID }  // Don't show self typing
      .compactMap { did -> String? in
        participantProfiles[did]?.displayName ?? participantProfiles[did]?.handle
      }

    if !typingNames.isEmpty {
      HStack(spacing: DesignTokens.Spacing.xs) {
        // Animated dots
        HStack(spacing: 3) {
          ForEach(0..<3, id: \.self) { index in
            Circle()
              .fill(Color.secondary)
              .frame(width: 6, height: 6)
              .opacity(0.7)
              .animation(
                .easeInOut(duration: 0.5)
                  .repeatForever(autoreverses: true)
                  .delay(Double(index) * 0.15),
                value: typingUsers.count
              )
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
          RoundedRectangle(cornerRadius: 12)
            .fill(Color.gray.opacity(0.2))
        )

        Text(
          typingNames.count == 1
            ? "\(typingNames[0]) is typing..."
            : "\(typingNames.count) people are typing..."
        )
        .designCaption()
        .foregroundColor(.secondary)

        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 4)
      .transition(.move(edge: .bottom).combined(with: .opacity))
      .animation(.easeInOut(duration: 0.2), value: typingUsers.count)
    }
  }

  // MARK: - Reaction Handling

  private func addReaction(messageId: String, emoji: String) {
    Task {
      guard let manager = await appState.getMLSConversationManager() else { return }

      do {
        // Use encrypted reaction (E2EE via MLS)
        _ = try await manager.sendEncryptedReaction(
          emoji: emoji,
          to: messageId,
          in: conversationId,
          action: .add
        )

        // Optimistic local update
        let reaction = MLSMessageReaction(
          messageId: messageId,
          reaction: emoji,
          senderDID: appState.userDID ?? "",
          reactedAt: Date()
        )

        await MainActor.run {
          var reactions = messageReactionsMap[messageId] ?? []
          reactions.append(reaction)
          messageReactionsMap[messageId] = reactions
        }

        // Persist to local storage
        persistReaction(
          messageId: messageId, emoji: emoji, actorDID: appState.userDID ?? "", action: "add")
      } catch {
        logger.error("Failed to add encrypted reaction: \(error.localizedDescription)")
      }
    }
  }

  private func removeReaction(messageId: String, emoji: String) {
    Task {
      guard let manager = await appState.getMLSConversationManager() else { return }

      do {
        // Use encrypted reaction removal (E2EE via MLS)
        _ = try await manager.sendEncryptedReaction(
          emoji: emoji,
          to: messageId,
          in: conversationId,
          action: .remove
        )

        // Optimistic local update
        await MainActor.run {
          if var reactions = messageReactionsMap[messageId] {
            reactions.removeAll { $0.reaction == emoji && $0.senderDID == appState.userDID }
            if reactions.isEmpty {
              messageReactionsMap.removeValue(forKey: messageId)
            } else {
              messageReactionsMap[messageId] = reactions
            }
          }
        }

        // Persist removal to local storage
        persistReaction(
          messageId: messageId, emoji: emoji, actorDID: appState.userDID ?? "", action: "remove")
      } catch {
        logger.error("Failed to remove encrypted reaction: \(error.localizedDescription)")
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
    contentWithNavigation
      .task {
        await setupView()
      }
      .onDisappear {
        isViewActive = false
        stopMessagePolling()
        // Cleanup state observer
        Task {
          if let observer = stateObserver,
            let manager = await appState.getMLSConversationManager()
          {
            manager.removeObserver(observer)
          }
          await MainActor.run {
            stateObserver = nil
          }
        }
      }
      .onReceive(messagePollingTimer) { _ in
        guard isViewActive else { return }
        Task {
          await checkForNewMessages()
        }
      }
      .onChange(of: scenePhase) { oldPhase, newPhase in
        if newPhase == .active && isViewActive {
          logger.info("📱 App became active - triggering immediate message check")
          Task {
            // Immediate fetch to catch up
            await checkForNewMessages()

            // Ensure SSE is running
            if !hasStartedSubscription {
              startMessagePolling()
              hasStartedSubscription = true
            }
          }
        }
      }
  }

  @ViewBuilder
  private var contentWithNavigation: some View {
    mainContent
      .navigationTitle(navigationTitle)
      .navigationBarTitleDisplayMode(.inline)
      //            .themedNavigationBar(appState.themeManager)
      .toolbar(.hidden, for: .tabBar)
      .toolbar {
        conversationToolbar
      }
      .sheet(isPresented: $showingMemberManagement) {
        memberManagementSheet
      }
      .sheet(isPresented: $showingEncryptionInfo) {
        encryptionInfoSheet
      }
      .sheet(isPresented: $showingAdminDashboard) {
        adminDashboardSheet
      }
      .sheet(isPresented: $showingReportsView) {
        reportsSheet
      }
      .sheet(isPresented: $showingReportSheet) {
        reportMemberSheet
      }
      .alert("Send Failed", isPresented: $showingSendError) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(sendError ?? "Failed to send message. Please try again.")
      }
      .alert("Leave Conversation", isPresented: $showingLeaveConfirmation) {
        Button("Cancel", role: .cancel) {}
        Button("Leave", role: .destructive) {
          leaveConversation()
        }
      } message: {
        Text(
          "Are you sure you want to leave this conversation? You will no longer be able to send or receive messages."
        )
      }
      .alert("Recovery Failed", isPresented: $showingRecoveryError) {
        Button("Retry") {
          Task { await performRecovery() }
        }
        Button("Cancel", role: .cancel) {
          recoveryState = .none
        }
      } message: {
        recoveryFailedMessage
      }
  }

  @ViewBuilder
  private var memberManagementSheet: some View {
    NavigationStack {
      MLSMemberManagementView(conversationId: conversationId)
    }
  }

  @ViewBuilder
  private var adminDashboardSheet: some View {
    if #available(iOS 26.0, *),
      let apiClient = viewModel?.apiClient,
      let conversationManager = viewModel?.conversationManager
    {
      NavigationStack {
        MLSAdminDashboardView(
          conversationId: conversationId,
          apiClient: apiClient,
          conversationManager: conversationManager
        )
      }
    }
  }

  @ViewBuilder
  private var reportsSheet: some View {
    if #available(iOS 26.0, *),
      let conversationManager = viewModel?.conversationManager
    {
      NavigationStack {
        MLSReportsView(
          conversationId: conversationId,
          conversationManager: conversationManager
        )
      }
    }
  }

  @ViewBuilder
  private var reportMemberSheet: some View {
    if let memberDID = reportMemberDID,
      let conversationManager = viewModel?.conversationManager
    {
      NavigationStack {
        MLSReportMemberSheet(
          conversationId: conversationId,
          memberDid: memberDID,
          memberDisplayName: reportMemberName ?? memberDID,
          conversationManager: conversationManager
        )
      }
    }
  }

  @ViewBuilder
  private var recoveryFailedMessage: some View {
    if case .failed(let errorMessage) = recoveryState {
      Text(errorMessage)
    } else {
      Text("Failed to rejoin conversation. Please try again.")
    }
  }

  private func setupView() async {
    isViewActive = true
    if viewModel == nil {
      guard let database = appState.mlsDatabase,
        let apiClient = await appState.getMLSAPIClient(),
        let conversationManager = await appState.getMLSConversationManager()
      else {
        logger.error("Cannot initialize view: dependencies not available")
        sendError = "MLS service not available. Please restart the app."
        showingSendError = true
        await MainActor.run { isLoadingProfiles = false }
        return
      }

      let newViewModel = MLSConversationDetailViewModel(
        conversationId: conversationId,
        database: database,
        apiClient: apiClient,
        conversationManager: conversationManager
      )
      viewModel = newViewModel

      // Create unified data source that pulls from storage
      unifiedDataSource = MLSConversationDataSource(
        conversationId: conversationId,
        currentUserDID: appState.userDID ?? "",
        appState: appState
      )

      // 🔍 [MEMBER_MGMT] Load conversation data so members are available (fire-and-forget)
      // Run on background to avoid blocking UI
      logger.debug("🔍 [MEMBER_MGMT] Loading conversation via ViewModel")
      Task.detached(priority: .userInitiated) { [viewModel] in
        await viewModel?.loadConversation()
      }
    } else if unifiedDataSource == nil {
      unifiedDataSource = MLSConversationDataSource(
        conversationId: conversationId,
        currentUserDID: appState.userDID ?? "",
        appState: appState
      )
    }

    // Setup observer for encrypted MLS events (reactions, read receipts, typing)
    await setupStateObserver()

    // Fire-and-forget MLS pipeline that outlives the view
    // This ensures MLS state updates complete even if user navigates away
    Task.detached(priority: .userInitiated) { [self] in
      await self.runConversationPipeline()
    }

    // UI-only work that can be cancelled if view disappears
    await loadMemberCount()
    await loadParticipantProfiles()

    // Hide loading state after profiles are loaded
    await MainActor.run {
      isLoadingProfiles = false
    }

    await checkAdminStatus()
    await loadPendingReportsCount()

    // Mark all messages in this conversation as read
    await markMessagesAsRead()

    // Clear membership change badge
    await clearMembershipChangeBadge()
  }

  /// Setup observer for encrypted MLS state events (reactions, read receipts, typing)
  private func setupStateObserver() async {
    guard stateObserver == nil else { return }  // Already setup

    guard let manager = await appState.getMLSConversationManager() else {
      logger.warning("Cannot setup state observer: conversation manager not available")
      return
    }

    let convoId = conversationId
    let observer = MLSStateObserver { [weak appState] event in
      Task { @MainActor in
        guard let appState = appState else { return }
        await self.handleMLSStateEvent(event, for: convoId, userDID: appState.userDID)
      }
    }

    stateObserver = observer
    manager.addObserver(observer)
    logger.info("📡 Registered MLS state observer for encrypted reactions/read receipts/typing")
  }

  /// Handle encrypted MLS state events (reactions, read receipts, typing indicators)
  @MainActor
  private func handleMLSStateEvent(_ event: MLSStateEvent, for convoId: String, userDID: String?)
    async
  {
    switch event {
    case .reactionReceived(let eventConvoId, let messageId, let emoji, let senderDID, let action):
      // Only handle events for this conversation
      guard eventConvoId == convoId else { return }

      // Skip our own reactions (already handled optimistically)
      if senderDID == userDID { return }

      logger.debug(
        "📬 Received encrypted reaction: \(emoji) on \(messageId) from \(senderDID) action=\(action)"
      )

      if action == "add" {
        let reaction = MLSMessageReaction(
          messageId: messageId,
          reaction: emoji,
          senderDID: senderDID,
          reactedAt: Date()
        )

        var reactions = messageReactionsMap[messageId] ?? []
        // Prevent duplicates
        if !reactions.contains(where: { $0.reaction == emoji && $0.senderDID == senderDID }) {
          reactions.append(reaction)
          messageReactionsMap[messageId] = reactions
          logger.debug(
            "Added encrypted reaction '\(emoji)' from \(senderDID) to message \(messageId)")

          // Ensure profile is loaded for the reactor
          ensureProfileLoaded(for: senderDID)
        }
      } else if action == "remove" {
        if var reactions = messageReactionsMap[messageId] {
          reactions.removeAll { $0.reaction == emoji && $0.senderDID == senderDID }
          if reactions.isEmpty {
            messageReactionsMap.removeValue(forKey: messageId)
          } else {
            messageReactionsMap[messageId] = reactions
          }
          logger.debug(
            "Removed encrypted reaction '\(emoji)' from \(senderDID) on message \(messageId)")
        }
      }

    case .readReceiptReceived(let eventConvoId, let messageId, let senderDID):
      // Only handle events for this conversation
      guard eventConvoId == convoId else { return }

      // Skip our own read receipts
      if senderDID == userDID { return }

      logger.debug("📬 Received encrypted read receipt for \(messageId) from \(senderDID)")

      // Update read-by map for the message
      var readers = messageReadByMap[messageId] ?? []
      readers.insert(senderDID)
      messageReadByMap[messageId] = readers

    case .typingChanged(let eventConvoId, let typingUsersList):
      // Only handle events for this conversation
      guard eventConvoId == convoId else { return }

      // Update typing users (excluding self)
      typingUsers = Set(typingUsersList.filter { $0 != userDID })

    default:
      // Ignore other events
      break
    }
  }

  @ToolbarContentBuilder
  private var conversationToolbar: some ToolbarContent {
    ToolbarItem(placement: .principal) {
      encryptionStatusHeader
    }

    // Note: Admin dashboard and reports buttons are currently disabled.
    // if #available(iOS 26.0, *), isCurrentUserAdmin {
    //     ToolbarItem(placement: .primaryAction) {
    //         Button {
    //             showingAdminDashboard = true
    //         } label: {
    //             Image(systemName: "chart.bar.fill")
    //                 .accessibilityLabel("Admin Dashboard")
    //         }
    //     }
    //
    //     ToolbarItem(placement: .primaryAction) {
    //         Button {
    //             showingReportsView = true
    //         } label: {
    //             Image(systemName: "doc.text.fill")
    //                 .overlay(alignment: .topTrailing) {
    //                     if pendingReportsCount > 0 {
    //                         Circle()
    //                             .fill(Color.red)
    //                             .frame(width: 8, height: 8)
    //                             .offset(x: 4, y: -4)
    //                     }
    //                 }
    //                 .accessibilityLabel(
    //                     pendingReportsCount > 0 ?
    //                         "\(pendingReportsCount) pending reports" :
    //                         "Reports"
    //                 )
    //         }
    //     }
    // }

    ToolbarItem(placement: .primaryAction) {
      Menu {
        if canShowMemberManagement {
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

  // MARK: - Admin Status and Reports

  @MainActor
  private func checkAdminStatus() async {
    guard let viewModel = viewModel else { return }

    let currentUserDid = appState.userDID
    var isAdmin = false

    if let conversation = viewModel.conversation,
      let member = conversation.members.first(where: { $0.did.description == currentUserDid })
    {
      isAdmin = member.isAdmin
    } else {
      isAdmin = await viewModel.conversationManager.isCurrentUserAdmin(of: conversationId)
    }

    isCurrentUserAdmin = isAdmin
    logger.debug("Admin status checked: \(self.isCurrentUserAdmin)")
  }

  @MainActor
  private func loadPendingReportsCount() async {
    guard isCurrentUserAdmin,
      let conversationManager = viewModel?.conversationManager
    else {
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

        // Show partial history note when user joined via External Commit at epoch > 1
        if let model = conversationModel,
           model.joinMethod == .externalCommit,
           model.joinEpoch > 1
        {
          HStack(spacing: 4) {
            Image(systemName: "clock.arrow.circlepath")
              .font(.system(size: 9))
              .foregroundColor(.secondary)

            Text("Partial History")
              .font(.system(size: 9, weight: .medium))
              .foregroundColor(.secondary)
          }
          .help("Messages before epoch \(model.joinEpoch) are unavailable due to device recovery.")
        }
      }
    }
    .onTapGesture {
      showingEncryptionInfo = true
    }
    .accessibilityLabel("End-to-end encrypted conversation")
    .accessibilityHint("Tap to view encryption details")
  }

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
          InfoRow(
            label: "Group ID",
            value: conversationModel?.groupID.base64EncodedString().prefix(16).description
              ?? "Unknown")
          InfoRow(label: "Epoch", value: "\(conversationModel?.epoch ?? 0)")
          InfoRow(label: "Key Rotation", value: "Automatic")
          InfoRow(label: "Forward Secrecy", value: "Enabled")
          InfoRow(label: "Post-Compromise Security", value: "Enabled")
        }

        Section {
          Text(
            "This conversation uses the Messaging Layer Security (MLS) protocol, providing end-to-end encryption with forward secrecy and post-compromise security."
          )
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

  /// Show member management when we know there are members or we have a conversation payload.
  private var canShowMemberManagement: Bool {
    let conversationMembersCount = viewModel?.conversation?.members.count
    let storedMemberCount = memberCount

    logger.debug(
      "🔍 [MEMBER_MGMT] Checking canShowMemberManagement: conversationMembersCount=\(String(describing: conversationMembersCount)), storedMemberCount=\(storedMemberCount)"
    )

    if let count = conversationMembersCount {
      logger.debug(
        "🔍 [MEMBER_MGMT] Using conversation members count: \(count), returning \(count >= 1)")
      return count >= 1
    }

    logger.debug(
      "🔍 [MEMBER_MGMT] Using stored member count: \(storedMemberCount), returning \(storedMemberCount >= 1)"
    )
    return storedMemberCount >= 1
  }

  // MARK: - Conversation Metadata

  @discardableResult
  private func ensureConversationMetadata() async -> MLSConversationModel? {
    if let cachedModel = conversationModel {
      return cachedModel
    }

    guard let database = appState.mlsDatabase,
      let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID
    else {
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
        userDID: currentUserDID,
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

  /// MLS conversation pipeline that runs independently of view lifecycle
  /// This function is called from a detached task to ensure MLS state updates
  /// complete even if the user navigates away from the view
  private func runConversationPipeline() async {
    logger.info(
      "🎬 [PIPELINE] Starting MLS conversation pipeline for conversation: \(conversationId)")

    // PHASE 0: Fetch conversation metadata
    // Even if the view is dismissed, we need conversation metadata for subsequent operations
    _ = await ensureConversationMetadata()

    logger.info("📍 [PIPELINE] Starting Phase 0: Load cached messages")

    // PHASE 0: Load cached messages for instant display
    // GRDB checks Task.isCancelled internally, so we run this in a detached task
    // to ensure it completes even if parent task is cancelled
    await Task.detached { [self] in
      await self.loadCachedMessages()
    }.value

    // PHASE 0.5: Load cached reactions from local storage
    // Reactions are not stored on the server, so we must persist them locally
    await loadCachedReactions()

    logger.info("📍 [PIPELINE] Completed Phase 0, starting Phase 1: Fetch new messages from server")

    // PHASE 1: Fetch and decrypt new messages from server
    await MainActor.run {
      isLoadingMessages = true
    }
    defer {
      Task { @MainActor in
        isLoadingMessages = false
      }
    }

    guard let manager = await appState.getMLSConversationManager() else {
      logger.error("Failed to get MLS conversation manager")
      return
    }

    // Ensure the MLS group is initialized for this conversation
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
      logger.error(
        "❌ Failed to initialize MLS group for \(conversationId): MLSConversationError - \(error.localizedDescription)"
      )
      await MainActor.run {
        sendError = "Failed to initialize secure messaging. Please try again."
        showingSendError = true
      }
      return
    } catch let error as MLSAPIError {
      logger.error(
        "❌ Failed to initialize MLS group for \(conversationId): MLSAPIError - \(error.localizedDescription)"
      )
      if case .invalidResponse(let message) = error {
        logger.error("  → Invalid response details: \(message)")
      }
      await MainActor.run {
        sendError = "Failed to initialize secure messaging. Please try again."
        showingSendError = true
      }
      return
    } catch {
      logger.error(
        "❌ Failed to initialize MLS group for \(conversationId): Unexpected error - \(type(of: error)) - \(error.localizedDescription)"
      )
      await MainActor.run {
        sendError = "Failed to initialize secure messaging. Please try again."
        showingSendError = true
      }
      return
    }

    do {
      // Get current user DID for plaintext isolation
      guard
        let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID
      else {
        logger.error("Cannot load messages: currentUserDID not available")
        return
      }

      // Query database for last cached sequence number
      guard let database = appState.mlsDatabase else {
        logger.error("MLS database not available")
        return
      }

      // Use MLSStorage helper method (avoids direct db.read on main thread)
      let lastCachedCursor = try? await MLSStorage.shared.fetchLastMessageCursor(
        conversationID: conversationId,
        currentUserDID: currentUserDID,
        database: database
      )

      if let cursor = lastCachedCursor {
        logger.debug(
          "📍 Last cached message epoch=\(cursor.epoch), seq=\(cursor.seq), will fetch messages after this"
        )
      } else {
        logger.debug("📍 No cached messages, will fetch all from server")
      }

      let lastCachedSeq = lastCachedCursor.map { Int($0.seq) }

      // Fetch messages from server
      let apiClient = await appState.getMLSAPIClient()
      guard let apiClient = apiClient else {
        logger.error("Failed to get MLS API client")
        return
      }

      // Only fetch NEW messages after last cached message
      let (messageViews, lastSeq, gapInfo) = try await apiClient.getMessages(
        convoId: conversationId,
        limit: 50,
        sinceSeq: lastCachedSeq.map { Int($0) }
      )

      if messageViews.isEmpty {
        logger.info("✅ No new messages from server since seq=\(lastCachedSeq ?? 0)")
        // Start subscription if not already running
        await MainActor.run {
          if isViewActive && !hasStartedSubscription {
            startMessagePolling()
            hasStartedSubscription = true
          }
        }
        return
      }

      logger.info(
        "Fetched \(messageViews.count) NEW encrypted messages since seq=\(lastCachedSeq ?? 0)")

      // Log what server sent
      for (index, msgView) in messageViews.enumerated() {
        logger.info("📨 SERVER MESSAGE [\(index)]: id=\(msgView.id)")
        logger.info("  - epoch: \(msgView.epoch)")
        logger.info("  - seq: \(msgView.seq)")
        logger.info("  - ciphertext.data.count: \(msgView.ciphertext.data.count)")
        logger.info("  - sentAt: \(msgView.createdAt.date)")
      }

      // Ensure conversation exists in database before processing messages
      if let database = appState.mlsDatabase {
        if let convo = manager.conversations[conversationId] {
          do {
            try await storage.ensureConversationExists(
              userDID: currentUserDID,
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
      logger.info("📊 Phase 1: Processing \(messageViews.count) messages in order (epoch/sequence)")

      // Process messages in correct order - this handles sorting, buffering, and decryption
      do {
        _ = try await manager.processMessagesInOrder(
          messages: messageViews,
          conversationID: conversationId
        )
        logger.info("✅ Phase 1 complete: All messages decrypted and cached in order")

        // Notify unified data source to refresh from storage
        await unifiedDataSource?.onMessagesDecrypted()
      } catch let error as MLSError {
        if case .ratchetStateDesync(let message) = error {
          logger.error("🔴 RATCHET STATE DESYNC in manual fetch: \(message)")
          logger.error(
            "   This indicates the client missed real-time updates and state is out of sync")
          logger.error(
            "   Manual message fetch cannot decrypt without proper state synchronization")

          await MainActor.run {
            sendError =
              "Cannot decrypt messages: conversation state is out of sync. This can happen when real-time updates are missed. Please leave and rejoin the conversation."
            showingSendError = true
          }
          return
        } else {
          logger.error("❌ Failed to process messages in order: \(error.localizedDescription)")
        }
      } catch {
        logger.error("❌ Failed to process messages in order: \(error.localizedDescription)")
      }

      // PHASE 2: Build UI Message objects from cached data
      logger.info("📊 Phase 2: Building UI Message objects from cached data")
      var decryptedMessages: [Message] = []
      var orderUpdates: [String: MessageOrderKey] = [:]

      // Server guarantees messages are returned in (epoch ASC, seq ASC) order
      for messageView in messageViews {
        do {
          guard let database = appState.mlsDatabase else {
            logger.error("Cannot fetch message data: database not available")
            continue
          }

          // Check if this is a commit message (MLS protocol control message)
          let plaintextResult: String?
          do {
            plaintextResult = try await storage.fetchPlaintextForMessage(
              messageView.id, currentUserDID: currentUserDID, database: database)
            logger.debug(
              "🔍 [COMMIT_FILTER] Plaintext fetch for \(messageView.id): \(plaintextResult == nil ? "nil" : "found (\(plaintextResult!.prefix(20))...)")"
            )
          } catch {
            logger.error(
              "🔍 [COMMIT_FILTER] Plaintext fetch THREW for \(messageView.id): \(error.localizedDescription)"
            )
            plaintextResult = nil
          }

          let senderResult: String?
          do {
            senderResult = try await storage.fetchSenderForMessage(
              messageView.id, currentUserDID: currentUserDID, database: database)
            logger.debug(
              "🔍 [COMMIT_FILTER] Sender fetch for \(messageView.id): \(senderResult == nil ? "nil" : "found (\(senderResult!))")"
            )
          } catch {
            logger.error(
              "🔍 [COMMIT_FILTER] Sender fetch THREW for \(messageView.id): \(error.localizedDescription)"
            )
            senderResult = nil
          }

          // Skip commit messages - they're MLS protocol control messages, not user messages
          if messageView.messageType == "commit" {
            logger.debug(
              "ℹ️ Message \(messageView.id) is a commit (epoch: \(messageView.epoch), seq: \(messageView.seq)) - MLS state updated, not displayed in UI"
            )
            continue
          }

          // If message has neither plaintext nor sender, it might be a proposal or other non-displayable message
          if plaintextResult == nil && senderResult == nil {
            logger.debug(
              "ℹ️ Message \(messageView.id) has no plaintext/sender (epoch: \(messageView.epoch), seq: \(messageView.seq)) - skipping display"
            )
            continue
          }

          // Skip control messages (reactions, read receipts, typing indicators, etc.)
          // These are cached with sentinel plaintext like "[control:reaction]"
          if let plaintext = plaintextResult, plaintext.hasPrefix("[control:") {
            logger.debug(
              "ℹ️ Message \(messageView.id) is a control message (\(plaintext.prefix(30))) - not displayed in UI"
            )
            continue
          }

          guard let senderDID = senderResult else {
            logger.warning("⚠️ No sender found for message \(messageView.id) - skipping")
            continue
          }

          logger.debug("🔍 MLS_OWNERSHIP: ====== Building UI for message \(messageView.id) ======")
          let isCurrentUser = isMessageFromCurrentUser(senderDID: senderDID)
          logger.info(
            "🔍 MLS_OWNERSHIP: Result for message \(messageView.id): isCurrentUser = \(isCurrentUser)"
          )

          // Use cached plaintext
          var displayText = ""
          var embed: MLSEmbedData?

          if let storedPlaintext = plaintextResult {
            displayText = storedPlaintext
            embed = try? await storage.fetchEmbedForMessage(
              messageView.id, currentUserDID: currentUserDID, database: database)
            logger.debug(
              "Using cached plaintext for message \(messageView.id) (hasEmbed: \(embed != nil))")
          } else {
            // No cached plaintext - this can happen for own messages (MLS prevents self-decryption)
            if isCurrentUser {
              logger.warning(
                "⚠️ Message \(messageView.id) from current user has no cached plaintext")
              logger.warning("   Self-decryption is impossible by MLS design - skipping message")
              continue
            } else {
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

          // Don't store error information for messages with valid plaintext
          // If we successfully decrypted it, we don't need to show errors
          // This prevents showing old epoch errors for messages that were successfully decrypted

          let message = Message(
            id: messageView.id,
            user: makeUser(for: senderDID, isCurrentUser: isCurrentUser),
            status: .sent,
            createdAt: messageView.createdAt.date,
            text: displayText
          )

          orderUpdates[messageView.id] = MessageOrderKey(
            epoch: messageView.epoch,
            sequence: messageView.seq,
            timestamp: messageView.createdAt.date
          )

          logger.info(
            "🔍 MLS_OWNERSHIP: Created Message object - user.name: '\(message.user.name ?? "nil")', user.isCurrentUser: \(message.user.isCurrentUser)"
          )
          decryptedMessages.append(message)
        } catch {
          logger.error(
            "Failed to build UI for message \(messageView.id): \(error.localizedDescription)")
        }
      }

      await MainActor.run {
        logger.debug(
          "🔀 [PIPELINE_MERGE] Before merge: messages.count=\(messages.count), decryptedMessages.count=\(decryptedMessages.count)"
        )
        applyMessageOrderUpdates(orderUpdates)
        // Merge new messages with existing cached messages
        var addedCount = 0
        for newMsg in decryptedMessages {
          if !messages.contains(where: { $0.id == newMsg.id }) {
            logger.debug(
              "🔀 [PIPELINE_MERGE] Adding new message \(newMsg.id.prefix(8)) from sender \(newMsg.user.id.suffix(8))"
            )
            messages.append(newMsg)
            addedCount += 1
          } else {
            logger.debug("🔀 [PIPELINE_MERGE] Skipping duplicate message \(newMsg.id.prefix(8))")
          }
        }
        logger.debug(
          "🔀 [PIPELINE_MERGE] After merge: messages.count=\(messages.count), added=\(addedCount)")
        sortMessagesByMLSOrder()
      }

      ensureProfilesLoaded(for: decryptedMessages.map { $0.user.id })

      logger.info("Loaded and decrypted \(decryptedMessages.count) messages")

      // Start live updates after initial load
      await MainActor.run {
        if isViewActive && !hasStartedSubscription {
          startMessagePolling()
          hasStartedSubscription = true
        }
      }

    } catch {
      logger.error("Failed to load messages: \(error.localizedDescription)")
    }
  }

  private func loadConversationAndMessages() async {
    logger.info(
      "🎬 [ENTRY] loadConversationAndMessages() called for conversation: \(conversationId)")

    // CRITICAL: Protect metadata fetching from task cancellation
    // Even if the view is dismissed, we need conversation metadata for subsequent operations
    // Using withTaskCancellationHandler ensures this completes before cancellation propagates
    await withTaskCancellationHandler {
      _ = await ensureConversationMetadata()
    } onCancel: {
      logger.debug("Conversation metadata fetch was cancelled, but allowing completion")
    }

    logger.info("📍 [ENTRY] Starting Phase 0: Load cached messages")

    // PHASE 0 FIX: Run cached message loading in detached task
    // GRDB checks Task.isCancelled internally, so withTaskCancellationHandler isn't enough
    // Task.detached creates a completely new task tree that's immune to parent cancellation
    // This is critical for seeing own sent messages on view re-entry
    await Task.detached { [self] in
      await self.loadCachedMessages()
    }.value

    logger.info("📍 [ENTRY] Completed Phase 0, starting Phase 1: Fetch new messages from server")

    // ⭐ CRITICAL FIX: ALWAYS check server for new messages
    // The previous logic incorrectly skipped server fetch if cache had ANY messages
    // This prevented seeing new messages from other participants
    // MLS ratchet concerns are addressed by only processing NEW messages (using sinceSeq)
    // Note: We'll determine lastCachedSeq from the database query below

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
      logger.error(
        "❌ Failed to initialize MLS group for \(conversationId): MLSConversationError - \(error.localizedDescription)"
      )
      sendError = "Failed to initialize secure messaging. Please try again."
      showingSendError = true
      return
    } catch let error as MLSAPIError {
      logger.error(
        "❌ Failed to initialize MLS group for \(conversationId): MLSAPIError - \(error.localizedDescription)"
      )
      if case .invalidResponse(let message) = error {
        logger.error("  → Invalid response details: \(message)")
      }
      sendError = "Failed to initialize secure messaging. Please try again."
      showingSendError = true
      return
    } catch {
      logger.error(
        "❌ Failed to initialize MLS group for \(conversationId): Unexpected error - \(type(of: error)) - \(error.localizedDescription)"
      )
      sendError = "Failed to initialize secure messaging. Please try again."
      showingSendError = true
      return
    }

    do {
      // Get current user DID for plaintext isolation
      guard
        let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID
      else {
        logger.error("Cannot load messages: currentUserDID not available")
        return
      }

      // ⭐ CRITICAL FIX: Query database for last cached sequence number
      // This allows us to only fetch NEW messages from server
      guard let database = appState.mlsDatabase else {
        logger.error("MLS database not available")
        return
      }

      // Use MLSStorage helper method (avoids direct db.read on main thread)
      let lastCachedCursor = try? await MLSStorage.shared.fetchLastMessageCursor(
        conversationID: conversationId,
        currentUserDID: currentUserDID,
        database: database
      )

      if let cursor = lastCachedCursor {
        logger.debug(
          "📍 Last cached message epoch=\(cursor.epoch), seq=\(cursor.seq), will fetch messages after this"
        )
      } else {
        logger.debug("📍 No cached messages, will fetch all from server")
      }

      let lastCachedSeq = lastCachedCursor.map { Int($0.seq) }

      // Fetch messages from server
      let apiClient = await appState.getMLSAPIClient()
      guard let apiClient = apiClient else {
        logger.error("Failed to get MLS API client")
        return
      }

      // ⭐ CRITICAL FIX: Only fetch NEW messages after last cached message
      // This prevents re-processing messages (which would fail due to MLS ratchet)
      // while ensuring we always see new messages from other participants
      let (messageViews, lastSeq, gapInfo) = try await apiClient.getMessages(
        convoId: conversationId,
        limit: 50,
        sinceSeq: lastCachedSeq.map { Int($0) }  // Only get messages after last cached seq
      )

      if messageViews.isEmpty {
        logger.info("✅ No new messages from server since seq=\(lastCachedSeq ?? 0)")
        // Start subscription if not already running
        if !hasStartedSubscription {
          startMessagePolling()
          hasStartedSubscription = true
        }
        return  // No new messages to process
      }

      logger.info(
        "Fetched \(messageViews.count) NEW encrypted messages since seq=\(lastCachedSeq ?? 0)")

      // 🔍 DEBUG: Log what server sent (sender extracted during decryption)
      for (index, msgView) in messageViews.enumerated() {
        logger.info("📨 SERVER MESSAGE [\(index)]: id=\(msgView.id)")
        logger.info("  - epoch: \(msgView.epoch)")
        logger.info("  - seq: \(msgView.seq)")
        logger.info("  - ciphertext.data.count: \(msgView.ciphertext.data.count)")
        logger.info(
          "  - ciphertext.data (first 32 bytes): \(msgView.ciphertext.data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " "))"
        )
        logger.info("  - sentAt: \(msgView.createdAt.date)")
      }

      // CRITICAL FIX #1: Ensure conversation exists in database before processing messages
      // This prevents foreign key constraint violations when storing decrypted messages
      if let database = appState.mlsDatabase {
        // Get groupID from manager's conversations cache
        if let convo = manager.conversations[conversationId] {
          do {
            try await storage.ensureConversationExists(
              userDID: currentUserDID,
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

      // Note: SQLiteData/GRDB implementation handles ciphertext in MLSMessageModel directly
      // processMessagesInOrder() handles decryption and caching via MLSStorageHelpers

      // PHASE 2 FIX: Protect message processing from view cancellation
      // Allow message decryption to complete even if user navigates away
      // This prevents MLS state corruption from partial batch processing
      await withTaskCancellationHandler {
        // Process messages in correct order - this handles sorting, buffering, and decryption
        do {
          _ = try await manager.processMessagesInOrder(
            messages: messageViews,
            conversationID: conversationId
          )
          logger.info("✅ Phase 1 complete: All messages decrypted and cached in order")

          // Notify unified data source to refresh from storage
          await unifiedDataSource?.onMessagesDecrypted()
        } catch let error as MLSError {
          if case .ratchetStateDesync(let message) = error {
            logger.error("🔴 RATCHET STATE DESYNC in manual fetch: \(message)")
            logger.error(
              "   This indicates the client missed real-time updates and state is out of sync")
            logger.error(
              "   Manual message fetch cannot decrypt without proper state synchronization")

            await MainActor.run {
              sendError =
                "Cannot decrypt messages: conversation state is out of sync. This can happen when real-time updates are missed. Please leave and rejoin the conversation."
              showingSendError = true
            }

            // Stop processing - we can't decrypt anything with stale state
            return
          } else {
            logger.error("❌ Failed to process messages in order: \(error.localizedDescription)")
            // Continue anyway - we'll use cached data where available
          }
        } catch {
          logger.error("❌ Failed to process messages in order: \(error.localizedDescription)")
          // Continue anyway - we'll use cached data where available
        }
      } onCancel: {
        logger.warning(
          "⚠️ Message processing was cancelled by view dismissal - allowing completion to prevent state corruption"
        )
      }

      // PHASE 2 FIX: Check for cancellation before building UI
      // If view was dismissed during Phase 1, exit gracefully without building UI
      do {
        try Task.checkCancellation()
      } catch {
        logger.info("⚠️ View dismissed after Phase 1 - skipping UI building")
        return
      }

      // PHASE 2: Build UI Message objects from cached data
      logger.info("📊 Phase 2: Building UI Message objects from cached data")
      var decryptedMessages: [Message] = []
      var orderUpdates: [String: MessageOrderKey] = [:]

      // Server guarantees messages are returned in (epoch ASC, seq ASC) order
      // No client-side sorting needed - use messageViews directly
      for messageView in messageViews {
        // PHASE 2 FIX: Check for cancellation at start of each message iteration
        // Exit gracefully if view is dismissed during UI building
        do {
          try Task.checkCancellation()
        } catch {
          logger.info(
            "⚠️ View dismissed during Phase 2 - stopping UI building at message \(messageView.id)")
          break
        }

        do {
          guard let database = appState.mlsDatabase else {
            logger.error("Cannot fetch message data: database not available")
            continue
          }

          // PHASE 4 FIX: Check if this is a commit message (MLS protocol control message)
          // Commit messages advance epochs but contain no application plaintext
          // They are processed for state updates but should NOT be displayed in UI

          // DEBUG: Add explicit logging to diagnose filtering issue
          let plaintextResult: String?
          do {
            plaintextResult = try await storage.fetchPlaintextForMessage(
              messageView.id, currentUserDID: currentUserDID, database: database)
            logger.debug(
              "🔍 [COMMIT_FILTER] Plaintext fetch for \(messageView.id): \(plaintextResult == nil ? "nil" : "found (\(plaintextResult!.prefix(20))...)")"
            )
          } catch is CancellationError {
            // Task was cancelled - exit gracefully (shouldn't happen due to checkCancellation above, but defensive)
            logger.info("⚠️ Plaintext fetch cancelled for \(messageView.id) - view dismissed")
            break
          } catch {
            logger.error(
              "🔍 [COMMIT_FILTER] Plaintext fetch THREW for \(messageView.id): \(error.localizedDescription)"
            )
            plaintextResult = nil
          }

          let senderResult: String?
          do {
            senderResult = try await storage.fetchSenderForMessage(
              messageView.id, currentUserDID: currentUserDID, database: database)
            logger.debug(
              "🔍 [COMMIT_FILTER] Sender fetch for \(messageView.id): \(senderResult == nil ? "nil" : "found (\(senderResult!))")"
            )
          } catch is CancellationError {
            // Task was cancelled - exit gracefully
            logger.info("⚠️ Sender fetch cancelled for \(messageView.id) - view dismissed")
            break
          } catch {
            logger.error(
              "🔍 [COMMIT_FILTER] Sender fetch THREW for \(messageView.id): \(error.localizedDescription)"
            )
            senderResult = nil
          }

          // Skip commit messages - they're MLS protocol control messages, not user messages
          if messageView.messageType == "commit" {
            logger.debug(
              "ℹ️ Message \(messageView.id) is a commit (epoch: \(messageView.epoch), seq: \(messageView.seq)) - MLS state updated, not displayed in UI"
            )
            continue
          }

          // If message has neither plaintext nor sender, it might be a proposal or other non-displayable message
          if plaintextResult == nil && senderResult == nil {
            logger.debug(
              "ℹ️ Message \(messageView.id) has no plaintext/sender (epoch: \(messageView.epoch), seq: \(messageView.seq)) - skipping display"
            )
            continue
          }

          // Use the sender we already fetched above (no need to fetch again)
          guard let senderDID = senderResult else {
            logger.warning("⚠️ No sender found for message \(messageView.id) - skipping")
            continue
          }

          logger.debug("🔍 MLS_OWNERSHIP: ====== Building UI for message \(messageView.id) ======")
          let isCurrentUser = isMessageFromCurrentUser(senderDID: senderDID)
          logger.info(
            "🔍 MLS_OWNERSHIP: Result for message \(messageView.id): isCurrentUser = \(isCurrentUser)"
          )

          // Use cached plaintext we already fetched above (should be available after Phase 1)
          var displayText = ""
          var embed: MLSEmbedData?

          if let storedPlaintext = plaintextResult {
            displayText = storedPlaintext
            embed = try? await storage.fetchEmbedForMessage(
              messageView.id, currentUserDID: currentUserDID, database: database)
            logger.debug(
              "Using cached plaintext for message \(messageView.id) (hasEmbed: \(embed != nil))")
          } else {
            // No cached plaintext - this can happen for own messages (MLS prevents self-decryption)
            if isCurrentUser {
              logger.warning(
                "⚠️ Message \(messageView.id) from current user has no cached plaintext")
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

          // Fetch error information from database if available (loadConversationAndMessages path)
          // Use MLSStorage helper (avoids direct db.read on main thread)
          if let messageModel = try? await MLSStorage.shared.fetchMessage(
            messageID: messageView.id,
            currentUserDID: currentUserDID,
            database: database
          ), messageModel.processingError != nil || messageModel.validationFailureReason != nil {
            await MainActor.run {
              messageErrorsMap[messageView.id] = MessageErrorInfo(
                processingError: messageModel.processingError,
                processingAttempts: messageModel.processingAttempts,
                validationFailureReason: messageModel.validationFailureReason
              )
            }
          }

          let message = Message(
            id: messageView.id,
            user: makeUser(for: senderDID, isCurrentUser: isCurrentUser),
            status: .sent,
            createdAt: messageView.createdAt.date,
            text: displayText
          )

          orderUpdates[messageView.id] = MessageOrderKey(
            epoch: messageView.epoch,
            sequence: messageView.seq,
            timestamp: messageView.createdAt.date
          )

          logger.info(
            "🔍 MLS_OWNERSHIP: Created Message object - user.name: '\(message.user.name ?? "nil")', user.isCurrentUser: \(message.user.isCurrentUser)"
          )
          decryptedMessages.append(message)
        } catch {
          logger.error(
            "Failed to build UI for message \(messageView.id): \(error.localizedDescription)")
        }
      }

      await MainActor.run {
        applyMessageOrderUpdates(orderUpdates)
        // Merge new messages with existing cached messages
        for newMsg in decryptedMessages {
          if !messages.contains(where: { $0.id == newMsg.id }) {
            messages.append(newMsg)
          }
        }
        sortMessagesByMLSOrder()
      }

      ensureProfilesLoaded(for: decryptedMessages.map { $0.user.id })

      logger.info("Loaded and decrypted \(decryptedMessages.count) messages")
      // Start live updates after initial load
      await MainActor.run {
        if isViewActive && !hasStartedSubscription {
          startMessagePolling()
          hasStartedSubscription = true
        }
      }

    } catch {
      logger.error("Failed to load messages: \(error.localizedDescription)")
    }
  }

  private func loadCachedMessages() async {
    logger.info(
      "🚀 [PHASE 0] Loading cached messages for instant display - conversationId: \(conversationId)")

    guard let database = appState.mlsDatabase else {
      logger.error("❌ [PHASE 0] Cannot load cached messages: database not available")
      return
    }

    guard
      let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID
    else {
      logger.error("❌ [PHASE 0] Cannot load cached messages: currentUserDID not available")
      return
    }

    logger.debug("🔍 [PHASE 0] Using currentUserDID: \(currentUserDID)")

    do {
      var orderUpdates: [String: MessageOrderKey] = [:]
      logger.debug("📊 [PHASE 0] Fetching cached messages from database...")
      let cachedModels = try await storage.fetchMessagesForConversation(
        conversationId,
        currentUserDID: currentUserDID,
        database: database,
        limit: 50
      )

      logger.info("📦 [PHASE 0] Database query returned \(cachedModels.count) messages")

      guard !cachedModels.isEmpty else {
        logger.warning("⚠️ [PHASE 0] No cached messages found in database")
        return
      }

      logger.info("✅ [PHASE 0] Found \(cachedModels.count) cached messages")

      // Convert MLSMessageModel to Message objects for display
      var cachedMessages: [Message] = []

      for model in cachedModels {
        // Note: We don't filter by message_type here because the database query
        // doesn't include that field. Commits are filtered out during message processing
        // before they're stored in the database with plaintext.

        guard let plaintext = model.plaintext, !model.plaintextExpired else {
          // Skip messages without plaintext or with expired plaintext
          // This includes messages that failed to decrypt due to forward secrecy
          logger.debug(
            "Skipping message \(model.messageID): no plaintext or expired (forward secrecy or expired)"
          )
          continue
        }

        // Skip control messages (reactions, read receipts, typing indicators, etc.)
        // These are cached with sentinel plaintext like "[control:reaction]"
        if plaintext.hasPrefix("[control:") {
          logger.debug(
            "Skipping control message \(model.messageID): \(plaintext.prefix(30))"
          )
          continue
        }

        let isCurrentUser = isMessageFromCurrentUser(senderDID: model.senderID)

        let message = Message(
          id: model.messageID,
          user: makeUser(for: model.senderID, isCurrentUser: isCurrentUser),
          status: .sent,
          createdAt: model.timestamp,
          text: plaintext
        )

        if model.processingError != nil || model.validationFailureReason != nil {
          logger.warning(
            "⚠️ [PHASE 0] Cached message \(model.messageID) includes processing error metadata (sender=\(model.senderID), attempts=\(model.processingAttempts))"
          )
          if let error = model.processingError {
            logger.debug("   processingError: \(error.prefix(200))")
          }
          if let validation = model.validationFailureReason {
            logger.debug("   validationFailure: \(validation.prefix(200))")
          }
          await MainActor.run {
            messageErrorsMap[model.messageID] = MessageErrorInfo(
              processingError: model.processingError,
              processingAttempts: model.processingAttempts,
              validationFailureReason: model.validationFailureReason
            )
          }
        } else if model.senderID == "unknown" {
          logger.warning(
            "⚠️ [PHASE 0] Cached message \(model.messageID) has unknown sender without error details"
          )
        }

        cachedMessages.append(message)
        orderUpdates[model.messageID] = MessageOrderKey(
          epoch: Int(model.epoch),
          sequence: Int(model.sequenceNumber),
          timestamp: model.timestamp
        )

        // Store embed in map if available
        if let embed = model.parsedEmbed {
          await MainActor.run {
            embedsMap[model.messageID] = embed
          }
        }

        // Don't store error information for messages with valid plaintext
        // If we successfully decrypted it, we don't need to show errors
        // This prevents showing old epoch errors for messages that were successfully decrypted
      }

      // Update UI with cached messages
      await MainActor.run {
        applyMessageOrderUpdates(orderUpdates)
        messages = cachedMessages
        sortMessagesByMLSOrder()
      }

      ensureProfilesLoaded(for: cachedMessages.map { $0.user.id })

      logger.info("Displayed \(cachedMessages.count) cached messages")

    } catch {
      logger.error("Failed to load cached messages: \(error.localizedDescription)")
    }
  }

  private func loadMoreMessages() async {
    guard !isLoadingMoreMessages, hasMoreMessages else {
      logger.debug("Skipping loadMoreMessages: already loading or no more messages")
      return
    }

    await MainActor.run {
      isLoadingMoreMessages = true
    }

    logger.info("📖 Loading more (older) messages for pagination")

    guard let database = appState.mlsDatabase else {
      logger.error("Cannot load more messages: database not available")
      await MainActor.run {
        isLoadingMoreMessages = false
      }
      return
    }

    guard
      let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID
    else {
      logger.error("Cannot load more messages: currentUserDID not available")
      await MainActor.run {
        isLoadingMoreMessages = false
      }
      return
    }

    do {
      // Get the oldest message currently displayed
      let oldestEpoch = await MainActor.run {
        messages.first.flatMap { messageOrdering[$0.id]?.epoch } ?? 0
      }
      let oldestSeq = await MainActor.run {
        messages.first.flatMap { messageOrdering[$0.id]?.sequence } ?? 0
      }

      logger.debug("Loading messages older than epoch=\(oldestEpoch), seq=\(oldestSeq)")

      // Fetch older messages from database
      let olderModels = try await storage.fetchMessagesBeforeSequence(
        conversationId: conversationId,
        currentUserDID: currentUserDID,
        beforeEpoch: Int64(oldestEpoch),
        beforeSeq: Int64(oldestSeq),
        database: database,
        limit: 50
      )

      guard !olderModels.isEmpty else {
        logger.info("No more older messages found in database")
        await MainActor.run {
          hasMoreMessages = false
          isLoadingMoreMessages = false
        }
        return
      }

      logger.info("Loaded \(olderModels.count) older messages from database")

      var olderMessages: [Message] = []
      var orderUpdates: [String: MessageOrderKey] = [:]

      for model in olderModels {
        guard let plaintext = model.plaintext, !model.plaintextExpired else {
          logger.debug("Skipping older message \(model.messageID): no plaintext or expired")
          continue
        }

        let isCurrentUser = isMessageFromCurrentUser(senderDID: model.senderID)

        let message = Message(
          id: model.messageID,
          user: makeUser(for: model.senderID, isCurrentUser: isCurrentUser),
          status: .sent,
          createdAt: model.timestamp,
          text: plaintext
        )

        olderMessages.append(message)
        orderUpdates[model.messageID] = MessageOrderKey(
          epoch: Int(model.epoch),
          sequence: Int(model.sequenceNumber),
          timestamp: model.timestamp
        )

        // Store embed in map if available
        if let embed = model.parsedEmbed {
          await MainActor.run {
            embedsMap[model.messageID] = embed
          }
        }

        if model.processingError != nil || model.validationFailureReason != nil {
          logger.warning(
            "⚠️ [PAGINATION] Older message \(model.messageID) carries processing error metadata (sender=\(model.senderID), attempts=\(model.processingAttempts))"
          )
          if let error = model.processingError {
            logger.debug("   processingError: \(error.prefix(200))")
          }
          if let validation = model.validationFailureReason {
            logger.debug("   validationFailure: \(validation.prefix(200))")
          }
          await MainActor.run {
            messageErrorsMap[model.messageID] = MessageErrorInfo(
              processingError: model.processingError,
              processingAttempts: model.processingAttempts,
              validationFailureReason: model.validationFailureReason
            )
          }
        } else if model.senderID == "unknown" {
          logger.warning(
            "⚠️ [PAGINATION] Older message \(model.messageID) has unknown sender without error details"
          )
        }
      }

      // Prepend older messages to current messages
      await MainActor.run {
        applyMessageOrderUpdates(orderUpdates)
        messages = olderMessages + messages
        sortMessagesByMLSOrder()
        isLoadingMoreMessages = false

        // Check if we got fewer messages than requested - means we've reached the end
        if olderModels.count < 50 {
          hasMoreMessages = false
        }
      }

      ensureProfilesLoaded(for: olderMessages.map { $0.user.id })

      logger.info("Successfully prepended \(olderMessages.count) older messages")

    } catch {
      logger.error("Failed to load more messages: \(error.localizedDescription)")
      await MainActor.run {
        isLoadingMoreMessages = false
      }
    }
  }

  private func loadParticipantProfiles() async {
    guard
      let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID
    else {
      logger.warning("Cannot load participant profiles: currentUserDID not available")
      return
    }

    guard let database = appState.mlsDatabase else {
      logger.error("Cannot load participant profiles: database not available")
      return
    }

    do {
      let fetchedMembers = try await storage.fetchMembers(
        conversationID: conversationId,
        currentUserDID: currentUserDID,
        database: database
      )

      let dids = Set(fetchedMembers.map(\.did))

      await MainActor.run {
        members = fetchedMembers
        participantProfiles = participantProfiles.filter { dids.contains($0.key) }
      }

      guard !dids.isEmpty else {
        logger.info("Conversation \(conversationId) has no active members to enrich")
        return
      }

      guard let client = appState.atProtoClient else {
        logger.warning("Cannot load participant profiles: ATProto client unavailable")
        return
      }

      let profiles = await appState.mlsProfileEnricher.ensureProfiles(
        for: Array(dids),
        using: client
      )

      await MainActor.run {
        mergeParticipantProfiles(with: profiles)
      }

      logger.info(
        "Loaded profile data for \(profiles.count) participants in conversation \(conversationId)")
    } catch {
      logger.error("Failed to load participant profiles: \(error.localizedDescription)")
    }
  }

  @MainActor
  private func mergeParticipantProfiles(with newProfiles: [String: MLSProfileEnricher.ProfileData])
  {
    guard !newProfiles.isEmpty else { return }
    for (did, profile) in newProfiles {
      participantProfiles[did] = profile
    }
  }

  /// Load cached reactions from SQLite for this conversation
  /// Called on conversation open to restore reactions from previous sessions
  private func loadCachedReactions() async {
    guard
      let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID
    else {
      logger.warning("Cannot load cached reactions: currentUserDID not available")
      return
    }

    guard let database = appState.mlsDatabase else {
      logger.warning("Cannot load cached reactions: database not available")
      return
    }

    do {
      let cachedReactions = try await storage.fetchReactionsForConversation(
        conversationId,
        currentUserDID: currentUserDID,
        database: database
      )

      // Convert MLSReactionModel to MLSMessageReaction for UI
      await MainActor.run {
        for (messageId, models) in cachedReactions {
          let mlsReactions = models.map { model in
            MLSMessageReaction(
              messageId: model.messageID,
              reaction: model.emoji,
              senderDID: model.actorDID,
              reactedAt: model.timestamp
            )
          }
          messageReactionsMap[messageId] = mlsReactions
        }
      }

      logger.info(
        "Loaded \(cachedReactions.values.flatMap { $0 }.count) cached reactions for conversation \(conversationId)"
      )
    } catch {
      logger.error("Failed to load cached reactions: \(error.localizedDescription)")
    }
  }

  /// Persist a reaction to SQLite for offline/cross-session access
  private func persistReaction(messageId: String, emoji: String, actorDID: String, action: String) {
    guard
      let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID
    else {
      logger.warning("Cannot persist reaction: currentUserDID not available")
      return
    }

    guard let database = appState.mlsDatabase else {
      logger.warning("Cannot persist reaction: database not available")
      return
    }

    Task {
      do {
        if action == "add" {
          let reactionModel = MLSReactionModel(
            messageID: messageId,
            conversationID: conversationId,
            currentUserDID: currentUserDID,
            actorDID: actorDID,
            emoji: emoji,
            action: action
          )
          try await storage.saveReaction(reactionModel, database: database)
          logger.debug("Persisted reaction: \(emoji) on \(messageId) by \(actorDID)")
        } else if action == "remove" {
          try await storage.deleteReaction(
            messageID: messageId,
            actorDID: actorDID,
            emoji: emoji,
            currentUserDID: currentUserDID,
            database: database
          )
          logger.debug("Deleted persisted reaction: \(emoji) on \(messageId) by \(actorDID)")
        }
      } catch {
        logger.error("Failed to persist reaction: \(error.localizedDescription)")
      }
    }
  }

  private func ensureProfileLoaded(for did: String) {
    ensureProfilesLoaded(for: [did])
  }

  private func ensureProfilesLoaded(for dids: [String]) {
    Task {
      let uniqueDIDs = Array(Set(dids))
      guard !uniqueDIDs.isEmpty else { return }

      let missing: [String] = await MainActor.run {
        uniqueDIDs.filter { participantProfiles[$0] == nil }
      }

      guard !missing.isEmpty else { return }
      guard let client = appState.atProtoClient else { return }

      let profiles = await appState.mlsProfileEnricher.ensureProfiles(for: missing, using: client)
      await MainActor.run {
        mergeParticipantProfiles(with: profiles)
        // Rebuild messages to reflect newly loaded profile data
        rebuildMessagesWithProfiles()
      }
    }
  }

  /// Mark all messages in this conversation as read
  private func markMessagesAsRead() async {
    logger.debug("📬 [READ_RECEIPTS] Marking messages as read for conversation \(conversationId)")

    // Mark messages as read in local database first
    if let database = appState.mlsDatabase {
      let currentUserDID = appState.userDID
      do {
        let count = try await MLSStorageHelpers.markAllMessagesAsRead(
          in: database,
          conversationID: conversationId,
          currentUserDID: currentUserDID
        )
        if count > 0 {
          logger.info("📬 [READ_RECEIPTS] Marked \(count) messages as read locally")
          // Update AppState's MLS unread count
          await appState.updateMLSUnreadCount()
        }
      } catch {
        logger.error(
          "📬 [READ_RECEIPTS] Failed to mark messages as read locally: \(error.localizedDescription)"
        )
      }
    }

    // Also notify the server
    guard let apiClient = await appState.getMLSAPIClient() else {
      logger.warning(
        "📬 [READ_RECEIPTS] Cannot mark messages as read on server: API client not available")
      return
    }

    do {
      // Mark all messages as read (messageId: nil means all messages)
      let readAt = try await apiClient.updateRead(convoId: conversationId, messageId: nil)
      logger.info("📬 [READ_RECEIPTS] ✅ Marked all messages as read on server at \(readAt)")
    } catch {
      logger.error(
        "📬 [READ_RECEIPTS] ❌ Failed to mark messages as read on server: \(error.localizedDescription)"
      )
    }
  }

  private func clearMembershipChangeBadge() async {
    logger.debug(
      "👥 [MEMBER_VISIBILITY] Clearing membership change badge for conversation \(conversationId)")

    guard let manager = await appState.getMLSConversationManager() else {
      logger.warning("👥 [MEMBER_VISIBILITY] Cannot clear badge: manager not available")
      return
    }

    let storage = manager.storage
    let database = manager.database

    do {
      try await storage.clearMembershipChangeBadge(
        conversationID: conversationId,
        currentUserDID: appState.userDID,
        database: database
      )
      logger.info("👥 [MEMBER_VISIBILITY] ✅ Cleared membership change badge")
    } catch {
      logger.error("👥 [MEMBER_VISIBILITY] ❌ Failed to clear membership badge: \(error)")
    }
  }

  private func loadMemberCount() async {
    logger.debug("🔍 [MEMBER_MGMT] loadMemberCount() called for conversation \(conversationId)")

    guard
      let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID
    else {
      logger.warning("🔍 [MEMBER_MGMT] Cannot load member count: currentUserDID not available")
      return
    }

    guard let database = appState.mlsDatabase else {
      logger.error("🔍 [MEMBER_MGMT] Cannot load member count: database not available")
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
      logger.info(
        "🔍 [MEMBER_MGMT] ✅ Loaded member count: \(count) for conversation \(conversationId)")
    } catch {
      logger.error("🔍 [MEMBER_MGMT] ❌ Failed to load member count: \(error.localizedDescription)")
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
    guard let senderDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID
    else {
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

      let (messageId, receivedAt, seq, epoch) = try await manager.sendMessage(
        convoId: conversationId,
        plaintext: trimmed,
        embed: embed
      )

      logger.debug("Message sent successfully: \(messageId) with seq=\(seq), epoch=\(epoch)")

      // Extract timestamp before MainActor.run
      let timestamp = receivedAt.date

      // Ensure conversation exists in database before saving sent message
      // Use captured sender DID (not current user) in case of account switch during send
      if let database = appState.mlsDatabase {
        // Ensure conversation exists first (prevents foreign key constraint violations)
        if let convo = manager.conversations[conversationId] {
          do {
            try await storage.ensureConversationExists(
              userDID: senderDID,
              conversationID: conversationId,
              groupID: convo.groupId,
              database: database
            )
            logger.debug("✅ Conversation exists, saving sent message plaintext")
          } catch {
            logger.error(
              "❌ Failed to ensure conversation exists before saving: \(error.localizedDescription)")
          }
        }

        // Now save the plaintext (can't decrypt own messages in MLS, so we cache on send)
        do {
          try await storage.savePlaintextForMessage(
            messageID: messageId,
            conversationID: conversationId,
            plaintext: trimmed,
            senderID: senderDID,  // ← Sender DID (who sent the message)
            currentUserDID: appState.userDID ?? senderDID,  // ← Current user's DID (owner of this storage context)
            embed: embed,
            epoch: epoch,  // ✅ Use real epoch from server
            sequenceNumber: seq,  // ✅ Use real sequence number from server
            timestamp: receivedAt.date,  // ✅ Use server timestamp
            database: database
          )
          logger.info(
            "✅ Saved plaintext under sender DID: \(senderDID) for message: \(messageId) with seq=\(seq), epoch=\(epoch)"
          )
        } catch {
          logger.error("Failed to save sent message plaintext: \(error.localizedDescription)")
        }
      } else {
        logger.error("Cannot save plaintext: database not available")
      }

      await MainActor.run {
        let userDID = appState.userDID ?? ""
        let newMessage = Message(
          id: messageId,
          user: makeUser(for: userDID, isCurrentUser: true),
          status: .sent,
          createdAt: timestamp,
          text: trimmed
        )

        // Store embed in map for immediate rendering
        if let embed = embed {
          embedsMap[messageId] = embed
          logger.debug("Stored embed for sent message: \(messageId)")
        }

        // Only add if not already present (SSE might have added it)
        if !messages.contains(where: { $0.id == messageId }) {
          messages.append(newMessage)
          messageOrdering[messageId] = MessageOrderKey(
            epoch: Int(epoch),
            sequence: Int(seq),
            timestamp: timestamp
          )
          sortMessagesByMLSOrder()
          logger.debug(
            "Added message to UI: \(messageId) with order key epoch=\(epoch), seq=\(seq)")
        } else {
          logger.debug("Message already in UI (from SSE): \(messageId)")
        }

        // Clear composer state after successful send
        composerText = ""
        attachedEmbed = nil
      }
      ensureProfileLoaded(for: senderDID)
      refreshOrderMetadata(for: messageId)
    } catch {
      await MainActor.run {
        logger.error("Failed to send message: \(error.localizedDescription)")
        sendError = "Failed to send message: \(error.localizedDescription)"
        showingSendError = true
      }
    }
  }

  // MARK: - Real-Time Events

  // MARK: - Polling Fallback

  private func checkForNewMessages() async {
    // Don't poll if already loading or sending
    if isLoadingMessages || isSendingMessage { return }

    guard let manager = await appState.getMLSConversationManager(),
      let apiClient = await appState.getMLSAPIClient(),
      let database = appState.mlsDatabase,
      let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID
    else {
      return
    }

    do {
      // Get last cached sequence
      let lastCachedCursor = try? await MLSStorage.shared.fetchLastMessageCursor(
        conversationID: conversationId,
        currentUserDID: currentUserDID,
        database: database
      )

      let lastCachedSeq = lastCachedCursor.map { Int($0.seq) }

      // Check for new messages
      let (messageViews, _, _) = try await apiClient.getMessages(
        convoId: conversationId,
        limit: 50,
        sinceSeq: lastCachedSeq.map { Int($0) }
      )

      if !messageViews.isEmpty {
        logger.info("🔄 [POLLING] Found \(messageViews.count) new messages via fallback polling")

        // Process them using the manager (handles decryption and ordering)
        _ = try await manager.processMessagesInOrder(
          messages: messageViews,
          conversationID: conversationId
        )

        // Reload messages to update UI
        await loadCachedMessages()

        // Notify unified data source to refresh from storage
        await unifiedDataSource?.onMessagesDecrypted()
      }
    } catch {
      logger.warning("⚠️ [POLLING] Failed to check for new messages: \(error.localizedDescription)")
    }
  }

  private func startMessagePolling() {
    logger.info("📡 SSE: startMessagePolling() called for convoId: \(conversationId)")

    Task {
      // Use centralized event stream manager from AppState
      logger.info("📡 SSE: Getting event stream manager from AppState...")
      guard let streamManager = await appState.getMLSEventStreamManager() else {
        logger.error("📡 SSE: Failed to get MLS event stream manager - ABORTING")
        return
      }
      logger.info("📡 SSE: Got event stream manager, storing reference...")

      // Store reference for local cleanup
      await MainActor.run {
        eventStreamManager = streamManager
      }

      logger.info("📡 SSE: Calling subscribe() for convoId: \(conversationId)")

      // Subscribe to conversation events
      // CRITICAL FIX: Use proper @MainActor async closures that synchronously await handlers
      // Previous pattern used fire-and-forget Tasks which could be delayed by Swift's scheduler
      await streamManager.subscribe(
        to: conversationId,
        handler: MLSEventStreamManager.EventHandler(
          onMessage: { @MainActor messageEvent in
            self.logger.info(
              "📡 SSE: onMessage handler called for message: \(messageEvent.message.id)")
            await self.handleNewMessage(messageEvent)
          },
          onReaction: { @MainActor reactionEvent in
            self.logger.info("📡 SSE: onReaction handler called")
            await self.handleReaction(reactionEvent)
          },
          onTyping: { @MainActor typingEvent in
            self.logger.info("📡 SSE: onTyping handler called for did: \(typingEvent.did)")
            await self.handleTypingIndicator(typingEvent)
          },
          onInfo: { @MainActor infoEvent in
            self.logger.info("📡 SSE: onInfo handler called")
            await self.handleInfoEvent(infoEvent)
          },
          onNewDevice: { @MainActor newDeviceEvent in
            self.logger.info("📡 SSE: onNewDevice handler called")
            await self.handleNewDeviceEvent(newDeviceEvent)
          },
          onGroupInfoRefreshRequested: { @MainActor refreshEvent in
            self.logger.info("📡 SSE: onGroupInfoRefreshRequested handler called")
            await self.handleGroupInfoRefreshRequested(refreshEvent)
          },
          onReadditionRequested: { @MainActor readditionEvent in
            self.logger.info("📡 SSE: onReadditionRequested handler called")
            await self.handleReadditionRequested(readditionEvent)
          },
          onRead: { @MainActor readEvent in
            self.logger.info(
              "📡 SSE: onRead handler called for message: \(readEvent.messageId ?? "all")")
            await self.handleReadReceipt(readEvent)
          },
          onMembershipChanged: { @MainActor convoId, did, action in
            self.logger.info("📡 SSE: onMembershipChanged handler called")
            await self.handleMembershipChanged(convoId: convoId, did: did, action: action)
          },
          onKickedFromConversation: { @MainActor convoId, byDID, reason in
            self.logger.info("📡 SSE: onKickedFromConversation handler called")
            await self.handleKickedFromConversation(convoId: convoId, byDID: byDID, reason: reason)
          },
          onError: { @MainActor error in
            self.logger.error("📡 SSE: onError handler called: \(error.localizedDescription)")
          },
          onReconnected: { @MainActor [weak appState] in
            self.logger.info("📡 SSE: onReconnected handler called - triggering catchup")
            guard let appState = appState,
              let manager = await appState.getMLSConversationManager()
            else {
              self.logger.warning("⚠️ Cannot trigger catchup - manager not available")
              return
            }
            await manager.triggerCatchup(for: self.conversationId)
          }
        )
      )
      logger.info("📡 SSE: subscribe() returned for convoId: \(conversationId)")
    }
  }

  private func stopMessagePolling() {
    logger.debug("Stopping SSE subscription for conversation: \(conversationId)")
    // Stop subscription for this conversation
    // Note: Manager is owned by AppState and shared across views
    // We only stop the subscription for THIS conversation, not all subscriptions
    Task {
      await eventStreamManager?.stop(conversationId)
    }
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
    guard
      let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID
    else {
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
            userDID: currentUserDID,
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
      // CRITICAL: Move I/O and FFI work OFF main thread to prevent UI blocking
      let messageId = event.message.id
      let storageRef = storage
      let (senderDID, displayText, embed): (String, String, MLSEmbedData?) =
        try await Task.detached(priority: .userInitiated) {
          if let storedSender = try? await storageRef.fetchSenderForMessage(
            messageId, currentUserDID: currentUserDID, database: database),
            let storedPlaintext = try? await storageRef.fetchPlaintextForMessage(
              messageId, currentUserDID: currentUserDID, database: database)
          {
            // Already decrypted and cached
            let embed = try? await storageRef.fetchEmbedForMessage(
              messageId, currentUserDID: currentUserDID, database: database)
            return (storedSender, storedPlaintext, embed)
          } else {
            // Need to decrypt - this extracts sender from MLS credentials (heavy FFI work)
            let decryptedMessage = try await manager.decryptMessage(event.message)
            return (decryptedMessage.senderDID, decryptedMessage.text ?? "", decryptedMessage.embed)
          }
        }.value

      logger.debug(
        "Processed SSE message \(event.message.id) from \(senderDID) (hasEmbed: \(embed != nil))")

      let isCurrentUser = isMessageFromCurrentUser(senderDID: senderDID)
      logger.info(
        "🔍 MLS_OWNERSHIP: SSE result for message \(event.message.id): isCurrentUser = \(isCurrentUser)"
      )

      // CRITICAL: Check if this is from current user AFTER decryption
      if isCurrentUser && displayText.isEmpty {
        logger.warning(
          "⚠️ SSE message \(event.message.id) is from current user but has no plaintext")
        logger.warning("   Self-decryption is impossible by MLS design - skipping SSE processing")
        logger.warning("   This message will be added by sendMLSMessage with cached plaintext")
        return
      }

      // Store embed in map for later rendering
      if let embed = embed {
        embedsMap[event.message.id] = embed
      }

      // Fetch error information from database if available (SSE path)
      // Use MLSStorage helper (avoids direct db.read on main thread)
      if let messageModel = try? await MLSStorage.shared.fetchMessage(
        messageID: event.message.id,
        currentUserDID: currentUserDID,
        database: database
      ), messageModel.processingError != nil || messageModel.validationFailureReason != nil {
        messageErrorsMap[event.message.id] = MessageErrorInfo(
          processingError: messageModel.processingError,
          processingAttempts: messageModel.processingAttempts,
          validationFailureReason: messageModel.validationFailureReason
        )
      }

      let newMessage = Message(
        id: event.message.id,
        user: makeUser(for: senderDID, isCurrentUser: isCurrentUser),
        status: .sent,
        createdAt: event.message.createdAt.date,
        text: displayText
      )

      logger.info(
        "🔍 MLS_OWNERSHIP: Created SSE Message object - user.name: '\(newMessage.user.name ?? "nil")', user.isCurrentUser: \(newMessage.user.isCurrentUser)"
      )

      messageOrdering[newMessage.id] = MessageOrderKey(
        epoch: event.message.epoch,
        sequence: event.message.seq,
        timestamp: event.message.createdAt.date
      )

      // Add to messages if not already present
      if !messages.contains(where: { $0.id == newMessage.id }) {
        messages.append(newMessage)
        logger.debug("🔍 MLS_OWNERSHIP: Added new message from SSE to UI")
      } else {
        logger.debug("🔍 MLS_OWNERSHIP: SSE message already in UI, skipping")
      }

      sortMessagesByMLSOrder()
      ensureProfileLoaded(for: senderDID)

      // Notify unified data source to refresh from storage
      await unifiedDataSource?.onMessagesDecrypted()

    } catch let error as MLSError {
      if case .ratchetStateDesync(let message) = error {
        logger.error("🔴 RATCHET STATE DESYNC in SSE: \(message)")
        logger.error("   Triggering conversation re-sync...")

        // Mark conversation as needing re-sync
        await MainActor.run {
          sendError = "Message decryption failed: conversation state out of sync. Reloading..."
          showingSendError = true
        }

        // Trigger recovery by re-loading conversation (this will process Welcome if available)
        await loadConversationAndMessages()
      } else {
        logger.error("Failed to process SSE message: \(error.localizedDescription)")
      }
    } catch {
      logger.error("Failed to process SSE message: \(error.localizedDescription)")
    }
  }

  @MainActor
  private func handleReaction(_ event: BlueCatbirdMlsStreamConvoEvents.ReactionEvent) async {
    logger.debug(
      "Received reaction via SSE: \(event.action) \(event.reaction) on \(event.messageId)")

    let senderDID = event.did.description

    if event.action == "add" {
      // Add reaction to map
      let reaction = MLSMessageReaction(
        messageId: event.messageId,
        reaction: event.reaction,
        senderDID: senderDID,
        reactedAt: Date()
      )

      var reactions = messageReactionsMap[event.messageId] ?? []
      // Prevent duplicates
      if !reactions.contains(where: { $0.reaction == event.reaction && $0.senderDID == senderDID })
      {
        reactions.append(reaction)
        messageReactionsMap[event.messageId] = reactions
        logger.debug(
          "Added reaction '\(event.reaction)' from \(senderDID) to message \(event.messageId)")

        // Persist to SQLite for cross-session access
        persistReaction(
          messageId: event.messageId, emoji: event.reaction, actorDID: senderDID, action: "add")

        // Ensure profile is loaded for the reactor so their name/avatar displays correctly
        ensureProfileLoaded(for: senderDID)
      }
    } else if event.action == "remove" {
      // Remove reaction from map
      if var reactions = messageReactionsMap[event.messageId] {
        reactions.removeAll { $0.reaction == event.reaction && $0.senderDID == senderDID }
        if reactions.isEmpty {
          messageReactionsMap.removeValue(forKey: event.messageId)
        } else {
          messageReactionsMap[event.messageId] = reactions
        }
        logger.debug(
          "Removed reaction '\(event.reaction)' from \(senderDID) on message \(event.messageId)")

        // Persist removal to SQLite
        persistReaction(
          messageId: event.messageId, emoji: event.reaction, actorDID: senderDID, action: "remove")
      }
    }

    // Keep the unified chat data source in sync so reactions render immediately.
    unifiedDataSource?.applyReactionEvent(
      messageID: event.messageId,
      emoji: event.reaction,
      senderDID: senderDID,
      action: event.action
    )
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
    // Typing indicator is displayed via typingIndicatorView above the composer
  }

  /// Handle new device events from SSE stream
  /// Forwards to MLSDeviceSyncManager for processing multi-device additions
  @MainActor
  private func handleNewDeviceEvent(_ event: BlueCatbirdMlsStreamConvoEvents.NewDeviceEvent) async {
    logger.info(
      "📱 [NewDeviceEvent] Received for convo \(conversationId) - user: \(event.userDid), device: \(event.deviceId)"
    )

    guard let manager = await appState.getMLSConversationManager() else {
      logger.warning("⚠️ [NewDeviceEvent] Cannot handle - manager not available")
      return
    }

    // Forward to device sync manager for processing
    await manager.handleNewDeviceSSEEvent(event)
  }

  /// Handle GroupInfo refresh request events from SSE stream
  /// When another member encounters stale GroupInfo during rejoin, they request
  /// active members to publish fresh GroupInfo. If we're an active member and
  /// didn't make this request ourselves, we export and upload fresh GroupInfo.
  @MainActor
  private func handleGroupInfoRefreshRequested(
    _ event: BlueCatbirdMlsStreamConvoEvents.GroupInfoRefreshRequestedEvent
  ) async {
    logger.info(
      "🔄 [GroupInfoRefresh] Received request for convo \(event.convoId) from \(event.requestedBy)")

    // Get current user DID to check if this is our own request
    guard
      let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID
    else {
      logger.warning("⚠️ [GroupInfoRefresh] Cannot handle - userDID not available")
      return
    }

    // Don't respond to our own requests
    if event.requestedBy.didString().hasPrefix(currentUserDID)
      || currentUserDID.hasPrefix(event.requestedBy.didString())
    {
      logger.info("🔄 [GroupInfoRefresh] Ignoring own request")
      return
    }

    guard let manager = await appState.getMLSConversationManager() else {
      logger.warning("⚠️ [GroupInfoRefresh] Cannot handle - manager not available")
      return
    }

    // Forward to manager for processing (export GroupInfo and upload to server)
    await manager.handleGroupInfoRefreshRequest(convoId: event.convoId)
  }

  /// Handle re-addition request events from SSE stream
  /// When a member cannot rejoin (Welcome and External Commit both failed), they request
  /// active members to re-add them. If we're an active member, we re-add the user.
  @MainActor
  private func handleReadditionRequested(
    _ event: BlueCatbirdMlsStreamConvoEvents.ReadditionRequestedEvent
  ) async {
    logger.info(
      "🆘 [Readdition] Received request for user \(event.userDid.didString().prefix(20))... in convo \(event.convoId)"
    )

    // Get current user DID to check if this is our own request
    guard
      let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID
    else {
      logger.warning("⚠️ [Readdition] Cannot handle - userDID not available")
      return
    }

    // Don't respond to our own requests
    if event.userDid.didString().hasPrefix(currentUserDID)
      || currentUserDID.hasPrefix(event.userDid.didString())
    {
      logger.info("🆘 [Readdition] Ignoring own request")
      return
    }

    guard let manager = await appState.getMLSConversationManager() else {
      logger.warning("⚠️ [Readdition] Cannot handle - manager not available")
      return
    }

    // Forward to manager for processing (re-add the user with fresh KeyPackages)
    await manager.handleReadditionRequest(
      convoId: event.convoId, userDidToAdd: event.userDid.didString())
  }

  /// Handle info events from SSE stream
  @MainActor
  private func handleInfoEvent(_ event: BlueCatbirdMlsStreamConvoEvents.InfoEvent) async {
    logger.info("ℹ️ [InfoEvent] Received for convo \(conversationId)")
    // Handle any informational events from the server
    // Currently a no-op, but can be extended for server-side announcements
  }

  /// Handle read receipt events from SSE stream
  @MainActor
  private func handleReadReceipt(_ event: BlueCatbirdMlsStreamConvoEvents.ReadEvent) async {
    let readerDID = event.did.description

    // Don't track our own read receipts
    guard readerDID != appState.userDID else {
      logger.debug("📬 [READ_RECEIPTS] Ignoring own read receipt")
      return
    }

    if let messageId = event.messageId {
      // Specific message was read
      logger.info("📬 [READ_RECEIPTS] User \(readerDID.prefix(20))... read message \(messageId)")

      var readers = messageReadByMap[messageId] ?? Set<String>()
      readers.insert(readerDID)
      messageReadByMap[messageId] = readers

      logger.debug("📬 [READ_RECEIPTS] Message \(messageId) now read by \(readers.count) users")
    } else {
      // All messages were marked as read by this user
      logger.info("📬 [READ_RECEIPTS] User \(readerDID.prefix(20))... read all messages")

      // Mark all messages from current user as read by this reader
      for message in messages where message.user.isCurrentUser {
        var readers = messageReadByMap[message.id] ?? Set<String>()
        readers.insert(readerDID)
        messageReadByMap[message.id] = readers
      }
    }
  }

  /// Handle membership changed events from SSE stream
  @MainActor
  private func handleMembershipChanged(convoId: String, did: DID, action: MembershipAction) async {
    logger.info(
      "👥 [MembershipChanged] Conversation \(convoId) - DID: \(did.didString()), action: \(action.rawValue)"
    )

    // Refresh member list and count
    await loadMemberCount()
    await checkAdminStatus()
  }

  /// Handle kicked from conversation events from SSE stream
  @MainActor
  private func handleKickedFromConversation(convoId: String, byDID: DID, reason: String?) async {
    logger.warning(
      "🚫 [Kicked] Kicked from conversation \(convoId) by \(byDID.didString()), reason: \(reason ?? "none")"
    )

    // Show an alert and dismiss the view
    await MainActor.run {
      sendError = "You have been removed from this conversation."
      showingSendError = true
    }

    // Dismiss the view after a delay
    try? await Task.sleep(nanoseconds: 2_000_000_000)
    dismiss()
  }

  private func handleMessageMenuAction(action: CustomMessageMenuAction, message: Message) {
    switch action {
    case .copy:
      UIPasteboard.general.string = message.text
    case .report:
      messageToReport = message
      showingReportSheet = true
    case .deleteForMe:
      messageToDelete = message
      showingDeleteAlert = true
    }
  }

  private func deleteMessage(_ message: Message) {
    messages.removeAll { $0.id == message.id }
    messageOrdering.removeValue(forKey: message.id)
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
      let apiClient = await appState.getMLSAPIClient()
    else {
      logger.error("Recovery failed: MLS services unavailable")
      recoveryState = .failed("MLS service unavailable. Please restart the app.")
      showingRecoveryError = true
      return
    }

    do {
      // Step 1: Join via External Commit (atomic rejoin)
      logger.debug("Joining via External Commit for recovery...")
      guard let userDid = manager.userDid else {
        logger.error("Recovery failed: No user DID available")
        recoveryState = .failed("User authentication required")
        showingRecoveryError = true
        return
      }

      // Use MLSClient to join via External Commit
      _ = try await manager.mlsClient.joinByExternalCommit(for: userDid, convoId: conversationId)

      logger.info("Successfully rejoined conversation via External Commit")

      // Step 2: Mark success
      recoveryState = .success
      logger.info("Recovery successful - reinitializing conversation")

      // Step 3: Reload conversation and messages
      await loadConversationAndMessages()

      // Reset recovery state after successful reload
      recoveryState = .none

    } catch {
      logger.error("Recovery failed: \(error.localizedDescription)")
      recoveryState = .failed(error.localizedDescription)
      showingRecoveryError = true
    }
  }

  // MARK: - Message Ordering

  @MainActor
  private func applyMessageOrderUpdates(_ updates: [String: MessageOrderKey]) {
    logger.debug("🔢 [ORDER] Applying \(updates.count) order updates to messageOrdering dictionary")
    for (id, key) in updates {
      logger.debug(
        "🔢 [ORDER] Setting order for \(id.prefix(8)): epoch=\(key.epoch) seq=\(key.sequence)")
      messageOrdering[id] = key
    }
    logger.debug("🔢 [ORDER] messageOrdering dictionary now has \(messageOrdering.count) entries")
  }

  @MainActor
  private func sortMessagesByMLSOrder() {
    logger.debug("🔢 [SORT] Sorting \(messages.count) messages by MLS order")
    logger.debug("🔢 [SORT] messageOrdering dictionary has \(messageOrdering.count) entries")

    // Log first few ordering keys before sorting
    for (index, msg) in messages.prefix(5).enumerated() {
      let key = orderingKey(for: msg)
      let currentUserIndicator = msg.user.isCurrentUser ? " (current user)" : ""
      let timestampMs = key.timestamp.timeIntervalSince1970 * 1000
      logger.debug(
        "🔢 [SORT] BEFORE[\(index)] msg=\(msg.id.prefix(8)) epoch=\(key.epoch) seq=\(key.sequence) ts=\(String(format: "%.3f", timestampMs))ms sender=\(msg.user.id.suffix(8))\(currentUserIndicator)"
      )
    }

    messages.sort { lhs, rhs in
      let lhsKey = orderingKey(for: lhs)
      let rhsKey = orderingKey(for: rhs)
      if lhsKey == rhsKey {
        // Use messageID as final tiebreaker for deterministic ordering
        // This handles edge cases where duplicate (epoch, seq) exist from old server data
        return lhs.id < rhs.id
      }
      return lhsKey < rhsKey
    }

    // Log first few ordering keys after sorting
    for (index, msg) in messages.prefix(5).enumerated() {
      let key = orderingKey(for: msg)
      let currentUserIndicator = msg.user.isCurrentUser ? " (current user)" : ""
      let timestampMs = key.timestamp.timeIntervalSince1970 * 1000
      logger.debug(
        "🔢 [SORT] AFTER[\(index)] msg=\(msg.id.prefix(8)) epoch=\(key.epoch) seq=\(key.sequence) ts=\(String(format: "%.3f", timestampMs))ms sender=\(msg.user.id.suffix(8))\(currentUserIndicator)"
      )
    }
  }

  @MainActor
  private func orderingKey(for message: Message) -> MessageOrderKey {
    messageOrdering[message.id]
      ?? MessageOrderKey(
        epoch: Int.max,
        sequence: Int.max,
        timestamp: message.createdAt
      )
  }

  private func refreshOrderMetadata(for messageID: String) {
    Task {
      guard let database = appState.mlsDatabase,
        let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID
      else {
        return
      }

      do {
        // Use MLSStorage helper (avoids direct db.read on main thread)
        if let model = try await MLSStorage.shared.fetchMessage(
          messageID: messageID,
          currentUserDID: currentUserDID,
          database: database
        ) {
          await MainActor.run {
            messageOrdering[messageID] = MessageOrderKey(
              epoch: Int(model.epoch),
              sequence: Int(model.sequenceNumber),
              timestamp: model.timestamp
            )
            sortMessagesByMLSOrder()
          }
        }
      } catch {
        logger.error(
          "Failed to refresh order metadata for \(messageID): \(error.localizedDescription)")
      }
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
    let normalizedSender = senderDID.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
      .lowercased()
    let normalizedCurrent = currentUserDID.trimmingCharacters(
      in: CharacterSet.whitespacesAndNewlines
    ).lowercased()

    logger.debug("🔍 MLS_OWNERSHIP: Sender DID normalized = '\(normalizedSender)'")
    logger.debug("🔍 MLS_OWNERSHIP: Current DID normalized = '\(normalizedCurrent)'")

    let isMatch = normalizedSender == normalizedCurrent
    logger.info(
      "🔍 MLS_OWNERSHIP: \(isMatch ? "✅ MATCH" : "❌ NO MATCH") - isCurrentUser = \(isMatch)")

    return isMatch
  }

  private func chatIdentity(
    for did: String,
    fallbackName: String?,
    isCurrentUser: Bool
  ) -> (name: String, avatarURL: URL?) {
    if isCurrentUser {
      let avatar = participantProfiles[did]?.avatarURL
      return ("You", avatar)
    }

    if let profile = participantProfiles[did] {
      let trimmedDisplayName = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
      let preferredName =
        (trimmedDisplayName?.isEmpty == false ? trimmedDisplayName : nil) ?? profile.handle
      return (preferredName ?? fallbackName ?? formatDID(did), profile.avatarURL)
    }

    if let member = members.first(where: { $0.did == did }) {
      if let displayName = member.displayName, !displayName.isEmpty {
        return (displayName, nil)
      }
      if let handle = member.handle, !handle.isEmpty {
        return (handle, nil)
      }
    }

    return (fallbackName ?? formatDID(did), nil)
  }

  private func formatDID(_ did: String) -> String {
    // Extract handle or last part of DID for display
    if let lastPart = did.split(separator: ":").last {
      return String(lastPart.prefix(12))
    }
    return did
  }

  /// Create a User object with profile data for a given DID
  /// - Parameters:
  ///   - did: The user's DID
  ///   - isCurrentUser: Whether this user is the current user
  /// - Returns: A User object with profile name and avatar if available
  private func makeUser(for did: String, isCurrentUser: Bool) -> User {
    let profile = participantProfiles[did]
    let displayName: String
    if isCurrentUser {
      displayName = "You"
    } else if let name = profile?.displayName, !name.isEmpty {
      displayName = name
    } else if let handle = profile?.handle, !handle.isEmpty {
      displayName = handle
    } else {
      displayName = formatDID(did)
    }

    return User(
      id: did,
      name: displayName,
      avatarURL: profile?.avatarURL,
      isCurrentUser: isCurrentUser
    )
  }

  /// Rebuild message User objects with current profile data
  /// Called after profiles are loaded to update names and avatars
  @MainActor
  private func rebuildMessagesWithProfiles() {
    guard !participantProfiles.isEmpty else { return }

    messages = messages.map { message in
      let isCurrentUser = message.user.isCurrentUser
      let newUser = makeUser(for: message.user.id, isCurrentUser: isCurrentUser)

      // Skip if nothing changed
      if newUser.name == message.user.name && newUser.avatarURL == message.user.avatarURL {
        return message
      }

      return Message(
        id: message.id,
        user: newUser,
        status: message.status,
        createdAt: message.createdAt,
        text: message.text,
        embed: message.embed
      )
    }

    logger.debug("Rebuilt \(messages.count) messages with profile data")
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
