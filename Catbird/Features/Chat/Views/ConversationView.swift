import SwiftUI
#if os(iOS)
import ExyteChat
#endif
import OSLog
import Petrel

// MARK: - Conversation View (Using ExyteChat)

#if os(iOS)
struct ConversationView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme
  let convoId: String

  // Get messages directly from ChatManager's map with defensive validation
  private var messages: [Message] {
    let rawMessages = appState.chatManager.messagesMap[convoId] ?? []

    // Filter out invalid messages that could crash ExyteChat
    var validMessages: [Message] = []
    var seenIds = Set<String>()

    for message in rawMessages {
      // Skip messages with invalid IDs
      guard !message.id.isEmpty else {
        logger.warning("Skipping message with empty ID")
        continue
      }

      // Skip duplicate message IDs
      guard !seenIds.contains(message.id) else {
        logger.warning("Skipping duplicate message ID: \(message.id)")
        continue
      }

      // Skip messages with invalid user data
      guard !message.user.id.isEmpty else {
        logger.warning("Skipping message with empty user ID: \(message.id)")
        continue
      }

      seenIds.insert(message.id)
      validMessages.append(message)
    }

    return validMessages
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
  
  // Post embed cache to avoid repeated fetches
  @State private var postEmbedCache: [String: AppBskyEmbedRecord.ViewRecordUnion] = [:]
  @State private var postEmbedLoadingStates: [String: Bool] = [:]

  // Access the specific ChatManager instance
  private var chatManager: ChatManager {
    appState.chatManager
  }
  
  private let logger = Logger(subsystem: "blue.catbird", category: "ConversationView")

  var body: some View {
    ZStack {  // Use ZStack to overlay loading indicator
      VStack(spacing: DesignTokens.Spacing.none) {  // Use VStack to prevent content overlap
        VStack(spacing: DesignTokens.Spacing.none) {
          ChatView<AnyView, EmptyView, CustomMessageMenuAction>(
            messages: messages,
            chatType: ChatType.conversation,
            replyMode: ReplyMode.answer,
            didSendMessage: { (draft: DraftMessage) in
              Task {
                await sendMessage(text: draft.text)
              }
            },
            reactionDelegate: BlueskyMessageReactionDelegate(
              chatManager: chatManager, convoId: convoId),
            messageBuilder: { (message: Message, positionInUserGroup: PositionInUserGroup, _, _, _, _, _) in
              AnyView(buildMessageView(message: message, positionInUserGroup: positionInUserGroup))
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
          // Restrict to text input only - Bluesky chat doesn't support file attachments
          .setAvailableInputs([AvailableInputType.text])
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
          .chatTheme(accentColor: Color.blue)
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
    .frame(maxWidth: 600)  
    .scrollDismissesKeyboard(.interactively)
    .navigationTitle(conversationTitle)
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
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
         !convoId.isEmpty,
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

    // Helper: Looks up the post record in cache or fetches it
    private func getPostRecord(for uri: String) -> AppBskyEmbedRecord.ViewRecordUnion? {
      let logger = Logger(subsystem: "blue.catbird", category: "ChatUI.PostEmbed")
      
      // Check cache first
      if let cachedRecord = postEmbedCache[uri] {
        return cachedRecord
      }
      
      // Check if we're already loading this URI
      if postEmbedLoadingStates[uri] == true {
        return nil // Will update when loaded
      }
      
      // Mark as loading
      postEmbedLoadingStates[uri] = true
      
      // Fetch the post record asynchronously
      Task {
        guard let client = appState.atProtoClient else {
          logger.error("Failed to fetch post record: AT Protocol client not available")
          postEmbedLoadingStates[uri] = false
          return
        }
        
        do {
          // Extract the AT URI components
          let atUri = try ATProtocolURI(uriString: uri)
          let did = atUri.authority
          
          guard let collection = atUri.collection,
                let rkey = atUri.recordKey else {
            logger.error("Invalid AT URI format - missing collection or record key: \(uri)")
            postEmbedLoadingStates[uri] = false
            return
          }
          
          // Fetch the post record from the repository
          let input = ComAtprotoRepoGetRecord.Parameters(
            repo: try ATIdentifier(string: did),
            collection: try NSID(nsidString: collection),
            rkey: try RecordKey(keyString: rkey),
            cid: nil
          )
          
          let (responseCode, response) = try await client.com.atproto.repo.getRecord(input: input)
          
          if responseCode == 200, let record = response?.value {
            // Also fetch the author profile for better display
            let (authorCode, authorData) = try await client.app.bsky.actor.getProfile(
              input: .init(actor: ATIdentifier(string: did))
            )
            
            if case .knownType(let recordValue) = record,
               let post = recordValue as? AppBskyFeedPost {
              // Create author with fetched profile data if available
              let author: AppBskyActorDefs.ProfileViewBasic
              if authorCode == 200, let profile = authorData {
                author = AppBskyActorDefs.ProfileViewBasic(
                  did: profile.did,
                  handle: profile.handle,
                  displayName: profile.displayName,
                  avatar: profile.avatar,
                  associated: profile.associated,
                  viewer: profile.viewer,
                  labels: profile.labels,
                  createdAt: profile.createdAt,
                  verification: profile.verification,
                  status: profile.status
                )
              } else {
                // Fallback author info
                author = AppBskyActorDefs.ProfileViewBasic(
                  did: try DID(didString: did),
                  handle: try Handle(handleString: ""), 
                  displayName: nil,
                  avatar: nil,
                  associated: nil,
                  viewer: nil,
                  labels: nil,
                  createdAt: post.createdAt,
                  verification: nil,
                  status: nil
                )
              }
              
              // Use the CID from the response, or create one from the post data
              let postCid: CID
              if let responseCid = response?.cid {
                postCid = responseCid
              } else {
                // Fallback: generate CID from the post data
                let postData = try post.encodedDAGCBOR()
                postCid = CID.fromDAGCBOR(postData)
              }
              
              let postView = AppBskyFeedDefs.PostView(
                uri: atUri,
                cid: postCid,
                author: author,
                record: ATProtocolValueContainer.knownType(post),
                embed: nil,   // Post embeds need to be converted to PostViewEmbedUnion
                bookmarkCount: nil,
                replyCount: 0,
                repostCount: 0,
                likeCount: 0,
                quoteCount: 0,
                indexedAt: ATProtocolDate(date: Date()),
                viewer: nil,
                labels: [],  // Labels need to be converted from post labels
                threadgate: nil
              )
              
              // Create a ViewRecord from the PostView
              let viewRecord = AppBskyEmbedRecord.ViewRecord(
                uri: postView.uri,
                cid: postView.cid,
                author: postView.author,
                value: postView.record,
                labels: postView.labels,
                replyCount: postView.replyCount,
                repostCount: postView.repostCount,
                likeCount: postView.likeCount,
                quoteCount: postView.quoteCount,
                embeds: nil,
                indexedAt: postView.indexedAt
              )
              
              let viewRecordUnion = AppBskyEmbedRecord.ViewRecordUnion.appBskyEmbedRecordViewRecord(viewRecord)
              
              // Cache the result
              await MainActor.run {
                postEmbedCache[uri] = viewRecordUnion
                postEmbedLoadingStates[uri] = false
              }
              
              return
            } else {
              logger.warning("Unsupported record type for embed: \(String(describing: record))")
              postEmbedLoadingStates[uri] = false
            }
          } else {
            logger.error("Failed to fetch post record: HTTP \(responseCode)")
            postEmbedLoadingStates[uri] = false
          }
        } catch {
          logger.error("Failed to fetch post record: \(error.localizedDescription), URI: \(uri)")
          postEmbedLoadingStates[uri] = false
        }
      }
      
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
  @ViewBuilder
  private func buildMessageView(message: Message, positionInUserGroup: PositionInUserGroup) -> some View {
    if convoId.isEmpty {
      createSimpleMessageView(message: message, positionInUserGroup: positionInUserGroup)
            .onAppear {
                logger.error("Conversation ID is empty - cannot load original messages")
                }
    } else {
      // Safely access the original messages map
      let convoMessages = chatManager.originalMessagesMap[convoId]
      let originalMessageView = convoMessages?[message.id]

      let record: AppBskyEmbedRecord.ViewRecordUnion? = {
        if case .appBskyEmbedRecordView(let recordView) = originalMessageView?.embed {
          return recordView.record
        }
        return nil
      }()

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
    }
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
        arrowSend: Image(systemName: "arrow.up")
        // Note: attachment-related images removed since attachments are disabled
    )

    return ChatTheme(colors: colors, images: images)
  }

  // Helper to create a simple message view without embeds as fallback
  @ViewBuilder
  private func createSimpleMessageView(message: Message, positionInUserGroup: PositionInUserGroup) -> some View {
    VStack(alignment: message.user.isCurrentUser ? .trailing : .leading, spacing: 2) {
      MessageBubble(message: message, embed: nil, position: positionInUserGroup, path: chatNavigationPath)
        .padding(1)
    }
  }
  
  // Helper to find the original MessageView for a given message ID
  private func getOriginalMessageForId(messageId: String) -> ChatBskyConvoDefs.MessageView? {
    guard !convoId.isEmpty else { return nil }
    return chatManager.originalMessagesMap[convoId]?[messageId]
  }
}

#else

// macOS stub for ConversationView
struct ConversationView: View {
  let convoId: String
  
  var body: some View {
    VStack {
      Text("Chat functionality is not available on macOS")
        .foregroundColor(.secondary)
      Text("Chat features require iOS")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .padding()
  }
}

#endif
