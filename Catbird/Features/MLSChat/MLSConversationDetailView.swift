import CatbirdMLSCore
import GRDB
import OSLog
import Petrel
import PhotosUI
import SwiftUI

#if os(iOS)

// MARK: - Recovery State

/// State tracking for key package desync recovery
enum RecoveryState: Equatable {
  case none
  case needed
  case inProgress
  case success
  case failed(String)
}

struct RejoinStatusPresentation: Equatable {
  let title: String
  let detail: String
  let iconName: String
  let showsProgress: Bool
  let showsRetry: Bool
}

func rejoinStatusPresentation(for recoveryState: RecoveryState) -> RejoinStatusPresentation? {
  switch recoveryState {
  case .inProgress:
    return RejoinStatusPresentation(
      title: "Updating secure session",
      detail: "Rejoining to keep forward secrecy up to date.",
      iconName: "arrow.triangle.2.circlepath.circle.fill",
      showsProgress: true,
      showsRetry: false
    )
  case .success:
    return RejoinStatusPresentation(
      title: "Secure session restored",
      detail: "You're rejoined and can continue chatting.",
      iconName: "checkmark.shield.fill",
      showsProgress: false,
      showsRetry: false
    )
  case .failed:
    return RejoinStatusPresentation(
      title: "Secure rejoin not completed",
      detail: "Your messages remain protected. Try rejoining again.",
      iconName: "exclamationmark.shield.fill",
      showsProgress: false,
      showsRetry: true
    )
  case .none, .needed:
    return nil
  }
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
/// Tracks which MLS conversations are currently visible in the foreground.
/// Used by NotificationManager to suppress banners for the active chat.
final class MLSActiveConversationTracker: @unchecked Sendable {
  static let shared = MLSActiveConversationTracker()
  private let lock = NSLock()
  private var activeIDs: Set<String> = []

  func setActive(_ conversationID: String) {
    lock.lock()
    activeIDs.insert(conversationID)
    lock.unlock()
  }

  func setInactive(_ conversationID: String) {
    lock.lock()
    activeIDs.remove(conversationID)
    lock.unlock()
  }

  func isActive(_ conversationID: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return activeIDs.contains(conversationID)
  }
}

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
  @State private var participantProfiles: [String: MLSProfileEnricher.ProfileData] = [:]
  @State private var isSendingMessage = false
  @State private var showingEncryptionInfo = false
  @State private var webSocketManager: MLSWebSocketManager?
  @State private var stateObserver: MLSStateObserver?  // Observer for encrypted MLS events (reactions)
  @State private var serverError: String?
  @State private var hasStartedSubscription = false
  @State private var sendError: String?
  @State private var showingSendError = false
  @State private var pipelineError: String?
  @State private var showingLeaveConfirmation = false
  @State private var showingGroupDetail = false
  @State private var showingAdminDashboard = false
  @State private var isCurrentUserAdmin = false
  @State private var recoveryState: RecoveryState = .none
  @State private var showingRecoveryError = false
  @State private var showingReportSpamSheet = false
  @State private var reportSpamDID: String?
  @State private var reportSpamDisplayName: String?
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

  @State private var isLoadingMoreMessages = false
  @State private var hasMoreMessages = true

  // Composer state
  @State private var composerText = ""
  @State private var attachedEmbed: MLSEmbedData?

  // Image DM support
  @State private var imageSender: MLSImageSender?
  @State private var showingPhotoPicker = false
  @State private var selectedPhotoItem: PhotosPickerItem?
  @State private var embedPreviewUIImage: PlatformImage?

  // GIF & Post pickers
  @State private var showingGifPicker = false
  @State private var showingPostPicker = false

  // Voice DM support
  @State private var voiceSender: MLSVoiceSender?
  @State private var voiceComposerMode: ComposerMode = .compose
  @State private var voicePreview: MLSVoiceSender.VoicePreview?

  // Delete state
  @State private var messageToDelete: Message?
  @State private var showingDeleteAlert = false

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

  private var isChatTabActive: Bool {
    appState.navigationManager.currentTabIndex == 4
  }

  /// Whether this conversation is a pending chat request that needs acceptance
  private var isPendingRequest: Bool {
    conversationModel?.requestState == .pendingInbound
  }

  /// Whether we currently have any message content visible in either legacy or unified chat state.
  private var hasVisibleMessages: Bool {
    if let dataSource = unifiedDataSource {
      return !dataSource.messages.isEmpty
    }
    return false
  }

  private var mainContent: some View {
    ZStack {
      // Use unified UICollectionView-based chat
      if let dataSource = unifiedDataSource {
        ChatCollectionViewBridge(
          dataSource: dataSource,
          navigationPath: chatNavigationPath,
          onMessageLongPress: { message in
            handleMessageLongPress(message)
          },
          onRequestEmojiPicker: { messageID in
            emojiPickerMessageID = messageID
            showingEmojiPicker = true
          },
          composerConfig: isPendingRequest ? nil : InlineComposerConfig(
            onSend: { text in
              let embed = unifiedDataSource?.attachedEmbed
              unifiedDataSource?.attachedEmbed = nil
              embedPreviewUIImage = nil
              Task { await sendMLSMessage(text: text, embed: embed) }
            },
            onAttachTapped: { },
            onPhotoPicker: {
              showingPhotoPicker = true
            },
            onGifPicker: {
              showingGifPicker = true
            },
            onPostPicker: {
              showingPostPicker = true
            },
            embedPreviewImage: embedPreviewUIImage,
            hasEmbed: unifiedDataSource?.attachedEmbed != nil,
            onEmbedRemoved: {
              unifiedDataSource?.attachedEmbed = nil
              embedPreviewUIImage = nil
            },
            voiceMode: voiceComposerMode,
            voicePreviewURL: voicePreview?.localURL,
            voiceRecordingDuration: {
              if case .recording(let duration) = voiceSender?.state {
                return duration
              }
              return 0
            }(),
            onVoiceRecordingStarted: {
              Task { await startVoiceRecording() }
            },
            onVoiceRecordingLocked: {
              lockVoiceRecording()
            },
            onVoiceRecordingStopped: {
              Task { await stopAndPreview() }
            },
            onVoiceRecordingCancelled: {
              cancelVoiceRecording()
            },
            onVoicePreviewSend: {
              Task { await sendVoicePreview() }
            },
            onVoicePreviewDiscard: {
              discardVoicePreview()
            }
          )
        )
        .ignoresSafeArea(.container)
        .ignoresSafeArea(.keyboard)
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
        .customEmojiPicker(isPresented: $showingEmojiPicker) { emoji in
          selectedEmoji = emoji
        }
      }

      if isLoadingMessages && !isLoadingProfiles && !hasVisibleMessages {
        ProgressView("Loading messages...")
          .padding()
          .background(.regularMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 10))
      }

      if let pipelineError, !isLoadingMessages, !hasVisibleMessages {
        VStack(spacing: 12) {
          Text("Couldn't load messages")
            .font(.headline)

          Text(pipelineError)
            .font(.subheadline)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)

          HStack(spacing: 12) {
            Button("Retry") {
              retryConversationPipeline()
            }
            .buttonStyle(.borderedProminent)

            Button("Dismiss") {
              self.pipelineError = nil
            }
            .buttonStyle(.bordered)
          }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding()
      }

      if let status = rejoinStatusPresentation(for: recoveryState) {
        VStack {
          secureRejoinStatusBanner(status)
            .padding(.horizontal)
            .padding(.top, 8)
          Spacer()
        }
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
    .sheet(isPresented: $showingGifPicker) {
      GifPickerView { gif in
        let mp4URL = gif.media_formats.mp4?.url
          ?? gif.media_formats.loopedmp4?.url
          ?? gif.media_formats.tinymp4?.url
          ?? gif.media_formats.nanomp4?.url
        guard let mp4URL else { return }
        let thumbnailURL = gif.media_formats.tinygif?.url ?? gif.media_formats.gif?.url
        let dims = gif.media_formats.mp4?.dims
        let width = dims?.first
        let height = dims?.count ?? 0 > 1 ? dims?[1] : nil
        unifiedDataSource?.attachedEmbed = .gif(MLSGIFEmbed(
          tenorURL: "https://tenor.com/view/\(gif.id)",
          mp4URL: mp4URL,
          title: gif.content_description,
          thumbnailURL: thumbnailURL,
          width: width,
          height: height
        ))
      }
    }
    .sheet(isPresented: $showingPostPicker) {
      MLSPostPickerView { post in
        let postText: String
        if case .knownType(let record) = post.record,
          let feedPost = record as? AppBskyFeedPost
        {
          postText = feedPost.text
        } else {
          postText = ""
        }
        var images: [MLSPostImage]?
        if case .appBskyEmbedImagesView(let imagesView) = post.embed {
          let mapped = imagesView.images.compactMap { img -> MLSPostImage? in
            guard let fullsize = img.fullsize.url, let thumb = img.thumb.url else { return nil }
            return MLSPostImage(thumb: thumb, fullsize: fullsize, alt: img.alt)
          }
          images = mapped.isEmpty ? nil : mapped
        }
        unifiedDataSource?.attachedEmbed = .post(MLSPostEmbed(
          uri: post.uri.uriString(),
          cid: post.cid.string,
          authorDid: post.author.did.description,
          authorHandle: post.author.handle.description,
          authorDisplayName: post.author.displayName,
          authorAvatar: post.author.finalAvatarURL(),
          text: postText,
          createdAt: post.indexedAt.date,
          likeCount: post.likeCount,
          replyCount: post.replyCount,
          repostCount: post.repostCount,
          images: images
        ))
      }
    }
    .photosPicker(isPresented: $showingPhotoPicker, selection: $selectedPhotoItem, matching: .images)
    .onChange(of: selectedPhotoItem) { _, newItem in
      guard let newItem else { return }
      selectedPhotoItem = nil
      Task {
        if imageSender == nil {
          imageSender = MLSImageSender(client: appState.client)
        }
        guard let sender = imageSender else { return }
        if let embed = await sender.processImage(from: newItem, convoId: conversationId) {
          unifiedDataSource?.attachedEmbed = .image(embed)
          // Load thumbnail for embed preview
          if let data = try? await newItem.loadTransferable(type: Data.self),
             let image = PlatformImage(data: data) {
            let size = CGSize(width: 64, height: 64)
            let renderer = CrossPlatformImageRenderer(size: size)
            embedPreviewUIImage = renderer.image { context in
              context.interpolationQuality = .high
              image.draw(in: CGRect(origin: .zero, size: size))
            }
          }
        }
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

  // MARK: - Voice Recording

  @MainActor
  private func startVoiceRecording() async {
    guard let client = appState.atProtoClient else { return }
    if voiceSender == nil {
      voiceSender = MLSVoiceSender(client: client)
    }
    do {
      try await voiceSender?.startRecording()
      voiceComposerMode = .recording(locked: false)
    } catch {
      logger.error("Failed to start voice recording: \(error.localizedDescription)")
    }
  }

  @MainActor
  private func lockVoiceRecording() {
    voiceComposerMode = .recording(locked: true)
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
  }

  @MainActor
  private func stopAndPreview() async {
    guard let sender = voiceSender else { return }
    do {
      let preview = try await sender.finishRecording()
      voicePreview = preview
      voiceComposerMode = .preview(
        duration: TimeInterval(preview.durationMs) / 1000.0,
        waveform: preview.waveform
      )
    } catch {
      logger.error("Failed to prepare voice preview: \(error.localizedDescription)")
      voiceComposerMode = .compose
    }
  }

  @MainActor
  private func sendVoicePreview() async {
    guard let preview = voicePreview, let sender = voiceSender else { return }
    voiceComposerMode = .compose
    voicePreview = nil
    do {
      guard let manager = await appState.getMLSConversationManager() else {
        logger.error("Failed to get MLS manager for voice send")
        return
      }
      try await sender.send(preview: preview, convoId: conversationId, manager: manager)
    } catch {
      logger.error("Failed to send voice message: \(error.localizedDescription)")
    }
  }

  @MainActor
  private func discardVoicePreview() {
    voiceSender?.discardPreview()
    voicePreview = nil
    voiceComposerMode = .compose
  }

  @MainActor
  private func cancelVoiceRecording() {
    voiceSender?.cancelRecording()
    voiceComposerMode = .compose
  }

  // MARK: - Message Long Press Handler

  private func handleMessageLongPress(_ message: MLSMessageAdapter) {
    let generator = UIImpactFeedbackGenerator(style: .soft)
    generator.impactOccurred()

    // Store for potential report spam action
    reportSpamDID = message.senderID
    reportSpamDisplayName = message.senderDisplayName
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
      if isChatTabActive && chatNavigationPath.wrappedValue.isEmpty {
        VStack(spacing: 0) {
          if isPendingRequest {
            // Show accept/decline buttons for pending chat requests
            ChatRequestActionBar(
              conversationId: conversationId,
              onAccept: {
                Task { await acceptChatRequest() }
              },
              onDecline: {
                Task { await declineChatRequest() }
              }
            )
          } else {
            MLSMessageComposerView(
              text: $composerText,
              attachedEmbed: $attachedEmbed,
              conversationId: conversationId,
              onSend: { text, embed in
                Task { await sendMLSMessage(text: text, embed: embed) }
              },
              imageSender: imageSender
            )
          }
        }
      }
    }
  }

  // MARK: - Reaction Handling

  private func addReaction(messageId: String, emoji: String) {
    Task {
      guard let manager = await appState.getMLSConversationManager() else { return }

      do {
        // Use encrypted reaction (E2EE via MLS)
        _ = try await manager.sendEncryptedReaction(
          convoId: conversationId,
          messageId: messageId,
          emoji: emoji,
          action: .add
        )

        // Optimistic local update
        let reaction = MLSMessageReaction(
          messageId: messageId,
          reaction: emoji,
          senderDID: appState.userDID,
          reactedAt: Date()
        )

        await MainActor.run {
          var reactions = messageReactionsMap[messageId] ?? []
          reactions.append(reaction)
          messageReactionsMap[messageId] = reactions
        }

        // Persist to local storage
        persistReaction(
            messageId: messageId, emoji: emoji, actorDID: appState.userDID, action: "add")
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
          convoId: conversationId,
          messageId: messageId,
          emoji: emoji,
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
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("mls.conversation.initializationOverlay")
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

  @ViewBuilder
  private func secureRejoinStatusBanner(_ status: RejoinStatusPresentation) -> some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      if status.showsProgress {
        ProgressView()
          .scaleEffect(0.8)
      } else {
        Image(systemName: status.iconName)
          .foregroundStyle(status.showsRetry ? .orange : .green)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(status.title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.primary)
        Text(status.detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if status.showsRetry {
        Button("Retry") {
          Task { await performRecovery() }
        }
        .font(.caption.weight(.semibold))
      }
    }
    .padding(.horizontal, DesignTokens.Spacing.base)
    .padding(.vertical, DesignTokens.Spacing.sm)
    .background(.ultraThinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Size.radiusLG))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(status.title). \(status.detail)")
  }

  var body: some View {
    contentWithNavigation
      .task {
        MLSActiveConversationTracker.shared.setActive(conversationId)
        await setupView()
      }
      .onDisappear {
        MLSActiveConversationTracker.shared.setInactive(conversationId)
        isViewActive = false
        unifiedDataSource?.stopLocalTypingIndicatorIfNeeded()
        stopMessagePolling()
        unifiedDataSource?.stopObserving()
        // Final mark-as-read sweep to catch messages that arrived while viewing
        Task {
          await markMessagesAsRead()
        }
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
      .onChange(of: scenePhase) { oldPhase, newPhase in
        if newPhase == .active && isViewActive {
          logger.info("App became active - ensuring SSE is running")
          if !hasStartedSubscription {
            startMessagePolling()
            hasStartedSubscription = true
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
      .sheet(isPresented: $showingEncryptionInfo) {
        encryptionInfoSheet
      }
      .sheet(isPresented: $showingGroupDetail) {
        groupDetailSheet
      }
      .sheet(isPresented: $showingAdminDashboard) {
        adminDashboardSheet
      }
      .sheet(isPresented: $showingReportSpamSheet) {
        reportSpamSheet
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
  private var reportSpamSheet: some View {
    if let did = reportSpamDID,
      let apiClient = viewModel?.apiClient
    {
      MLSReportSpamSheet(
        conversationId: conversationId,
        reportedDid: did,
        reportedDisplayName: reportSpamDisplayName ?? did,
        apiClient: apiClient
      )
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

  private func resolveSetupDependencies() async -> (
    database: DatabasePool,
    apiClient: MLSAPIClient,
    conversationManager: MLSConversationManager
  )? {
    let maxAttempts = 2
    for attempt in 1...maxAttempts {
      let database = appState.mlsDatabase
      async let apiClientTask = appState.getMLSAPIClient()
      async let managerTask = appState.getMLSConversationManager(timeout: 12.0)

      let apiClient = await apiClientTask
      let conversationManager = await managerTask

      if let database, let apiClient, let conversationManager {
        return (database, apiClient, conversationManager)
      }

      if attempt < maxAttempts {
        logger.warning(
          "MLS setup dependencies unavailable for \(conversationId) on attempt \(attempt)/\(maxAttempts); retrying"
        )
        try? await Task.sleep(nanoseconds: 400_000_000)
      }
    }
    return nil
  }

  private func setupView() async {
    isViewActive = true
    if viewModel == nil {
      guard let dependencies = await resolveSetupDependencies()
      else {
        logger.error("Cannot initialize view: dependencies not available")
        sendError = "MLS service not available. Please restart the app."
        showingSendError = true
        await MainActor.run { isLoadingProfiles = false }
        return
      }

      // Ensure the database pool is fresh before loading messages.
      // After WAL corruption recovery, the pool may have been closed and recreated.
      // This updates conversationManager.database with a fresh pool if needed,
      // and propagates to appState.mlsDatabase via the onDatabaseRefreshed callback.
      try? await dependencies.conversationManager.refreshDatabaseIfNeeded()

      let newViewModel = MLSConversationDetailViewModel(
        conversationId: conversationId,
        database: dependencies.conversationManager.database,
        apiClient: dependencies.apiClient,
        conversationManager: dependencies.conversationManager
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

    // Initialize image sender
    if imageSender == nil {
      imageSender = MLSImageSender(client: appState.client)
    }

    // Setup observer for encrypted MLS events (reactions, read receipts, typing)
    await setupStateObserver()

    // Start WebSocket subscription before the bootstrap pipeline so ephemeral typing events
    // aren't missed while initial fetch/decrypt work is running.
    if !hasStartedSubscription {
      startMessagePolling()
      hasStartedSubscription = true
    }

    // Fire-and-forget MLS pipeline that outlives the view
    // This ensures MLS state updates complete even if user navigates away
    launchConversationPipeline()

    // UI-only work that can be cancelled if view disappears
    await loadMemberCount()
    await loadParticipantProfiles()

    // Hide loading state after profiles are loaded
    await MainActor.run {
      isLoadingProfiles = false
    }

    await checkAdminStatus()

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
    logger.info("📡 Registered MLS state observer for encrypted reactions")
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

      // SAFETY: Check if parent message is decrypted/valid before displaying in legacy path
      let parentMessage = unifiedDataSource?.message(for: messageId)
      guard parentMessage?.isDecryptedAndValid == true else {
        logger.warning(
          "⚠️ [REACTION-SAFETY] Suppressing reaction display for undecryptable message: \(messageId.prefix(16))"
        )
        // Still forward to data source for caching (it has its own safety check)
        unifiedDataSource?.applyReactionEvent(
          messageID: messageId,
          emoji: emoji,
          senderDID: senderDID,
          action: action
        )
        return
      }

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

      // Keep the unified chat data source in sync so reactions render immediately.
      unifiedDataSource?.applyReactionEvent(
        messageID: messageId,
        emoji: emoji,
        senderDID: senderDID,
        action: action
      )

    // Read receipts and typing indicators have been removed

    case .syncCompleted:
      await reloadConversationMetadata(userDID: userDID)

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
    // }

    ToolbarItem(placement: .primaryAction) {
      Button {
        showingGroupDetail = true
      } label: {
        Image(systemName: "info.circle")
          .accessibilityLabel("Conversation details")
      }
    }
  }

  // MARK: - Admin Status

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


  // MARK: - Other User (1:1)

  private var otherParticipant: (did: String, profile: MLSProfileEnricher.ProfileData?)? {
    let currentUserDID = appState.userDID
    let others = members.filter { $0.did.lowercased() != currentUserDID.lowercased() && $0.isActive }
    guard others.count == 1, let other = others.first else { return nil }
    let canonical = MLSProfileEnricher.canonicalDID(other.did)
    let profile = participantProfiles[other.did] ?? participantProfiles[canonical]
    return (other.did, profile)
  }

  private var isOneOnOne: Bool {
    otherParticipant != nil
  }

  // MARK: - Conversation Header (Toolbar Principal)

  @ViewBuilder
  private var encryptionStatusHeader: some View {
    let avatarSize: CGFloat = 50

    ZStack(alignment: .bottom) {
      Group {
        if isOneOnOne, let other = otherParticipant {
          AsyncProfileImage(
            url: other.profile?.avatarURL,
            size: avatarSize
          )
        } else {
          MLSGroupAvatarView(
            participants: participantViewModels,
            size: avatarSize,
            groupAvatarData: conversationModel?.avatarImageData,
            currentUserDID: appState.userDID
          )
        }
      }
      .frame(width: avatarSize, height: avatarSize)
      .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
      .offset(y: 12)
      Group {
        if #available(iOS 26.0, *) {
          HStack(spacing: 4) {
            Text(navigationTitle)
              .font(.system(size: 11, weight: .semibold))
              .lineLimit(1)
            Image(systemName: "lock.shield.fill")
              .font(.system(size: 9))
              .foregroundStyle(.green)
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 3)
          .glassEffect(in: .capsule)
        } else {
          HStack(spacing: 4) {
            Text(navigationTitle)
              .font(.system(size: 11, weight: .semibold))
              .lineLimit(1)
            Image(systemName: "lock.shield.fill")
              .font(.system(size: 9))
              .foregroundStyle(.green)
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 3)
          .background(.ultraThinMaterial, in: Capsule())
        }
      }
      .offset(y: 25)
    }
    .padding(.bottom, 10)
    .onTapGesture {
      showingGroupDetail = true
    }
    .accessibilityLabel("\(navigationTitle) conversation")
    .accessibilityHint("Tap to view conversation details")
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
            Button {
                showingEncryptionInfo = false
            } label: {
                Image(systemName: "checkmark")
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

  // MARK: - Group Detail Sheet

  @ViewBuilder
  private var groupDetailSheet: some View {
    if let model = conversationModel,
      let conversationManager = viewModel?.conversationManager
    {
      MLSGroupDetailView(
        conversationId: conversationId,
        conversationModel: model,
        conversationManager: conversationManager,
        currentUserDID: appState.userDID,
        participants: participantViewModels,
        participantProfiles: participantProfiles
      )
    }
  }

  private var participantViewModels: [MLSParticipantViewModel] {
    members.filter(\.isActive).map { member in
      let canonical = MLSProfileEnricher.canonicalDID(member.did)
      let profile = participantProfiles[member.did] ?? participantProfiles[canonical]
      return MLSParticipantViewModel(
        id: member.did,
        handle: profile?.handle ?? member.handle ?? member.did,
        displayName: profile?.displayName ?? member.displayName,
        avatarURL: profile?.avatarURL
      )
    }
  }

  // MARK: - Computed Properties

  private var navigationTitle: String {
    if let title = conversationModel?.title, !title.isEmpty {
      return title
    }

    // For 1:1, show the other participant's display name
     let currentUserDID = appState.userDID 
      let others = members.filter { $0.did.lowercased() != currentUserDID.lowercased() && $0.isActive }
      if others.count == 1, let other = others.first {
        let canonical = MLSProfileEnricher.canonicalDID(other.did)
        if let profile = participantProfiles[other.did] ?? participantProfiles[canonical] {
          return profile.displayName ?? profile.handle
        }
        return other.displayName ?? other.handle ?? "Secure Chat"
      }
    

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

  @MainActor
  private func reloadConversationMetadata(userDID: String?) async {
    guard let database = appState.mlsDatabase else {
      logger.warning("Cannot reload conversation metadata: database unavailable")
      return
    }

    guard
      let currentUserDID = userDID ?? appState.userDID
        ?? AppStateManager.shared.authentication.state.userDID
    else {
      logger.warning("Cannot reload conversation metadata: missing user DID")
      return
    }

    do {
      if let stored = try await storage.fetchConversation(
        conversationID: conversationId,
        currentUserDID: currentUserDID,
        database: database
      ) {
        conversationModel = stored
        logger.debug("Reloaded conversation metadata for \(conversationId.prefix(16))...")
      } else {
        _ = await ensureConversationMetadata()
      }
    } catch {
      logger.error("Failed to reload conversation metadata: \(error.localizedDescription)")
    }
  }

  private func resolveConversationView() async -> BlueCatbirdMlsChatDefs.ConvoView? {
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

  private struct PipelineTimeoutError: LocalizedError {
    let operation: String
    let seconds: TimeInterval

    var errorDescription: String? {
      let rounded = Int(seconds.rounded())
      return "Timed out after \(rounded)s while \(operation)."
    }
  }

  private final class TimeoutResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResolve = false

    func tryResolve() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if didResolve { return false }
      didResolve = true
      return true
    }
  }

  private final class ConversationPipelineGate: @unchecked Sendable {
    static let shared = ConversationPipelineGate()

    private let lock = NSLock()
    private var activeConversationIDs: Set<String> = []

    func begin(conversationID: String) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if activeConversationIDs.contains(conversationID) {
        return false
      }
      activeConversationIDs.insert(conversationID)
      return true
    }

    func end(conversationID: String) {
      lock.lock()
      defer { lock.unlock() }
      activeConversationIDs.remove(conversationID)
    }
  }

  private func withTimeout<T>(
    seconds: TimeInterval,
    operationName: String,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let gate = TimeoutResumeGate()

    return try await withCheckedThrowingContinuation { continuation in
      let operationTask = Task.detached(priority: .userInitiated) {
        do {
          let value = try await operation()
          if gate.tryResolve() {
            continuation.resume(returning: value)
          }
        } catch {
          if gate.tryResolve() {
            continuation.resume(throwing: error)
          }
        }
      }

      Task.detached(priority: .userInitiated) {
        do {
          try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
          if gate.tryResolve() {
            operationTask.cancel()
            continuation.resume(
              throwing: PipelineTimeoutError(operation: operationName, seconds: seconds)
            )
          }
        } catch {
          // Ignore cancellation: if the operation completes first, the timeout is irrelevant.
        }
      }
    }
  }

  @MainActor
  private func showPipelineError(_ message: String) {
    guard !hasVisibleMessages else {
      logger.info("Suppressing pipeline overlay because cached messages are already visible")
      return
    }
    pipelineError = message
  }

  private func launchConversationPipeline() {
    Task.detached(priority: .userInitiated) { [self] in
      await self.runConversationPipeline()
    }
  }

  private func retryConversationPipeline() {
    Task { @MainActor in
      pipelineError = nil
    }

    launchConversationPipeline()
  }

  /// MLS conversation pipeline that runs independently of view lifecycle
  /// This function is called from a detached task to ensure MLS state updates
  /// complete even if the user navigates away from the view
  private func runConversationPipeline() async {
    guard ConversationPipelineGate.shared.begin(conversationID: conversationId) else {
      logger.debug(
        "🚫 [PIPELINE] Skipping duplicate pipeline run for conversation: \(conversationId)")
      return
    }
    defer {
      ConversationPipelineGate.shared.end(conversationID: conversationId)
    }

    logger.info(
      "🎬 [PIPELINE] Starting MLS conversation pipeline for conversation: \(conversationId)")

    // PHASE 0: Fetch conversation metadata
    // Even if the view is dismissed, we need conversation metadata for subsequent operations
    guard await ensureConversationMetadata() != nil else {
      logger.error("❌ [PIPELINE] Conversation metadata unavailable for \(conversationId)")
      await showPipelineError("Couldn't load conversation details. Tap Retry to try again.")
      return
    }

    logger.info("📍 [PIPELINE] Starting Phase 1: Fetch new messages from server")

    // PHASE 1: Fetch and decrypt new messages from server
    await MainActor.run {
      pipelineError = nil
      isLoadingMessages = true
    }
    defer {
      Task { @MainActor in
        isLoadingMessages = false
      }
    }

    let groupInitializationTimeoutSeconds: TimeInterval = 20
    let fetchMessagesTimeoutSeconds: TimeInterval = 20
    let processMessagesTimeoutSeconds: TimeInterval = 30

    guard let manager = await appState.getMLSConversationManager(timeout: 15.0) else {
      logger.error("Failed to get MLS conversation manager")
      await showPipelineError("MLS service unavailable. Please try again.")
      return
    }

    // Ensure the MLS group is initialized for this conversation
    do {
      try await withTimeout(seconds: groupInitializationTimeoutSeconds, operationName: "initializing secure messaging") {
        try await manager.ensureGroupInitialized(for: conversationId)
      }
      logger.info("MLS group initialized for conversation \(conversationId)")
    } catch is PipelineTimeoutError {
      logger.error("⏱️ [PIPELINE] Timed out initializing MLS group for \(conversationId)")
      await showPipelineError("Timed out initializing secure messaging. Tap Retry to try again.")
      return
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
      await showPipelineError("Failed to initialize secure messaging. Tap Retry to try again.")
      return
    } catch let error as MLSAPIError {
      logger.error(
        "❌ Failed to initialize MLS group for \(conversationId): MLSAPIError - \(error.localizedDescription)"
      )
      if case .invalidResponse(let message) = error {
        logger.error("  → Invalid response details: \(message)")
      }
      await showPipelineError("Failed to initialize secure messaging. Tap Retry to try again.")
      return
    } catch {
      logger.error(
        "❌ Failed to initialize MLS group for \(conversationId): Unexpected error - \(type(of: error)) - \(error.localizedDescription)"
      )
      await showPipelineError("Failed to initialize secure messaging. Tap Retry to try again.")
      return
    }

    do {
      // Get current user DID for plaintext isolation
      guard
        let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID
      else {
        logger.error("Cannot load messages: currentUserDID not available")
        await showPipelineError("Cannot load messages: user not available. Please try again.")
        return
      }

      // Query database for last cached sequence number
      guard let database = appState.mlsDatabase else {
        logger.error("MLS database not available")
        await showPipelineError("Cannot load messages: database unavailable. Please try again.")
        return
      }

            // Use MLSStorage helper method (avoids direct db.read on main thread)

            let lastCachedCursor = try? await withTimeout(seconds: 5.0, operationName: "checking cache") {

              try await MLSStorage.shared.fetchLastMessageCursor(

                conversationID: conversationId,

                currentUserDID: currentUserDID,

                database: database

              )

            }

      

            if let cursor = lastCachedCursor {

              logger.debug(

                "📍 Last cached message epoch=\(cursor.epoch), seq=\(cursor.seq), will fetch messages after this"

              )

            } else {

              logger.debug(

                "📍 No cached messages, will fetch all from server"

              )

            }

      

            let lastCachedSeq = lastCachedCursor.map { Int($0.seq) }

      

            // Fetch messages from server

            let apiClient = await appState.getMLSAPIClient()

            guard let apiClient = apiClient else {

              logger.error("Failed to get MLS API client")

              await showPipelineError("Cannot load messages: server client unavailable. Please try again.")

              return

            }

      

            // Only fetch NEW messages after last cached message

            let (messageViews, lastSeq, gapInfo) = try await withTimeout(

              seconds: fetchMessagesTimeoutSeconds,

              operationName: "fetching messages"

            ) {

              try await apiClient.getMessages(

                convoId: conversationId,

                limit: 50,

                sinceSeq: lastCachedSeq.map { Int($0) }

              )

            }

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
        _ = try await withTimeout(
          seconds: processMessagesTimeoutSeconds,
          operationName: "decrypting messages"
        ) {
          try await manager.processMessagesInOrder(
            messages: messageViews,
            conversationID: conversationId,
            source: "manual-fetch"
          )
        }
        logger.info("✅ Phase 1 complete: All messages decrypted and cached in order")
      } catch is PipelineTimeoutError {
        logger.error(
          "⏱️ [PIPELINE] Timed out processing/decrypting messages for \(conversationId)"
        )
        await showPipelineError("Timed out decrypting messages. Tap Retry to try again.")
        return
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
          await showPipelineError("Failed to decrypt messages. Tap Retry to try again.")
          return
        }
      } catch {
        logger.error("❌ Failed to process messages in order: \(error.localizedDescription)")
        await showPipelineError("Failed to decrypt messages. Tap Retry to try again.")
        return
      }

      // Start live updates after initial load
      await MainActor.run {
        if isViewActive && !hasStartedSubscription {
          startMessagePolling()
          hasStartedSubscription = true
          // Deferred re-sort to fix any messages that arrived during initial load
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            sortMessagesByMLSOrder()
          }
        }
      }

    } catch let error as PipelineTimeoutError {
      logger.error("⏱️ [PIPELINE] \(error.localizedDescription)")
      await showPipelineError("Timed out loading messages. Tap Retry to try again.")

      // Fallback: Attempt to connect WebSocket even if REST fetch fails
      // This ensures real-time updates work even if the initial sync hits a 500 error
      await MainActor.run {
        if isViewActive && !hasStartedSubscription {
          startMessagePolling()
          hasStartedSubscription = true
        }
      }
    } catch {
      logger.error("Failed to load messages: \(error.localizedDescription)")
      await showPipelineError("Failed to load messages. Tap Retry to try again.")

      // Fallback: Attempt to connect WebSocket even if REST fetch fails
      // This ensures real-time updates work even if the initial sync hits a 500 error
      await MainActor.run {
        if isViewActive && !hasStartedSubscription {
          startMessagePolling()
          hasStartedSubscription = true
        }
      }
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

    logger.info("📍 [ENTRY] Starting Phase 1: Fetch new messages from server")

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
            conversationID: conversationId,
            source: "manual-fetch"
          )
          logger.info("✅ Phase 1 complete: All messages decrypted and cached in order")
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

      // Start live updates after initial load
      await MainActor.run {
        if isViewActive && !hasStartedSubscription {
          startMessagePolling()
          hasStartedSubscription = true
          // Deferred re-sort to fix any messages that arrived during initial load
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            sortMessagesByMLSOrder()
          }
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

    // Seed participantProfiles from the enricher's actor-level cache and DB members
    // so that makeUser() can resolve display names and avatars for Phase 0 messages
    // without waiting for the network fetch in loadParticipantProfiles().
    do {
      let memberModels = try await storage.fetchMembers(
        conversationID: conversationId,
        currentUserDID: currentUserDID,
        database: database
      )
      let memberDIDs = memberModels.map(\.did)
      let enricherProfiles = await appState.mlsProfileEnricher.getCachedProfiles(for: memberDIDs)

      await MainActor.run {
        // First: seed from DB member data (handles/names but no avatars)
        for member in memberModels {
          if participantProfiles[member.did] == nil,
            member.handle != nil || member.displayName != nil
          {
            participantProfiles[member.did] = MLSProfileEnricher.ProfileData(
              did: member.did,
              handle: member.handle ?? "",
              displayName: member.displayName,
              avatarURL: nil
            )
          }
        }
        // Then: upgrade with enricher cache (full profiles with avatars)
        for (canonical, profile) in enricherProfiles {
          if participantProfiles[canonical] == nil
            || participantProfiles[canonical]?.avatarURL == nil
          {
            participantProfiles[canonical] = profile
          }
        }
      }
      let seededCount = enricherProfiles.count
      let memberSeeded = memberModels.filter { $0.handle != nil || $0.displayName != nil }.count
      logger.debug(
        "🔍 [PHASE 0] Seeded profiles: \(memberSeeded) from DB, \(seededCount) from enricher cache"
      )
    } catch {
      logger.debug("🔍 [PHASE 0] Could not seed profiles: \(error.localizedDescription)")
    }

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
        // doesn't include that field. Control/commit payloads are stored but skipped
        // below because we only display .text messages.

        guard let payload = model.parsedPayload, !model.payloadExpired else {
          // Skip messages without payload or with expired payload
          // This includes messages that failed to decrypt due to forward secrecy
          logger.debug(
            "Skipping message \(model.messageID): no payload or expired (forward secrecy or expired)"
          )
          continue
        }

        // Check if it's a control message (reaction, read receipt, typing)
        guard payload.messageType == .text else {
          logger.debug(
            "Skipping control message \(model.messageID): type=\(payload.messageType.rawValue)"
          )
          continue
        }

        // SAFETY: Skip placeholder error messages that shouldn't be displayed
        // These are created when messages fail to decrypt (e.g., reactions, self-messages)
        let text = payload.text ?? ""
        let isPlaceholderError =
          model.processingError != nil
          && (text.isEmpty || text.contains("Message unavailable")
            || text.contains("Decryption Failed") || text.contains("Self-sent message"))
        if isPlaceholderError {
          logger.debug("Skipping placeholder error message: \(model.messageID)")
          continue
        }

        let isCurrentUser = isMessageFromCurrentUser(senderDID: model.senderID)

        let message = Message(
          id: model.messageID,
          user: makeUser(for: model.senderID, isCurrentUser: isCurrentUser),
          status: .sent,
          createdAt: model.timestamp,
          text: payload.text ?? ""
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
        if !cachedMessages.isEmpty {
          pipelineError = nil
        }
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
        guard let payload = model.parsedPayload, !model.payloadExpired else {
          logger.debug("Skipping older message \(model.messageID): no payload or expired")
          continue
        }

        // Check if it's a control message
        guard payload.messageType == .text else {
          logger.debug(
            "Skipping older control message \(model.messageID): type=\(payload.messageType.rawValue)"
          )
          continue
        }

        // SAFETY: Skip placeholder error messages (same as loadCachedMessages)
        let text = payload.text ?? ""
        let isPlaceholderError =
          model.processingError != nil
          && (text.isEmpty || text.contains("Message unavailable")
            || text.contains("Decryption Failed") || text.contains("Self-sent message"))
        if isPlaceholderError {
          logger.debug("Skipping placeholder error in pagination: \(model.messageID)")
          continue
        }

        let isCurrentUser = isMessageFromCurrentUser(senderDID: model.senderID)

        let message = Message(
          id: model.messageID,
          user: makeUser(for: model.senderID, isCurrentUser: isCurrentUser),
          status: .sent,
          createdAt: model.timestamp,
          text: payload.text ?? ""
        )

        olderMessages.append(message)
        orderUpdates[model.messageID] = MessageOrderKey(
          epoch: Int(model.epoch),
          sequence: Int(model.sequenceNumber),
          timestamp: model.timestamp
        )

        // Store embed in map if available
        if let embed = payload.embed {
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

      // Seed participantProfiles from DB-persisted member data immediately
      // so messages show names before the network fetch completes
      var dbProfiles: [String: MLSProfileEnricher.ProfileData] = [:]
      for member in fetchedMembers {
        if member.handle != nil || member.displayName != nil {
          dbProfiles[member.did] = MLSProfileEnricher.ProfileData(
            did: member.did,
            handle: member.handle ?? "",
            displayName: member.displayName,
            avatarURL: nil
          )
        }
      }

      await MainActor.run {
        members = fetchedMembers
        participantProfiles = participantProfiles.filter { dids.contains($0.key) }
        // Merge DB-cached profiles as initial values (won't overwrite existing)
        for (did, profile) in dbProfiles where participantProfiles[did] == nil {
          participantProfiles[did] = profile
        }
        // Rebuild messages immediately with DB-cached names
        if !dbProfiles.isEmpty {
          rebuildMessagesWithProfiles()
        }
      }

      // Seed the in-memory actor cache from DB data so subsequent lookups are fast
      await appState.mlsProfileEnricher.seedFromDatabase(Array(dbProfiles.values))

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
        using: client,
        currentUserDID: appState.userDID
      )

      await MainActor.run {
        mergeParticipantProfiles(with: profiles)

        // Pass profiles to unified data source so messages show names immediately
        unifiedDataSource?.preloadProfiles(profiles)
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
    // Rebuild messages to reflect newly loaded profile data
    rebuildMessagesWithProfiles()
  }

  /// Load cached reactions from SQLite for this conversation
  /// Called on conversation open to restore reactions from previous sessions
  /// Includes retry logic for transient database errors (SQLite OOM, busy, etc.)
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

    // CRITICAL FIX: First, try to adopt any orphaned reactions for this conversation
    // This handles the race condition where reactions arrived before their parent messages
    // were visible to the database (cross-process WAL visibility).
    await adoptOrphanedReactionsForConversation(
      conversationID: conversationId,
      currentUserDID: currentUserDID,
      database: database
    )

    // Retry up to 3 times for transient database errors
    let maxRetries = 3
    var lastError: Error?

    for attempt in 1...maxRetries {
      do {
        let cachedReactions = try await storage.fetchReactionsForConversation(
          conversationId,
          currentUserDID: currentUserDID,
          database: database
        )

        // Convert MLSReactionModel to MLSMessageReaction for UI
        await MainActor.run {
          // Get set of displayable message IDs for safety filter
          let displayableMessageIDs = Set(messages.map { $0.id })

          for (messageId, models) in cachedReactions {
            // SAFETY: Only display reactions for messages that are actually displayable
            // This filters out reactions for messages with processing errors or missing payloads
            guard displayableMessageIDs.contains(messageId) else {
              logger.debug(
                "⚠️ [REACTION-SAFETY] Skipping cached reactions for non-displayable message: \(messageId.prefix(16))"
              )
              continue
            }

            // De-dupe in case we replayed the same reaction event multiple times across reconnects.
            var seen = Set<String>()
            let mlsReactions = models.compactMap { model -> MLSMessageReaction? in
              let key = "\(model.actorDID)|\(model.emoji)"
              guard seen.insert(key).inserted else { return nil }
              return MLSMessageReaction(
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
        return  // Success - exit the retry loop

      } catch {
        lastError = error
        let errorDesc = error.localizedDescription

        // Check if this is a retryable SQLite error (OOM, busy, locked)
        let isRetryable =
          errorDesc.contains("out of memory") || errorDesc.contains("database is locked")
          || errorDesc.contains("busy") || errorDesc.contains("SQLITE_BUSY")
          || errorDesc.contains("error 7") || errorDesc.contains("error 5")
          || errorDesc.contains("error 6")

        if isRetryable && attempt < maxRetries {
          logger.warning(
            "⚠️ Transient DB error loading reactions (attempt \(attempt)/\(maxRetries)): \(errorDesc)"
          )
          // Exponential backoff: 100ms, 200ms, 400ms
          let delayMs = UInt64(100 * (1 << (attempt - 1)))
          try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
          continue
        }

        // Non-retryable or exhausted retries
        logger.error("Failed to load cached reactions after \(attempt) attempt(s): \(errorDesc)")
        break
      }
    }

    // If we get here, all retries failed - schedule a delayed retry
    if lastError != nil {
      logger.info("📋 Scheduling delayed reaction reload in 2 seconds...")
      Task {
        try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds
        await loadCachedReactionsDelayed()
      }
    }
  }

  /// Delayed reload of reactions after initial failure
  /// This gives the database time to recover from transient issues
  private func loadCachedReactionsDelayed() async {
    guard
      let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID,
      let database = appState.mlsDatabase
    else {
      return
    }

    do {
      let cachedReactions = try await storage.fetchReactionsForConversation(
        conversationId,
        currentUserDID: currentUserDID,
        database: database
      )

      await MainActor.run {
        for (messageId, models) in cachedReactions {
          var seen = Set<String>()
          let mlsReactions = models.compactMap { model -> MLSMessageReaction? in
            let key = "\(model.actorDID)|\(model.emoji)"
            guard seen.insert(key).inserted else { return nil }
            return MLSMessageReaction(
              messageId: model.messageID,
              reaction: model.emoji,
              senderDID: model.actorDID,
              reactedAt: model.timestamp
            )
          }
          // Merge with existing reactions (don't overwrite)
          if messageReactionsMap[messageId] == nil {
            messageReactionsMap[messageId] = mlsReactions
          } else {
            // Merge new reactions with existing
            var existing = messageReactionsMap[messageId] ?? []
            let existingKeys = Set(existing.map { "\($0.senderDID)|\($0.reaction)" })
            for reaction in mlsReactions {
              let key = "\(reaction.senderDID)|\(reaction.reaction)"
              if !existingKeys.contains(key) {
                existing.append(reaction)
              }
            }
            messageReactionsMap[messageId] = existing
          }
        }
      }

      logger.info(
        "✅ Delayed reload: Loaded \(cachedReactions.values.flatMap { $0 }.count) cached reactions"
      )
    } catch {
      logger.error("Delayed reaction reload also failed: \(error.localizedDescription)")
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
      // Retry logic for transient database errors
      var lastError: Error?
      for attempt in 1...3 {
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
          return  // Success
        } catch {
          lastError = error
          let desc = error.localizedDescription
          // Check for retryable SQLite errors
          if (desc.contains("out of memory") || desc.contains("busy") || desc.contains("locked")
            || desc.contains("error 7") || desc.contains("error 5") || desc.contains("error 6"))
            && attempt < 3
          {
            logger.warning("⚠️ Transient error persisting reaction (attempt \(attempt)): \(desc)")
            try? await Task.sleep(nanoseconds: UInt64(100 * attempt) * 1_000_000)
            continue
          }
          break
        }
      }
      if let error = lastError {
        logger.error("Failed to persist reaction after retries: \(error.localizedDescription)")
      }
    }
  }

  /// Adopt orphaned reactions for this conversation
  /// This handles the race condition where reactions arrived before their parent messages
  private func adoptOrphanedReactionsForConversation(
    conversationID: String,
    currentUserDID: String,
    database: CatbirdMLSCore.MLSDatabase
  ) async {
    do {
      // Get orphan stats for this conversation
      let orphanStats = try await storage.fetchOrphanedReactionStats(
        for: conversationID,
        currentUserDID: currentUserDID,
        limit: 50,
        database: database
      )

      guard !orphanStats.isEmpty else { return }

      logger.info(
        "[ORPHAN-UI] Found \(orphanStats.count) orphaned parent messages in conversation - attempting adoption"
      )

      var totalAdopted = 0
      for (messageID, count) in orphanStats {
        // Check if parent message now exists
        if (try? await storage.fetchMessage(
          messageID: messageID,
          currentUserDID: currentUserDID,
          database: database
        )) != nil {
          // Parent exists, adopt orphans
          let adopted = try await storage.adoptOrphansForMessage(
            messageID,
            currentUserDID: currentUserDID,
            database: database
          )

          // Add adopted reactions to the UI map
          for reaction in adopted {
            let mlsReaction = MLSMessageReaction(
              messageId: reaction.messageID,
              reaction: reaction.emoji,
              senderDID: reaction.actorDID,
              reactedAt: Date()
            )

            await MainActor.run {
              var reactions = messageReactionsMap[reaction.messageID] ?? []
              // Check for duplicate
              let key = "\(reaction.actorDID)|\(reaction.emoji)"
              let existingKeys = Set(reactions.map { "\($0.senderDID)|\($0.reaction)" })
              if !existingKeys.contains(key) {
                reactions.append(mlsReaction)
                messageReactionsMap[reaction.messageID] = reactions
              }
            }

            totalAdopted += 1
          }

          logger.info(
            "[ORPHAN-UI] Adopted \(adopted.count) orphan(s) for message \(messageID.prefix(16))")
        }
      }

      if totalAdopted > 0 {
        logger.info("[ORPHAN-UI] Total adopted \(totalAdopted) orphaned reactions for conversation")
      }
    } catch {
      logger.error("[ORPHAN-UI] Failed to adopt orphans: \(error.localizedDescription)")
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

      let profiles = await appState.mlsProfileEnricher.ensureProfiles(
        for: missing,
        using: client,
        currentUserDID: appState.userDID
      )
      await MainActor.run {
        mergeParticipantProfiles(with: profiles)
      }
    }
  }

  /// Mark all messages in this conversation as read
  private func markMessagesAsRead() async {
    logger.debug("📬 [READ_RECEIPTS] Marking messages as read for conversation \(conversationId)")

    var latestLocalCursor: (epoch: Int64, seq: Int64, messageID: String)?
    var didAdvanceFrontier = false

    // Mark messages as read in local database first
    if let database = appState.mlsDatabase {
      let currentUserDID = appState.userDID
      do {
        latestLocalCursor = try await storage.fetchLastDecryptedMessageCursor(
          conversationID: conversationId,
          currentUserDID: currentUserDID,
          database: database
        )

        let count = try await MLSStorageHelpers.markAllMessagesAsRead(
          in: database,
          conversationID: conversationId,
          currentUserDID: currentUserDID
        )

        if let latestLocalCursor {
          didAdvanceFrontier = try await storage.upsertReadFrontier(
            conversationID: conversationId,
            currentUserDID: currentUserDID,
            epoch: latestLocalCursor.epoch,
            sequenceNumber: latestLocalCursor.seq,
            database: database
          )
        }

        if count > 0 {
          logger.info("📬 [READ_RECEIPTS] Marked \(count) messages as read locally")
        }
        if count > 0 || didAdvanceFrontier {
          // Update AppState's MLS unread count
          await appState.updateMLSUnreadCount()
        }
      } catch {
        logger.error(
          "📬 [READ_RECEIPTS] Failed to mark messages as read locally: \(error.localizedDescription)"
        )
      }
    }

    guard let latestLocalCursor else {
      logger.debug(
        "📬 [READ_RECEIPTS] No decryptable/displayable message cursor available; skipping server read update"
      )
      return
    }

    // Also notify the server
    guard let apiClient = await appState.getMLSAPIClient() else {
      logger.warning(
        "📬 [READ_RECEIPTS] Cannot mark messages as read on server: API client not available")
      return
    }

    // TODO: apiClient.updateRead() not yet available in MLSAPIClient
    logger.debug("📬 [READ_RECEIPTS] Server read update not yet implemented (updateRead unavailable)")
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

        // Now save the payload (can't decrypt own messages in MLS, so we cache on send)
        do {
          let payload = CatbirdMLSCore.MLSMessagePayload.text(trimmed, embed: embed)
          try await storage.savePayloadForMessage(
            messageID: messageId,
            conversationID: conversationId,
            payload: payload,
            senderID: senderDID,  // ← Sender DID (who sent the message)
            currentUserDID: appState.userDID ?? senderDID,  // ← Current user's DID (owner of this storage context)
            epoch: epoch,  // ✅ Use real epoch from server
            sequenceNumber: seq,  // ✅ Use real sequence number from server
            timestamp: receivedAt.date,  // ✅ Use server timestamp
            database: database
          )
          logger.info(
            "✅ Saved payload under sender DID: \(senderDID) for message: \(messageId) with seq=\(seq), epoch=\(epoch)"
          )
        } catch {
          logger.error("Failed to save sent message payload: \(error.localizedDescription)")
        }
      } else {
        logger.error("Cannot save payload: database not available")
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

  // MARK: - Chat Request Actions
  
  /// Accept a pending chat request, moving it to the main inbox
  private func acceptChatRequest() async {
    guard let manager = await appState.getMLSConversationManager() else {
      logger.error("Cannot accept: no conversation manager")
      return
    }
    
    do {
      try await manager.acceptConversationRequest(convoId: conversationId)
      
      // Update local state
      await MainActor.run {
        if var model = conversationModel {
          conversationModel = model.withRequestState(.none)
        }
      }
      
      logger.info("✅ Accepted chat request: \(conversationId.prefix(16))...")
    } catch {
      logger.error("Failed to accept chat request: \(error.localizedDescription)")
      sendError = "Failed to accept: \(error.localizedDescription)"
      showingSendError = true
    }
  }
  
  /// Decline a pending chat request, leaving the conversation
  private func declineChatRequest() async {
    guard let manager = await appState.getMLSConversationManager() else {
      logger.error("Cannot decline: no conversation manager")
      return
    }
    
    do {
      try await manager.declineConversationRequest(convoId: conversationId)
      
      // Navigate back since the conversation is now deleted
      await MainActor.run {
        dismiss()
      }
      
      logger.info("❌ Declined chat request: \(conversationId.prefix(16))...")
    } catch {
      logger.error("Failed to decline chat request: \(error.localizedDescription)")
      sendError = "Failed to decline: \(error.localizedDescription)"
      showingSendError = true
    }
  }

  // MARK: - Real-Time Events

  private func startMessagePolling() {
    logger.info("📡 WS: startMessagePolling() called for convoId: \(conversationId)")

    Task {
      // Use centralized WebSocket manager from AppState
      logger.info("📡 WS: Getting WebSocket manager from AppState...")
      guard let wsManager = await appState.getMLSWebSocketManager() else {
        logger.error("📡 WS: Failed to get MLS WebSocket manager - ABORTING")
        return
      }
      logger.info("📡 WS: Got WebSocket manager, storing reference...")

      // Store reference for local cleanup
      await MainActor.run {
        webSocketManager = wsManager
      }

      logger.info("📡 WS: Calling subscribe() for convoId: \(conversationId)")

      // Subscribe to conversation events
      // CRITICAL FIX: Use proper @MainActor async closures that synchronously await handlers
      // Previous pattern used fire-and-forget Tasks which could be delayed by Swift's scheduler
      await wsManager.subscribe(
        to: conversationId,
        handler: MLSWebSocketManager.EventHandler(
          onMessage: { @MainActor messageEvent in
            self.logger.info(
              "📡 WS: onMessage handler called for message: \(messageEvent.message.id)")
            await self.handleNewMessage(messageEvent)
          },
          onReaction: { @MainActor reactionEvent in
            self.logger.info("📡 WS: onReaction handler called")
            await self.handleReaction(reactionEvent)
          },
          onTyping: { @MainActor typingEvent in
            self.logger.info("📡 WS: onTyping handler called")
            await self.handleTypingEvent(typingEvent)
          },
          onInfo: { @MainActor infoEvent in
            self.logger.info("📡 WS: onInfo handler called")
            await self.handleInfoEvent(infoEvent)
          },
          onNewDevice: { @MainActor newDeviceEvent in
            self.logger.info("📡 WS: onNewDevice handler called")
            await self.handleNewDeviceEvent(newDeviceEvent)
          },
          onGroupInfoRefreshRequested: { @MainActor refreshEvent in
            self.logger.info("📡 WS: onGroupInfoRefreshRequested handler called")
            await self.handleGroupInfoRefreshRequested(refreshEvent)
          },
          onReadditionRequested: { @MainActor readditionEvent in
            self.logger.info("📡 WS: onReadditionRequested handler called")
            await self.handleReadditionRequested(readditionEvent)
          },
          onMembershipChanged: { @MainActor convoId, did, action in
            self.logger.info("📡 WS: onMembershipChanged handler called")
            await self.handleMembershipChanged(convoId: convoId, did: did, action: action)
          },
          onKickedFromConversation: { @MainActor convoId, byDID, reason in
            self.logger.info("📡 WS: onKickedFromConversation handler called")
            await self.handleKickedFromConversation(convoId: convoId, byDID: byDID, reason: reason)
          },
          onConversationNeedsRecovery: nil,
          onError: { @MainActor error in
            self.logger.error("📡 WS: onError handler called: \(error.localizedDescription)")
          },
          onReconnected: { @MainActor [weak appState] in
            self.logger.info("📡 WS: onReconnected handler called - triggering catchup")
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
      logger.info("📡 WS: subscribe() returned for convoId: \(conversationId)")
    }
  }

  private func stopMessagePolling() {
    logger.debug("Stopping WebSocket subscription for conversation: \(conversationId)")
    // Stop subscription for this conversation
    // Note: Manager is owned by AppState and shared across views
    // We only stop the subscription for THIS conversation, not all subscriptions
    Task {
      await webSocketManager?.stop(conversationId)
    }
    hasStartedSubscription = false
    // Don't nil out webSocketManager - it's shared and owned by AppState
  }

  @MainActor
  private func handleNewMessage(_ event: BlueCatbirdMlsChatSubscribeEvents.MessageEvent) async {
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
      let result:
        (senderDID: String, displayText: String, embed: MLSEmbedData?, isControlMessage: Bool) =
          try await Task.detached(priority: .userInitiated) {
            if let storedSender = try? await storageRef.fetchSenderForMessage(
              messageId, currentUserDID: currentUserDID, database: database),
              let storedPlaintext = try? await storageRef.fetchPlaintextForMessage(
                messageId, currentUserDID: currentUserDID, database: database)
            {
              // Already decrypted and cached - parse to extract display text
              let embed = try? await storageRef.fetchEmbedForMessage(
                messageId, currentUserDID: currentUserDID, database: database)

              // Parse the plaintext to check if it's a control message
              if let parsed = MLSConversationDetailView.parseDisplayText(from: storedPlaintext) {
                return (storedSender, parsed.text, embed, parsed.isControlMessage)
              }
              return (storedSender, storedPlaintext, embed, false)
            } else {
              // Need to decrypt - this extracts sender from MLS credentials (heavy FFI work)
              let decryptedMessage = try await manager.decryptMessage(event.message, source: "sse")
              return (
                decryptedMessage.senderDID, decryptedMessage.text ?? "", decryptedMessage.embed,
                false
              )
            }
          }.value

      // Skip control messages (reactions, etc.) - they don't appear in message list
      if result.isControlMessage {
        // Check if this is a read receipt — process it before skipping
        if let data = result.displayText.data(using: .utf8),
          let payload = try? CatbirdMLSCore.MLSMessagePayload.decodeFromJSON(data),
          payload.messageType == .readReceipt,
          let readReceipt = payload.readReceipt
        {
          let senderDID = result.senderDID
          logger.info(
            "📬 [READ_RECEIPTS] Received read receipt from \(senderDID) for message \(readReceipt.messageId)"
          )
          await unifiedDataSource?.applyReadReceipt(
            readUpToMessageID: readReceipt.messageId,
            readerDID: senderDID
          )
        }
        logger.debug("Skipping SSE control message \(event.message.id)")
        return
      }

      let senderDID = result.senderDID
      let displayText = result.displayText
      let embed = result.embed

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

      if messageOrdering[newMessage.id] == nil {
        messageOrdering[newMessage.id] = MessageOrderKey(
          epoch: event.message.epoch,
          sequence: event.message.seq,
          timestamp: event.message.createdAt.date
        )
      }

      // Add to messages if not already present
      if !messages.contains(where: { $0.id == newMessage.id }) {
        messages.append(newMessage)
        logger.debug("🔍 MLS_OWNERSHIP: Added new message from SSE to UI")
      } else {
        logger.debug("🔍 MLS_OWNERSHIP: SSE message already in UI, skipping")
      }

      sortMessagesByMLSOrder()
      ensureProfileLoaded(for: senderDID)

      // Mark the message as read immediately since the user is actively viewing this conversation
      if !isCurrentUser, let database = appState.mlsDatabase {
        Task {
          do {
            try await database.write { db in
              try db.execute(
                sql: "UPDATE MLSMessageModel SET isRead = 1 WHERE messageID = ? AND currentUserDID = ? AND isRead = 0",
                arguments: [event.message.id, currentUserDID]
              )
            }
          } catch {
            logger.warning("Failed to mark incoming message as read: \(error.localizedDescription)")
          }
        }
      }

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
  private func handleReaction(_ event: BlueCatbirdMlsChatSubscribeEvents.ReactionEvent) async {
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
  private func handleTypingEvent(_ event: BlueCatbirdMlsChatSubscribeEvents.TypingEvent) async {
    unifiedDataSource?.applyTypingEvent(
      participantID: event.did.didString(),
      isTyping: event.isTyping
    )
  }

  // TODO: handleReadEvent is stubbed out — BlueCatbirdMlsChatSubscribeEvents.ReadEvent
  // and the onRead EventHandler callback are not yet available in the current SDK.
  // Re-enable when ReadEvent is added to CatbirdMLSCore.

  /// Handle new device events from SSE stream
  /// Forwards to MLSDeviceSyncManager for processing multi-device additions
  @MainActor
  private func handleNewDeviceEvent(_ event: BlueCatbirdMlsChatSubscribeEvents.NewDeviceEvent)
    async
  {
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
    _ event: BlueCatbirdMlsChatSubscribeEvents.InfoEvent
  ) async {
    guard let convoId = event.convoId else {
      logger.warning("⚠️ [GroupInfoRefresh] Missing convoId in InfoEvent")
      return
    }

    guard let requestedBy = event.requestedBy else {
      logger.warning("⚠️ [GroupInfoRefresh] Missing requestedBy in InfoEvent")
      return
    }

    logger.info(
      "🔄 [GroupInfoRefresh] Received request for convo \(convoId) from \(requestedBy)")

    // Get current user DID to check if this is our own request
    guard
      let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID
    else {
      logger.warning("⚠️ [GroupInfoRefresh] Cannot handle - userDID not available")
      return
    }

    // Don't respond to our own requests
    if requestedBy.didString().hasPrefix(currentUserDID)
      || currentUserDID.hasPrefix(requestedBy.didString())
    {
      logger.info("🔄 [GroupInfoRefresh] Ignoring own request")
      return
    }

    guard let manager = await appState.getMLSConversationManager() else {
      logger.warning("⚠️ [GroupInfoRefresh] Cannot handle - manager not available")
      return
    }

    // Forward to manager for processing (export GroupInfo and upload to server)
    await manager.handleGroupInfoRefreshRequest(convoId: convoId)
  }

  /// Handle re-addition request events from SSE stream
  /// When a member cannot rejoin (Welcome and External Commit both failed), they request
  /// active members to re-add them. If we're an active member, we re-add the user.
  @MainActor
  private func handleReadditionRequested(
    _ event: BlueCatbirdMlsChatSubscribeEvents.InfoEvent
  ) async {
    guard let convoId = event.convoId else {
      logger.warning("⚠️ [Readdition] Missing convoId in InfoEvent")
      return
    }

    guard let requestedBy = event.requestedBy else {
      logger.warning("⚠️ [Readdition] Missing requestedBy in InfoEvent")
      return
    }

    logger.info(
      "🆘 [Readdition] Received request for user \(requestedBy.didString().prefix(20))... in convo \(convoId)"
    )

    // Get current user DID to check if this is our own request
    guard
      let currentUserDID = appState.userDID ?? AppStateManager.shared.authentication.state.userDID
    else {
      logger.warning("⚠️ [Readdition] Cannot handle - userDID not available")
      return
    }

    // Don't respond to our own requests
    if requestedBy.didString().hasPrefix(currentUserDID)
      || currentUserDID.hasPrefix(requestedBy.didString())
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
      convoId: convoId, userDidToAdd: requestedBy.didString())
  }

  /// Handle info events from SSE stream
  @MainActor
  private func handleInfoEvent(_ event: BlueCatbirdMlsChatSubscribeEvents.InfoEvent) async {
    logger.info("ℹ️ [InfoEvent] Received for convo \(conversationId)")
    // Handle any informational events from the server
    // Currently a no-op, but can be extended for server-side announcements
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
      // MLS member reporting is disabled until moderation backend is implemented.
      // The report sheet would show an error anyway, but we skip it entirely for better UX.
      // TODO: Re-enable when MLS moderation infrastructure is ready.
      break
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

          // Clear any stacked navigation and notify list to clear selection
          appState.navigationManager.clearPath(for: 4)
          NotificationCenter.default.post(
            name: Notification.Name("MLSConversationLeft"),
            object: conversationId
          )
          dismiss()
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
    pipelineError = nil
    sendError = nil
    showingRecoveryError = false
    recoveryState = .inProgress

    guard let manager = await appState.getMLSConversationManager() else {
      logger.error("Recovery failed: MLS services unavailable")
      recoveryState = .failed("Secure rejoin is unavailable right now. Please restart the app and try again.")
      showingRecoveryError = true
      return
    }

    do {
      // Step 1: Join via External Commit (atomic rejoin)
      logger.debug("Joining via External Commit for recovery...")
      guard let userDid = manager.userDid else {
        logger.error("Recovery failed: No user DID available")
        recoveryState = .failed("Sign in is required to update your secure session.")
        showingRecoveryError = true
        return
      }

      // Use MLSClient to join via External Commit
      _ = try await manager.mlsClient.joinByExternalCommit(for: userDid, convoId: conversationId)

      logger.info("Successfully rejoined conversation via External Commit")

      // Step 2: Reload conversation and messages to confirm recovery
      logger.info("Rejoin accepted - verifying secure session state")
      await loadConversationAndMessages()

      if case .needed = recoveryState {
        recoveryState = .failed("Secure rejoin is still pending. Please try again in a moment.")
        showingRecoveryError = true
        return
      }

      if let pipelineError, !pipelineError.isEmpty {
        recoveryState = .failed(
          "We couldn't finish updating your secure session. Please try rejoining again.")
        showingRecoveryError = true
        return
      }

      if let sendError, !sendError.isEmpty {
        recoveryState = .failed(
          "We couldn't finish updating your secure session. Please try rejoining again.")
        showingRecoveryError = true
        return
      }

      // Step 3: Confirm success only after post-rejoin reload succeeds
      recoveryState = .success
      logger.info("Recovery confirmed - secure session restored")

      try? await Task.sleep(for: .seconds(2.5))
      if recoveryState == .success {
        recoveryState = .none
      }

    } catch {
      logger.error("Recovery failed: \(error.localizedDescription)")
      recoveryState = .failed(recoveryFailureMessage(for: error))
      showingRecoveryError = true
    }
  }

  private func recoveryFailureMessage(for error: Error) -> String {
    let normalizedError = error.localizedDescription.lowercased()

    if normalizedError.contains("network")
      || normalizedError.contains("timeout")
      || normalizedError.contains("timed out")
    {
      return "Network connection was interrupted while updating your secure session. Please try again."
    }

    if normalizedError.contains("auth")
      || normalizedError.contains("token")
      || normalizedError.contains("sign in")
    {
      return "Please sign in again to update your secure session."
    }

    return "We couldn't update your secure session yet. Your messages remain protected."
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
    if let key = messageOrdering[message.id] {
      return key
    }
    // Fallback: sort by timestamp with epoch/sequence 0
    // so unknown messages sort by time rather than being pushed to the end
    return MessageOrderKey(
      epoch: 0,
      sequence: 0,
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

  // MARK: - Plaintext Parsing Helpers

  /// Parse cached plaintext and extract display text for the message list.
  /// Parses JSON payloads to extract text content and detect control messages.
  /// - Returns: A tuple of (displayText, isControlMessage) or nil if parsing fails
  private static func parseDisplayText(from plaintext: String) -> (
    text: String, isControlMessage: Bool
  )? {
    // Check for legacy control message sentinel format
    // These are stored by cacheControlMessageEnvelope and should not be displayed
    if plaintext.hasPrefix("[control:") {
      return (plaintext, true)
    }

    // Try parsing as JSON payload
    if plaintext.hasPrefix("{"),
      let data = plaintext.data(using: .utf8),
      let payload = try? CatbirdMLSCore.MLSMessagePayload.decodeFromJSON(data)
    {

      switch payload.messageType {
      case .text:
        // Text messages are displayable
        return (payload.text ?? "New Message", false)
      case .reaction, .readReceipt, .typing:
        // Control messages should not be displayed in the message list
        return (plaintext, true)
      case .adminRoster, .adminAction:
        // Admin messages could be shown as system messages, but skip for now
        return (plaintext, true)
      case .system:
        // System messages (history boundary markers, etc.) are displayable
        return (payload.text ?? plaintext, false)
      }
    }

    // Plain text (non-JSON text messages)
    return (plaintext, false)
  }
}

// MARK: - Custom Message Menu Action

// MARK: - Preview

#Preview("Conversation Detail") {
  MLSConversationDetailPreview()
}

private struct MLSConversationDetailPreview: View {
  var body: some View {
    NavigationStack {
      Group {
        if let appState = AppStateManager.shared.lifecycle.appState {
          MLSConversationDetailView(conversationId: "preview-conversation-id")
            .environment(appState)
        } else {
          // Placeholder when no authenticated AppState is available
          VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
              .font(.system(size: 48))
              .foregroundColor(.green)

            Text("MLS Conversation Detail")
              .font(.headline)

            Text("End-to-End Encrypted Chat")
              .font(.subheadline)
              .foregroundColor(.secondary)

            Text("Sign in to preview this view")
              .font(.caption)
              .foregroundColor(.secondary)
              .padding(.top, 8)
          }
          .padding()
          .navigationTitle("Secure Chat")
        }
      }
    }
  }
}

// MARK: - Chat Request Action Bar

/// Action bar shown at the bottom of a conversation detail view when the conversation
/// is a pending inbound chat request that needs acceptance.
private struct ChatRequestActionBar: View {
  let conversationId: String
  let onAccept: () -> Void
  let onDecline: () -> Void
  
  @State private var isProcessing = false
  
  var body: some View {
    VStack(spacing: 0) {
      Divider()
      
      VStack(spacing: 12) {
        Text("This is a message request")
          .font(.subheadline)
          .foregroundColor(.secondary)
        
        Text("Accept to continue the conversation")
          .font(.caption)
          .foregroundColor(.secondary)
        
        HStack(spacing: 16) {
          Button(role: .destructive) {
            isProcessing = true
            onDecline()
          } label: {
            HStack {
              Image(systemName: "xmark")
              Text("Decline")
            }
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .disabled(isProcessing)
          
          Button {
            isProcessing = true
            onAccept()
          } label: {
            HStack {
              if isProcessing {
                ProgressView()
                  .tint(.white)
              } else {
                Image(systemName: "checkmark")
                Text("Accept")
              }
            }
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .disabled(isProcessing)
        }
      }
      .padding()
      .background(.ultraThinMaterial)
    }
  }
}

#endif
