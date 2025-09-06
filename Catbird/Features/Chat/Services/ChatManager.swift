#if os(iOS)
import ExyteChat
import UIKit
#endif
import Foundation
import OSLog
import Petrel
import SwiftUI

/// Data structure for post embeds in chat messages
struct PostEmbedData: Codable {
  let postView: AppBskyFeedDefs.PostView
  let authorHandle: String
  let displayText: String
}

#if os(iOS)
/// Manages chat operations for the Bluesky chat feature
@Observable
final class ChatManager: StateInvalidationSubscriber {
  private let logger = Logger(subsystem: "blue.catbird", category: "ChatManager")

  // AT Protocol client reference
  private(set) var client: ATProtoClient?  // Made private(set) for controlled access

  // Conversations and messages
  var conversations: [ChatBskyConvoDefs.ConvoView] = []
  private(set) var messagesMap: [String: [Message]] = [:]
  // Store original message views for reactions and other advanced features
  private(set) var originalMessagesMap: [String: [String: ChatBskyConvoDefs.MessageView]] = [:]  // [convoId: [messageId: MessageView]]
  private(set) var loadingConversations: Bool = false
  private(set) var loadingMessages: [String: Bool] = [:]
  var errorState: ChatError?

  // Search-related state
  private(set) var filteredConversations: [ChatBskyConvoDefs.ConvoView] = []
  private(set) var filteredProfiles: [ChatBskyActorDefs.ProfileViewBasic] = []
  
  // Message requests state
  private(set) var messageRequests: [ChatBskyConvoDefs.ConvoView] = []
  private(set) var acceptedConversations: [ChatBskyConvoDefs.ConvoView] = []

  // Profile caching
  private var profileCache: [String: AppBskyActorDefs.ProfileViewDetailed] = [:]
  
  // Message delivery tracking
  private var pendingMessages: [String: PendingMessage] = [:]  // [tempId: PendingMessage]
  private var messageDeliveryStatus: [String: MessageDeliveryStatus] = [:]  // [messageId: status]

  // Pagination control
  var conversationsCursor: String?
  private var messagesCursors: [String: String?] = [:]
  
  // Polling control
  private var conversationsPollingTask: Task<Void, Never>?
  private var messagePollingTasks: [String: Task<Void, Never>] = [:]
  private var isAppActive = true
  
  // Polling intervals (in seconds) - optimized for better real-time experience
  private let activeConversationPollInterval: TimeInterval = 1.5  // 1.5 seconds when viewing a conversation (faster)
  private let activeListPollInterval: TimeInterval = 10.0  // 10 seconds when viewing conversation list (faster)
  private let backgroundPollInterval: TimeInterval = 60.0  // 1 minute when backgrounded (more responsive)
  private let inactivePollInterval: TimeInterval = 180.0  // 3 minutes when inactive (reduced)
  
  // Callback for when unread count changes
  var onUnreadCountChanged: (() -> Void)?

  init(client: ATProtoClient? = nil, appState: AppState? = nil) {
    self.client = client
    logger.debug("ChatManager initialized")
    setupNotificationObservers()
    
    // Subscribe to state invalidation events if appState is provided
    if let appState = appState {
      appState.stateInvalidationBus.subscribe(self)
    }
  }

  // MARK: - Lifecycle Management
  
  deinit {
    stopAllPolling()
  }
  
  private func setupNotificationObservers() {
    #if os(iOS)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
    
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    #elseif os(macOS)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidBecomeActive),
      name: NSApplication.didBecomeActiveNotification,
      object: nil
    )
    
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidEnterBackground),
      name: NSApplication.didResignActiveNotification,
      object: nil
    )
    #endif
  }
  
  @objc private func appDidBecomeActive() {
    isAppActive = true
    logger.debug("App became active, adjusting polling intervals")
  }
  
  @objc private func appDidEnterBackground() {
    isAppActive = false
    logger.debug("App entered background, adjusting polling intervals")
  }

  // Update client when auth changes
  func updateClient(_ client: ATProtoClient?) async {
    self.client = client
    logger.debug("ChatManager client updated")

    let currentClientDid = try? await client?.getDid()
    // Clear existing data when client changes (e.g., logout or account switch)
    if client == nil || currentClientDid != currentClientDid {
      stopAllPolling()
      conversations = []
      messagesMap = [:]
      originalMessagesMap = [:]
      conversationsCursor = nil
      messagesCursors = [:]
      loadingConversations = false
      loadingMessages = [:]
      errorState = nil
      profileCache = [:]  // Clear profile cache on client change
      filteredConversations = []
      filteredProfiles = []
      messageRequests = []
      acceptedConversations = []
      logger.debug("Chat data cleared due to client change.")
    } else if client != nil {
      // Start polling for the new client
      startConversationsPolling()
    }
  }
  
  /// Update app state reference and subscribe to state invalidation events
  func updateAppState(_ appState: AppState?) {
    if let appState = appState {
      appState.stateInvalidationBus.subscribe(self)
      logger.debug("ChatManager subscribed to state invalidation bus")
    }
  }
  
  // MARK: - State Invalidation Handling
  
  /// Check if ChatManager is interested in a specific state invalidation event
  func isInterestedIn(_ event: StateInvalidationEvent) -> Bool {
    switch event {
    case .accountSwitched, .chatMessageReceived:
      return true
    default:
      return false // ChatManager only cares about account switches and chat messages
    }
  }
  
  /// Handle state invalidation events from the central event bus
  func handleStateInvalidation(_ event: StateInvalidationEvent) async {
    logger.debug("Chat handling state invalidation event: \(String(describing: event))")
    
    switch event {
    case .accountSwitched:
      // Account switching should clear and reload chat data
      await MainActor.run {
        logger.info("Account switched - clearing chat data and reloading")
        clearChatData()
        
        // Reload conversations if we have a client
        if client != nil {
          Task {
            await loadConversations(refresh: true)
          }
        }
      }
      
    case .chatMessageReceived:
      // New message received - refresh conversations to update unread counts
      await MainActor.run {
        if client != nil {
          Task {
            await loadConversations(refresh: true)
          }
        }
      }
      
    case .authenticationCompleted:
      // Authentication completed - reload conversations if needed
      await MainActor.run {
        if client != nil {
          Task {
            await loadConversations(refresh: true)
          }
        }
      }
      
    case .postCreated, .replyCreated, .threadUpdated:
      // These don't affect chat content
      break
      
    case .feedUpdated, .profileUpdated, .notificationsUpdated:
      // These don't affect chat content
      break
      
    case .postLiked, .postUnliked, .postReposted, .postUnreposted:
      // These don't affect chat content
      break
    case .feedListChanged:
      // Feed list changes don't affect chat content
      break
    }
  }
  
  /// Clear all chat data (called during account switching)
  private func clearChatData() {
    stopAllPolling()
    conversations = []
    messagesMap = [:]
    originalMessagesMap = [:]
    conversationsCursor = nil
    messagesCursors = [:]
    loadingConversations = false
    loadingMessages = [:]
    errorState = nil
    profileCache = [:]
    filteredConversations = []
    filteredProfiles = []
    messageRequests = []
    acceptedConversations = []
    logger.debug("Chat data cleared")
  }

  // MARK: - Conversation Loading

  @MainActor
  func loadConversations(refresh: Bool = false) async {
    guard let client = client else {
      logger.error("Cannot load conversations: client is nil")
      errorState = .noClient
      return
    }

    // Skip if already loading
    if loadingConversations {
      logger.debug("Already loading conversations, skipping.")
      return
    }
    
    // Skip if user is currently authenticating to reduce noise during login flow
    let authState = AppState.shared.authManager.state
    if case .authenticating = authState {
      logger.debug("Skipping conversation loading while user is authenticating")
      return
    }

    // If refreshing, cancel any ongoing load? (Consider Task management if needed)

    do {
      loadingConversations = true
      errorState = nil

      // Reset cursor if refreshing
      let cursorToUse = refresh ? nil : conversationsCursor

      let params = ChatBskyConvoListConvos.Parameters(
        limit: 20,  // Consider making limit configurable or dynamic
        cursor: cursorToUse
      )

      logger.debug("Loading conversations with cursor: \(cursorToUse ?? "nil")")
         let (responseCode, response) = try await client.chat.bsky.convo.listConvos(input: params)
 
      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Error loading conversations: HTTP \(responseCode)")
        errorState = .networkError(code: responseCode)
        loadingConversations = false
        return
      }

      guard let convosData = response else {
        logger.error("No data returned from conversations request")
        errorState = .emptyResponse
        loadingConversations = false
        return
      }

      // Update state
      if refresh {
        conversations = convosData.convos
      } else {
        // Avoid duplicates if loading more
        let existingIDs = Set(conversations.map { $0.id })
        let newConvos = convosData.convos.filter { !existingIDs.contains($0.id) }
        conversations.append(contentsOf: newConvos)
      }

      conversationsCursor = convosData.cursor
      
      // Update filtered lists based on status
      updateConversationsByStatus()

      logger.debug(
        "Loaded \(convosData.convos.count) conversations. New cursor: \(convosData.cursor ?? "nil")"
      )
      
      // Notify that unread count may have changed
      onUnreadCountChanged?()

    } catch {
      logger.error("Error loading conversations: \(error.localizedDescription)")
      setErrorState(error)
    }

    loadingConversations = false
  }

  // MARK: - Messages Loading

  @MainActor
  func loadMessages(convoId: String, refresh: Bool = false) async {
    guard let client = client else {
      logger.error("Cannot load messages for \(convoId): client is nil")
      errorState = .noClient
      return
    }

    // Skip if already loading this conversation
    if loadingMessages[convoId] == true {
      logger.debug("Already loading messages for \(convoId), skipping.")
      return
    }

    do {
      loadingMessages[convoId] = true
      errorState = nil

      // Reset cursor if refreshing
      let cursorToUse: String? = refresh ? nil : (messagesCursors[convoId] ?? nil)

      let params = ChatBskyConvoGetMessages.Parameters(
        convoId: convoId,
        limit: 30,  // Consider making limit configurable
        cursor: cursorToUse
      )

      logger.debug("Loading messages for \(convoId) with cursor: \(cursorToUse ?? "nil")")
   
      let (responseCode, response) = try await client.chat.bsky.convo.getMessages(input: params)
 
      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Error loading messages for \(convoId): HTTP \(responseCode)")
        errorState = .networkError(code: responseCode)
        loadingMessages[convoId] = false
        return
      }

      guard let messagesData = response else {
        logger.error("No data returned from messages request for \(convoId)")
        errorState = .emptyResponse
        loadingMessages[convoId] = false
        return
      }

      // Convert messages sequentially since we need to use async functions
      var chatMessages: [Message] = []
      var originalMessages: [String: ChatBskyConvoDefs.MessageView] = [:]
      for messageUnion in messagesData.messages {
        switch messageUnion {
        case .chatBskyConvoDefsMessageView(let messageView):
          // Ensure we have a client session to determine 'isCurrentUser'
          let message = await createChatMessage(from: messageView)
          chatMessages.append(message)
          originalMessages[messageView.id] = messageView
        case .chatBskyConvoDefsDeletedMessageView:
          // Represent deleted messages differently if needed, or filter out
          continue  // Skip deleted messages for now
        case .unexpected(let data):
          logger.warning(
            "Unexpected message type encountered in \(convoId): \(String(describing: data))")
          continue
        }
      }

      // Update state
      if refresh {
        messagesMap[convoId] = chatMessages.reversed()  // Reverse to show newest at bottom
        originalMessagesMap[convoId] = originalMessages
      } else if var existing = messagesMap[convoId] {
        // Avoid duplicates when loading older messages
        let existingIDs = Set(existing.map { $0.id })
        let newMessages = chatMessages.filter { !existingIDs.contains($0.id) }
        existing.insert(contentsOf: newMessages.reversed(), at: 0)  // Insert older messages at the beginning
        messagesMap[convoId] = existing

        if var existingOriginals = originalMessagesMap[convoId] {
          for (id, messageView) in originalMessages {
            existingOriginals[id] = messageView
          }
          originalMessagesMap[convoId] = existingOriginals
        } else {
          originalMessagesMap[convoId] = originalMessages
        }
      } else {
        messagesMap[convoId] = chatMessages.reversed()  // Reverse initial load
        originalMessagesMap[convoId] = originalMessages
      }

      messagesCursors[convoId] = messagesData.cursor

      logger.debug(
        "Loaded \(chatMessages.count) messages for conversation \(convoId). New cursor: \(messagesData.cursor ?? "nil")"
      )

      // Mark conversation as read only after successfully loading messages
      await markConversationAsRead(convoId: convoId)

    } catch {
      logger.error("Error loading messages for \(convoId): \(error.localizedDescription)")
      setErrorState(error)
    }

    loadingMessages[convoId] = false
  }

  @MainActor
  func leaveConversation(convoId: String) async {
    guard let client = client else {
      logger.error("Cannot leave conversation \(convoId): client is nil")
      errorState = .noClient
      return
    }

    // Implement leave functionality here
    // 1. Create ChatBskyConvoLeave.Input
    // 2. Call client.chat.bsky.convo.leave
    // 3. Check responseCode
    // 4. If success, remove conversation from local state
    let leaveInput = ChatBskyConvoLeaveConvo.Input(convoId: convoId)
     do {
      let (responseCode, _) = try await client.chat.bsky.convo.leaveConvo(input: leaveInput)
 
      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Error leaving conversation \(convoId): HTTP \(responseCode)")
        errorState = .networkError(code: responseCode)
        return
      }

      // Remove conversation from local state
      if let index = conversations.firstIndex(where: { $0.id == convoId }) {
        conversations.remove(at: index)
        messagesMap[convoId] = nil  // Clear messages for this convo
        originalMessagesMap[convoId] = nil  // Clear original messages for this convo
        logger.debug("Left conversation \(convoId) successfully.")
      }

    } catch {
      logger.error("Error leaving conversation \(convoId): \(error.localizedDescription)")
      setErrorState(error)
    }
  }

  @MainActor
  func muteConversation(convoId: String) async {
    guard let client = client else {
      logger.error("Cannot mute conversation: client is nil")
      errorState = .noClient
      return
    }

    // Implement mute functionality here
    // 1. Create ChatBskyConvoMute.Input
    // 2. Call client.chat.bsky.convo.mute
    // 3. Check responseCode
    // 4. If success, update local state (e.g., mark conversation as muted)
    let muteInput = ChatBskyConvoMuteConvo.Input(convoId: convoId)
     do {
      let (responseCode, _) = try await client.chat.bsky.convo.muteConvo(input: muteInput)
 
      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Error muting conversation \(convoId): HTTP \(responseCode)")
        errorState = .networkError(code: responseCode)
        return
      }

      // Update local state
      if conversations.firstIndex(where: { $0.id == convoId }) != nil {
        //                conversations[index].muted = true // Assuming ConvoView has an isMuted property
        await self.loadMessages(convoId: convoId, refresh: true)  // Reload messages to reflect mute state
        logger.debug("Conversation \(convoId) muted successfully.")
      }

    } catch {
      logger.error("Error muting conversation \(convoId): \(error.localizedDescription)")
      setErrorState(error)
    }
  }

  @MainActor
  func unmuteConversation(convoId: String) async {
    guard let client = client else {
      logger.error("Cannot unmute conversation: client is nil")
      errorState = .noClient
      return
    }

    let unmuteInput = ChatBskyConvoUnmuteConvo.Input(convoId: convoId)
     do {
      let (responseCode, _) = try await client.chat.bsky.convo.unmuteConvo(input: unmuteInput)
 
      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Error unmuting conversation \(convoId): HTTP \(responseCode)")
        errorState = .networkError(code: responseCode)
        return
      }

      // Update local state
      if conversations.firstIndex(where: { $0.id == convoId }) != nil {
        await self.loadMessages(convoId: convoId, refresh: true)
        logger.debug("Conversation \(convoId) unmuted successfully.")
      }

    } catch {
      logger.error("Error unmuting conversation \(convoId): \(error.localizedDescription)")
      setErrorState(error)
    }
  }

  @MainActor
  func acceptConversation(convoId: String) async -> Bool {
    guard let client = client else {
      logger.error("Cannot accept conversation: client is nil")
      errorState = .noClient
      return false
    }

    let acceptInput = ChatBskyConvoAcceptConvo.Input(convoId: convoId)
     do {
      let (responseCode, _) = try await client.chat.bsky.convo.acceptConvo(input: acceptInput)
 
      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Error accepting conversation \(convoId): HTTP \(responseCode)")
        errorState = .networkError(code: responseCode)
        return false
      }

      logger.debug("Conversation \(convoId) accepted successfully.")
      // Refresh conversation list to reflect acceptance
      await loadConversations(refresh: true)
      return true

    } catch {
      logger.error("Error accepting conversation \(convoId): \(error.localizedDescription)")
      setErrorState(error)
      return false
    }
  }

  @MainActor
  func getConversation(convoId: String) async -> ChatBskyConvoDefs.ConvoView? {
    guard let client = client else {
      logger.error("Cannot get conversation: client is nil")
      errorState = .noClient
      return nil
    }

    let params = ChatBskyConvoGetConvo.Parameters(convoId: convoId)
     do {
      let (responseCode, response) = try await client.chat.bsky.convo.getConvo(input: params)
 
      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Error getting conversation \(convoId): HTTP \(responseCode)")
        errorState = .networkError(code: responseCode)
        return nil
      }

      guard let convoData = response else {
        logger.error("No data returned from get conversation request")
        errorState = .emptyResponse
        return nil
      }

      logger.debug("Successfully retrieved conversation \(convoId)")
      return convoData.convo

    } catch {
      logger.error("Error getting conversation \(convoId): \(error.localizedDescription)")
      setErrorState(error)
      return nil
    }
  }

  @MainActor
  func checkConversationAvailability(members: [String]) async -> (canChat: Bool, existingConvo: ChatBskyConvoDefs.ConvoView?) {
    guard let client = client else {
      logger.error("Cannot check conversation availability: client is nil")
      errorState = .noClient
      return (false, nil)
    }

    do {
      let memberDIDs = try members.map { try DID(didString: $0) }
      let params = ChatBskyConvoGetConvoAvailability.Parameters(members: memberDIDs)
         
      let (responseCode, response) = try await client.chat.bsky.convo.getConvoAvailability(input: params)
 
      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Error checking conversation availability: HTTP \(responseCode)")
        errorState = .networkError(code: responseCode)
        return (false, nil)
      }

      guard let availability = response else {
        logger.error("No data returned from conversation availability request")
        errorState = .emptyResponse
        return (false, nil)
      }

      logger.debug("Conversation availability check completed. Can chat: \(availability.canChat)")
      return (availability.canChat, availability.convo)

    } catch {
      logger.error("Error checking conversation availability: \(error.localizedDescription)")
      setErrorState(error)
      return (false, nil)
    }
  }

  // MARK: - Message Actions

  @MainActor
  func sendMessage(convoId: String, text: String) async -> Bool {
    return await sendMessage(convoId: convoId, text: text, embed: nil)
  }
  
  /// Send a message with optional embed (for sharing posts)
  func sendMessage(convoId: String, text: String, embed: ChatBskyConvoDefs.MessageInputEmbedUnion?) async -> Bool {
    guard let client = client else {
      logger.error("Cannot send message to \(convoId): client or session is nil")
      errorState = .noClient
      return false
    }

    // Basic validation
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      logger.warning("Attempted to send empty message to \(convoId)")
      return false
    }

    // Note: ExyteChat handles optimistic UI updates, so we don't create them here
    // This prevents message duplication where both ExyteChat and ChatManager create optimistic messages

    do {
      let messageInput = ChatBskyConvoDefs.MessageInput(
        text: text,
        facets: nil,  // Placeholder for rich text facets
        embed: embed
      )

      let input = ChatBskyConvoSendMessage.Input(
        convoId: convoId,
        message: messageInput
      )

      logger.debug("Sending message to conversation \(convoId)\(embed != nil ? " with embed" : "")")
   
      let (responseCode, response) = try await client.chat.bsky.convo.sendMessage(input: input)
 
      guard responseCode >= 200 && responseCode < 300, let messageView = response else {
        logger.error("Error sending message to \(convoId): HTTP \(responseCode)")
        errorState = .networkError(code: responseCode)
        return false
      }

      // Add the real message to our local state (ExyteChat handles optimistic UI)
      let realMessage = await createChatMessage(from: messageView)
      
      if var existing = messagesMap[convoId] {
        existing.append(realMessage)
        messagesMap[convoId] = existing
      } else {
        messagesMap[convoId] = [realMessage]
      }

      // Store original message view for reactions and other features
      if var existingOriginals = originalMessagesMap[convoId] {
        existingOriginals[messageView.id] = messageView
        originalMessagesMap[convoId] = existingOriginals
      } else {
        originalMessagesMap[convoId] = [messageView.id: messageView]
      }

      // Update conversation list's last message preview
      await updateConversationLastMessage(convoId: convoId, messageView: messageView)

      logger.debug("Message sent successfully to conversation \(convoId)")
      return true

    } catch {
      logger.error("Error sending message to \(convoId): \(error.localizedDescription)")
      setErrorState(error)
      return false
    }
  }

  @MainActor
  func markConversationAsRead(convoId: String) async {
    guard let client = client else {
      logger.debug("Cannot mark conversation \(convoId) as read: client is nil")
      return
    }

    // Only mark as read if there are unread messages locally
    guard let convoIndex = conversations.firstIndex(where: { $0.id == convoId }),
      conversations[convoIndex].unreadCount > 0
    else {
      // logger.debug("Conversation \(convoId) already marked as read locally or not found.")
      return
    }

    do {
      let input = ChatBskyConvoUpdateRead.Input(convoId: convoId, messageId: nil)  // messageId is optional
      logger.debug("Marking conversation \(convoId) as read")
   
      let (responseCode, response) = try await client.chat.bsky.convo.updateRead(input: input)
 
      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Error marking conversation \(convoId) as read: HTTP \(responseCode)")
        // Don't update local state if API call failed
        return
      }

      // Update local conversation read state immediately on success
      if let updatedConvoView = response?.convo {
        if let index = conversations.firstIndex(where: { $0.id == updatedConvoView.id }) {
          conversations[index] = updatedConvoView
          logger.debug(
            "Successfully marked conversation \(convoId) as read and updated local state.")
          // Notify that unread count has changed
          onUnreadCountChanged?()
        }
      } else {
        // Fallback if response doesn't contain the updated convo view
        if conversations.firstIndex(where: { $0.id == convoId }) != nil {
          // Manually create a modified version or wait for next refresh
          // For simplicity, let's assume the next refresh will fix it,
          // but ideally, we'd update the unreadCount to 0 here.
          // conversations[index].unreadCount = 0 // This requires ConvoView to be mutable or recreated
          logger.debug(
            "Successfully marked conversation \(convoId) as read (API success, local state update pending refresh)."
          )
        }
      }

    } catch {
      logger.error("Error marking conversation \(convoId) as read: \(error.localizedDescription)")
      // Optionally set an error state specific to this action
    }
  }

  @MainActor
  func sendMessageBatch(items: [(convoId: String, text: String)]) async -> [String?] {
    guard let client = client else {
      logger.error("Cannot send message batch: client is nil")
      errorState = .noClient
      return Array(repeating: nil, count: items.count)
    }

    do {
      let batchItems = items.map { item in
        let messageInput = ChatBskyConvoDefs.MessageInput(
          text: item.text,
          facets: nil,
          embed: nil
        )
        return ChatBskyConvoSendMessageBatch.BatchItem(
          convoId: item.convoId,
          message: messageInput
        )
      }

      let input = ChatBskyConvoSendMessageBatch.Input(items: batchItems)

         let (responseCode, response) = try await client.chat.bsky.convo.sendMessageBatch(input: input)
 
      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Error sending message batch: HTTP \(responseCode)")
        errorState = .networkError(code: responseCode)
        return Array(repeating: nil, count: items.count)
      }

      guard let batchResponse = response else {
        logger.error("No response returned from message batch")
        errorState = .emptyResponse
        return Array(repeating: nil, count: items.count)
      }

      // Update local state for successful messages
      var results: [String?] = []
      for (index, messageResult) in batchResponse.items.enumerated() {
        // Access the MessageView directly since BatchItem contains the MessageView
        let newMessage = await createChatMessage(from: messageResult)
        let convoId = items[index].convoId
        
        if var existing = messagesMap[convoId] {
          existing.append(newMessage)
          messagesMap[convoId] = existing
        } else {
          messagesMap[convoId] = [newMessage]
        }

        if var existingOriginals = originalMessagesMap[convoId] {
          existingOriginals[messageResult.id] = messageResult
          originalMessagesMap[convoId] = existingOriginals
        } else {
          originalMessagesMap[convoId] = [messageResult.id: messageResult]
        }

        results.append(messageResult.id)
      }

      logger.debug("Message batch sent successfully")
      return results

    } catch {
      logger.error("Error sending message batch: \(error.localizedDescription)")
      setErrorState(error)
      return Array(repeating: nil, count: items.count)
    }
  }

  @MainActor
  func deleteMessageForSelf(convoId: String, messageId: String) async -> Bool {
    guard let client = client else {
      logger.error("Cannot delete message: client is nil")
      errorState = .noClient
      return false
    }

    let input = ChatBskyConvoDeleteMessageForSelf.Input(convoId: convoId, messageId: messageId)
     do {
      let (responseCode, _) = try await client.chat.bsky.convo.deleteMessageForSelf(input: input)
 
      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Error deleting message \(messageId): HTTP \(responseCode)")
        errorState = .networkError(code: responseCode)
        return false
      }

      // Remove message from local state
      if var messages = messagesMap[convoId] {
        messages.removeAll { $0.id == messageId }
        messagesMap[convoId] = messages
      }

      if var originalMessages = originalMessagesMap[convoId] {
        originalMessages.removeValue(forKey: messageId)
        originalMessagesMap[convoId] = originalMessages
      }

      logger.debug("Message \(messageId) deleted successfully")
      return true

    } catch {
      logger.error("Error deleting message \(messageId): \(error.localizedDescription)")
      setErrorState(error)
      return false
    }
  }

  @MainActor
  func markAllConversationsAsRead() async -> Bool {
    guard let client = client else {
      logger.error("Cannot mark all conversations as read: client is nil")
      errorState = .noClient
      return false
    }

     do {
        let (responseCode, _) = try await client.chat.bsky.convo.updateAllRead(input: .init())
 
      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Error marking all conversations as read: HTTP \(responseCode)")
        errorState = .networkError(code: responseCode)
        return false
      }

      // Update local state - set all unread counts to 0
      for _ in conversations.indices {
        // Since ConvoView might be immutable, we'd need to refresh from server
        // For now, just refresh the conversation list
      }
      
      await loadConversations(refresh: true)
      logger.debug("All conversations marked as read successfully")
      return true

    } catch {
      logger.error("Error marking all conversations as read: \(error.localizedDescription)")
      setErrorState(error)
      return false
    }
  }

  @MainActor
  func getConversationLog(cursor: String? = nil) async -> (logs: [Any]?, cursor: String?) {
    guard let client = client else {
      logger.error("Cannot get conversation log: client is nil")
      errorState = .noClient
      return (nil, nil)
    }

    let params = ChatBskyConvoGetLog.Parameters(cursor: cursor)
     do {
      let (responseCode, response) = try await client.chat.bsky.convo.getLog(input: params)
 
      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Error getting conversation log: HTTP \(responseCode)")
        errorState = .networkError(code: responseCode)
        return (nil, nil)
      }

      guard let logData = response else {
        logger.error("No data returned from conversation log request")
        errorState = .emptyResponse
        return (nil, nil)
      }

      logger.debug("Successfully retrieved conversation log")
      return (logData.logs, logData.cursor)

    } catch {
      logger.error("Error getting conversation log: \(error.localizedDescription)")
      setErrorState(error)
      return (nil, nil)
    }
  }

  // MARK: - Reaction Actions (Live)
  @MainActor
  func toggleReaction(convoId: String, messageId: String, emoji: String) async throws {
    do {
      // Validate input parameters to prevent crashes
      guard !convoId.isEmpty, !messageId.isEmpty, !emoji.isEmpty else {
        logger.error("Invalid parameters for toggleReaction: convoId='\(convoId)', messageId='\(messageId)', emoji='\(emoji)'")
        return
      }
      
      // Safely check if the user has already reacted with this emoji
      guard let convoMessages = originalMessagesMap[convoId],
            let messageView = convoMessages[messageId] else { 
        logger.warning("Message not found in originalMessagesMap for convoId='\(convoId)', messageId='\(messageId)'")
        return 
      }

      // Get the current user's DID first
      let currentUserDid = try await client?.getDid()

      // Then use it in the contains check
      let hasReacted =
        messageView.reactions?.contains(where: {
          $0.value == emoji && $0.sender.did.didString() == currentUserDid
        }) ?? false

      if hasReacted {
        _ = await removeReaction(convoId: convoId, messageId: messageId, emoji: emoji)
      } else {
        _ = await addReaction(convoId: convoId, messageId: messageId, emoji: emoji)
      }
    } catch {
      logger.error("Error in toggleReaction: \(error.localizedDescription)")
      
      // Only set error state for non-cancellation errors to prevent alert loops
      if shouldShowError(error) {
        setErrorState(error)
      }
      
      // Re-throw only non-cancellation errors to maintain API contract while preventing loops
      if shouldShowError(error) {
        throw error
      }
      // For cancellation errors, we silently return without throwing
    }
  }

  @MainActor
  private func addReaction(convoId: String, messageId: String, emoji: String) async -> Bool {
    guard let client = client else { return false }
    do {
      let input = ChatBskyConvoAddReaction.Input(
        convoId: convoId, messageId: messageId, value: emoji)
         let (responseCode, response) = try await client.chat.bsky.convo.addReaction(input: input)
       guard responseCode >= 200 && responseCode < 300, let updated = response?.message else {
        return false
      }
      await updateMessageInLocalState(updated)
      return true
    } catch {
      logger.error("Failed to add reaction: \(error.localizedDescription)")
      // Only set error state for non-cancellation errors
      if shouldShowError(error) {
        setErrorState(error)
      }
      return false
    }
  }

  @MainActor
  private func removeReaction(convoId: String, messageId: String, emoji: String) async -> Bool {
    guard let client = client else { return false }
    do {
      let input = ChatBskyConvoRemoveReaction.Input(
        convoId: convoId, messageId: messageId, value: emoji)
         let (responseCode, response) = try await client.chat.bsky.convo.removeReaction(input: input)
       guard responseCode >= 200 && responseCode < 300, let updated = response?.message else {
        return false
      }
      await updateMessageInLocalState(updated)
      return true
    } catch {
      logger.error("Failed to remove reaction: \(error.localizedDescription)")
      // Only set error state for non-cancellation errors
      if shouldShowError(error) {
        setErrorState(error)
      }
      return false
    }
  }

  // MARK: - Search Methods

  /// Search for conversations and profiles based on a search term
  @MainActor
  func searchLocal(searchTerm: String, currentUserDID: String?) {
    logger.debug("Performing local search for: \(searchTerm)")

    guard !searchTerm.isEmpty else {
      filteredConversations = []
      filteredProfiles = []
      return
    }

    let searchText = searchTerm.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

    // Filter conversations based on three criteria:
    // 1. Member names/handles
    // 2. Last message content
    // 3. Messages in the conversation
    if let did = currentUserDID {
      filteredConversations = conversations.filter { convo in
        // 1. Check if any member matches (except current user)
        let otherMembers = convo.members.filter { $0.did.didString() != did }
        let memberMatches = otherMembers.contains { member in
          let nameMatch = member.displayName?.lowercased().contains(searchText) ?? false
          let handleMatch = member.handle.description.lowercased().contains(searchText)
          return nameMatch || handleMatch
        }

        if memberMatches {
          return true
        }

        // 2. Check last message
        if let lastMessage = convo.lastMessage {
          switch lastMessage {
          case .chatBskyConvoDefsMessageView(let messageView):
            if messageView.text.lowercased().contains(searchText) {
              return true
            }
          default:
            break
          }
        }

        // 3. Check message content in the loaded messages for this conversation
        if let convoMessages = messagesMap[convo.id] {
          for message in convoMessages {
            if message.text.lowercased().contains(searchText) {
              return true
            }
          }
        }

        return false
      }
    } else {
      filteredConversations = []
    }

    // Create a list of unique chat participants for contacts search
    let allChatParticipants = Set(conversations.flatMap { convo in
      convo.members.map { $0 }
    })

    // Filter profiles by search text
    filteredProfiles = Array(allChatParticipants)
      .filter { profile in
        // Don't include current user
        guard profile.did.didString() != currentUserDID else { return false }

        let nameMatch = profile.displayName?.lowercased().contains(searchText) ?? false
        let handleMatch = profile.handle.description.lowercased().contains(searchText)
        return nameMatch || handleMatch
      }
      // Sort alphabetically by display name or handle
      .sorted { profile1, profile2 in
        let name1 = profile1.displayName?.lowercased() ?? profile1.handle.description.lowercased()
        let name2 = profile2.displayName?.lowercased() ?? profile2.handle.description.lowercased()
        return name1 < name2
      }

      logger.debug("Local search found \(self.filteredConversations.count) conversations and \(self.filteredProfiles.count) profiles")
  }

  // MARK: - Helper Methods

  private func getProfile(for did: String) async -> AppBskyActorDefs.ProfileViewDetailed? {
    guard let client = client else {
      logger.error("Cannot fetch profile for \(did): client is nil")
      return nil
    }

    // Check cache first
    if let cachedProfile = profileCache[did] {
      logger.debug("Returning cached profile for \(did)")
      return cachedProfile
    }

    do {
      let params = try AppBskyActorGetProfile.Parameters(actor: ATIdentifier(string: did))
      let (responseCode, response) = try await client.app.bsky.actor.getProfile(input: params)

      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Error fetching profile for \(did): HTTP \(responseCode)")
        return nil
      }

      if let profile = response {
        // Cache the profile
        profileCache[did] = profile
      }

      return response

    } catch {
      logger.error("Error fetching profile for \(did): \(error.localizedDescription)")
      return nil
    }
  }

  /// Creates an optimistic message for immediate UI feedback
  private func createOptimisticMessage(tempId: String, text: String, convoId: String) async -> Message {
    let currentUserID = try? await client?.getDid()
    
    return Message(
      id: tempId,  // Use temporary ID
      user: User(
        id: currentUserID ?? "current-user",
        name: "You",
        avatarURL: nil,  // Could load current user's avatar if available
        isCurrentUser: true
      ),
      status: .sending,  // Show as sending
      createdAt: Date(),
      text: text,
      attachments: []
    )
  }

  /// Creates a `Message` object suitable for ExyteChat from a Bluesky `MessageView`.
  private func createChatMessage(from messageView: ChatBskyConvoDefs.MessageView) async -> Message {
    // Ensure client and session DID are available to determine 'isCurrentUser'
    let currentUserID = try? await client?.getDid()
    let isCurrentUser = messageView.sender.did.didString() == currentUserID

    // Fetch profile details (name, avatar) asynchronously or use cached data
    let senderProfile = await getProfile(for: messageView.sender.did.didString())
    let userName = senderProfile?.displayName ?? "@\(messageView.sender.did.didString())"
    let avatarURL = senderProfile?.avatar?.url

    // Convert timestamp
    let createdAtDate = messageView.sentAt.date  // Assuming this is already a Date object

    // Process facets (mentions, links, etc.)
    var processedText = messageView.text
    var attachments: [Attachment] = []
    
    // Process facets (mentions, links, etc.)
//    if let facets = messageView.facets {
//      for facet in facets {
//        // Handle different facet types
//        for feature in facet.features {
//          switch feature {
//          case .appBskyRichtextFacetMention(let mention):
//            // For mentions, we might want to highlight them or make them tappable
//            // For now, just ensure the text is preserved correctly
//            logger.debug("Message contains mention: \(mention.did)")
//            
//          case .appBskyRichtextFacetLink(let link):
//            // For links, add them as text attachments or inline
//            logger.debug("Message contains link: \(link.uri)")
//            
//            // Add link as attachment if ExyteChat supports link previews
////              if let url = URL(string: link.uri.uriString()) {
////                  attachments.append(Attachment(id: url.absoluteString, url: <#URL#>, type: .))
////            }
//            
//          case .unexpected(let data):
//            logger.debug("Unexpected facet type: \(String(describing: data))")
//          case .appBskyRichtextFacetTag(_):
//              <#code#>
//          }
//        }
//      }
//    }
//    
//    // Process embeds (images, posts, records, etc.)
    if let embedUnion = messageView.embed {
      switch embedUnion {
      case .appBskyEmbedRecordView(let recordView):
        logger.debug("Message contains record embed: \(String(describing: recordView))")
        // Handle the specific record type within the recordView.record
        switch recordView.record {
        case .appBskyEmbedRecordViewRecord(let recordViewRecord):
          // Create a rich post embed attachment for display in chat
          let postAuthorHandle = recordViewRecord.author.handle.description
          
          // Access the record value to get the text
          let recordValue = recordViewRecord.value
          if case .knownType = recordValue {
            // Extract text from the record - this will need adjustment based on actual structure
            let postTextSnippet = "Post from @\(postAuthorHandle)" // Simplified for now
            let postDisplayText = postTextSnippet
            
            // Don't create attachments for post embeds - they're handled by RecordEmbedView
            // The embed is already passed to MessageBubble separately
          }

        case .appBskyGraphDefsListView(let listView):
          logger.debug("Embed is a list view: \(listView.name)")
          processedText += "\n\n📝 Shared List: \(listView.name)"
          
        case .appBskyLabelerDefsLabelerView(let labelerView):
          logger.debug("Embed is a labeler view: \(labelerView.creator.handle)")
          processedText += "\n\n🏷️ Shared Labeler: @\(labelerView.creator.handle)"
          
        case .appBskyGraphDefsStarterPackViewBasic(let starterPackView):
          logger.debug("Embed is a starter pack")
          processedText += "\n\n🎁 Shared Starter Pack"
          
        case .unexpected(let data):
          logger.warning("Unexpected record type in embed: \(String(describing: data))")
          
        default:
          logger.warning("Unhandled record type in embed: \(String(describing: recordView.record))")
        }
        
      case .unexpected(let data):
        logger.debug("Unexpected embed type: \(String(describing: data))")
      }
    }
    return Message(
      id: messageView.id,  // Use the message ID from Bluesky
      user: User(
        id: messageView.sender.did.didString(),  // Use sender's DID
        name: userName,
        avatarURL: avatarURL,
        isCurrentUser: isCurrentUser
      ),
      status: .sent,  // Assuming sent, could be updated based on API response or logic
      createdAt: createdAtDate, text: processedText,
      attachments: attachments
    )
  }

  /// Updates a specific message within the `messagesMap` based on an updated `MessageView`.
  @MainActor
  private func updateMessageInLocalState(_ updatedMessageView: ChatBskyConvoDefs.MessageView) async {
    // Find the conversation containing this message
    // This might be inefficient if there are many conversations.
    // Consider passing convoId if available from the calling context (e.g., reaction response).
    for (convoId, messages) in messagesMap {
      if let index = messages.firstIndex(where: { $0.id == updatedMessageView.id }) {
        var updatedMessages = messages
        // Recreate the ExyteChat Message object with updated data
        updatedMessages[index] = await createChatMessage(from: updatedMessageView)
        messagesMap[convoId] = updatedMessages

        if var existingOriginals = originalMessagesMap[convoId] {
          existingOriginals[updatedMessageView.id] = updatedMessageView
          originalMessagesMap[convoId] = existingOriginals
        }

        logger.debug("Updated message \(updatedMessageView.id) in local state for convo \(convoId)")
        // Found and updated, no need to continue loop
        return
      }
    }
    logger.warning("Could not find message \(updatedMessageView.id) in local state to update.")
  }

  /// Updates the `lastMessage` property of a conversation in the `conversations` array.
  @MainActor
  private func updateConversationLastMessage(
    convoId: String, messageView: ChatBskyConvoDefs.MessageView
  ) {
    if let index = conversations.firstIndex(where: { $0.id == convoId }) {
      // We need to update the ConvoView, which might be immutable.
      // A common pattern is to replace the element with a modified copy.
      _ = conversations[index]

      // Create the correct union type for the last message
      _ = ChatBskyConvoDefs.ConvoViewLastMessageUnion
        .chatBskyConvoDefsMessageView(messageView)

      // Create a new ConvoView instance with the updated lastMessage
      // This assumes ConvoView has an initializer or properties are mutable.
      // If immutable, you might need a custom struct or recreate it fully.
      // For demonstration, assuming properties can be set (replace if needed):

      // This direct mutation won't work if ConvoView is a struct from a library.
      // conversations[index].lastMessage = updatedLastMessage

      // Instead, you might need to recreate it (if possible) or rely on the next refresh.
      // Example if ConvoView was mutable or had an appropriate init:
      // conversations[index] = ChatBskyConvoDefs.ConvoView(..., lastMessage: updatedLastMessage, ...)

      // For now, log and rely on refresh:
      logger.debug(
        "Need to update last message preview for convo \(convoId). Relying on next refresh.")

      // Also, move the updated conversation to the top of the list
      let updatedConvo = conversations.remove(at: index)
      conversations.insert(updatedConvo, at: 0)
      logger.debug("Moved conversation \(convoId) to top.")

    }
  }

  // MARK: - Actor Management Methods

  @MainActor
  func exportChatAccountData() async -> Data? {
    guard let client = client else {
      logger.error("Cannot export chat account data: client is nil")
      errorState = .noClient
      return nil
    }

     do {
      let (responseCode, output) = try await client.chat.bsky.actor.exportAccountData()
 
      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Error exporting chat account data: HTTP \(responseCode)")
        errorState = .networkError(code: responseCode)
        return nil
      }

      logger.debug("Successfully exported chat account data")
      // Convert the output to Data if needed, or return the raw data
      if let outputData = output {
        return try JSONEncoder().encode(outputData)
      }
      return nil

    } catch {
      logger.error("Error exporting chat account data: \(error.localizedDescription)")
      setErrorState(error)
      return nil
    }
  }

  @MainActor
  func deleteChatAccount() async -> (success: Bool, exportData: Data?) {
    guard let client = client else {
      logger.error("Cannot delete chat account: client is nil")
      errorState = .noClient
      return (false, nil)
    }

     do {
      let (responseCode, output) = try await client.chat.bsky.actor.deleteAccount()
 
      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Error deleting chat account: HTTP \(responseCode)")
        errorState = .networkError(code: responseCode)
        return (false, nil)
      }

      // Clear all local chat data after successful deletion
      conversations = []
      messagesMap = [:]
      originalMessagesMap = [:]
      conversationsCursor = nil
      messagesCursors = [:]
      profileCache = [:]
      filteredConversations = []
      filteredProfiles = []

      logger.debug("Successfully deleted chat account")
      
      // Convert output to Data if available
      let exportData: Data?
      if let outputData = output {
        exportData = try JSONEncoder().encode(outputData)
      } else {
        exportData = nil
      }
      
      return (true, exportData)

    } catch {
      logger.error("Error deleting chat account: \(error.localizedDescription)")
      setErrorState(error)
      return (false, nil)
    }
  }

  // MARK: - Moderation Methods

  @MainActor
  func getActorMetadata(actor: String) async -> ChatBskyModerationGetActorMetadata.Output? {
    guard let client = client else {
      logger.error("Cannot get actor metadata: client is nil")
      errorState = .noClient
      return nil
    }

    do {
      let params = ChatBskyModerationGetActorMetadata.Parameters(
        actor: try DID(didString: actor)
      )
         
      let (responseCode, response) = try await client.chat.bsky.moderation.getActorMetadata(input: params)
 
      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Error getting actor metadata for \(actor): HTTP \(responseCode)")
        errorState = .networkError(code: responseCode)
        return nil
      }

      logger.debug("Successfully retrieved actor metadata for \(actor)")
      return response

    } catch {
      logger.error("Error getting actor metadata for \(actor): \(error.localizedDescription)")
      setErrorState(error)
      return nil
    }
  }

  @MainActor
  func getMessageContext(convoId: String, messageId: String, before: Int? = nil, after: Int? = nil) async -> ChatBskyModerationGetMessageContext.Output? {
    guard let client = client else {
      logger.error("Cannot get message context: client is nil")
      errorState = .noClient
      return nil
    }

    let params = ChatBskyModerationGetMessageContext.Parameters(
      convoId: convoId,
      messageId: messageId,
      before: before,
      after: after
    )
     do {
      let (responseCode, response) = try await client.chat.bsky.moderation.getMessageContext(input: params)
 
      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Error getting message context for \(messageId): HTTP \(responseCode)")
        errorState = .networkError(code: responseCode)
        return nil
      }

      logger.debug("Successfully retrieved message context for \(messageId)")
      return response

    } catch {
      logger.error("Error getting message context for \(messageId): \(error.localizedDescription)")
      setErrorState(error)
      return nil
    }
  }

  @MainActor
  func updateActorAccess(actor: String, allowAccess: Bool, ref: String? = nil) async -> Bool {
    guard let client = client else {
      logger.error("Cannot update actor access: client is nil")
      errorState = .noClient
      return false
    }

    do {
      let input = ChatBskyModerationUpdateActorAccess.Input(
        actor: try DID(didString: actor),
        allowAccess: allowAccess,
        ref: ref
      )
         
      let responseCode = try await client.chat.bsky.moderation.updateActorAccess(input: input)
 
      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Error updating actor access for \(actor): HTTP \(responseCode)")
        errorState = .networkError(code: responseCode)
        return false
      }

      logger.debug("Successfully updated actor access for \(actor) to \(allowAccess)")
      return true

    } catch {
      logger.error("Error updating actor access for \(actor): \(error.localizedDescription)")
      setErrorState(error)
      return false
    }
  }

  // MARK: - Message Requests Management
  
  /// Updates the message requests and accepted conversations lists based on status
  @MainActor
  private func updateConversationsByStatus() {
    messageRequests = conversations.filter { $0.status == "request" }
    acceptedConversations = conversations.filter { $0.status == "accepted" || $0.status == nil }
    
      logger.debug("Updated conversation lists: \(self.messageRequests.count) requests, \(self.acceptedConversations.count) accepted")
  }
  
  /// Loads conversations with a specific status filter
  @MainActor
  func loadMessageRequests(refresh: Bool = false) async {
    guard let client = client else {
      logger.error("Cannot load message requests: client is nil")
      errorState = .noClient
      return
    }

    do {
      loadingConversations = true
      errorState = nil

      let cursorToUse = refresh ? nil : conversationsCursor

      let params = ChatBskyConvoListConvos.Parameters(
        limit: 20,
        cursor: cursorToUse,
        readState: nil,
        status: "request"  // Filter for requests only
      )

      logger.debug("Loading message requests with cursor: \(cursorToUse ?? "nil")")
         let (responseCode, response) = try await client.chat.bsky.convo.listConvos(input: params)
 
      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Error loading message requests: HTTP \(responseCode)")
        errorState = .networkError(code: responseCode)
        loadingConversations = false
        return
      }

      guard let convosData = response else {
        logger.error("No data returned from message requests request")
        errorState = .emptyResponse
        loadingConversations = false
        return
      }

      // Update message requests specifically
      if refresh {
        messageRequests = convosData.convos
      } else {
        let existingIDs = Set(messageRequests.map { $0.id })
        let newRequests = convosData.convos.filter { !existingIDs.contains($0.id) }
        messageRequests.append(contentsOf: newRequests)
      }

      logger.debug("Loaded \(convosData.convos.count) message requests")

    } catch {
      logger.error("Error loading message requests: \(error.localizedDescription)")
      setErrorState(error)
    }

    loadingConversations = false
  }
  
  /// Accepts a message request and moves it to accepted conversations
  @MainActor
  func acceptMessageRequest(convoId: String) async -> Bool {
    let success = await acceptConversation(convoId: convoId)
    if success {
      // Move conversation from requests to accepted
      if let requestIndex = messageRequests.firstIndex(where: { $0.id == convoId }) {
        let conversation = messageRequests.remove(at: requestIndex)
        // Update status to accepted (this would normally come from server)
        // Note: We can't modify the struct directly, so we'll rely on the next refresh
        acceptedConversations.insert(conversation, at: 0)
        
        // Also update the main conversations list
        if let mainIndex = conversations.firstIndex(where: { $0.id == convoId }) {
          conversations.remove(at: mainIndex)
          conversations.insert(conversation, at: 0)
        }
      }
    }
    return success
  }
  
  /// Declines a message request
  @MainActor
  func declineMessageRequest(convoId: String) async -> Bool {
    await leaveConversation(convoId: convoId)
      // Remove from message requests
      messageRequests.removeAll { $0.id == convoId }
    // Note: leaveConversation already removes from main conversations list
    return true
  }
  
  /// Gets the count of unread message requests
  var unreadMessageRequestsCount: Int {
    messageRequests.reduce(0) { $0 + $1.unreadCount }
  }
  
  /// Gets the total count of message requests
  var messageRequestsCount: Int {
    messageRequests.count
  }
  
  /// Gets the total count of unread messages across all conversations
  var totalUnreadCount: Int {
    conversations.reduce(0) { $0 + $1.unreadCount }
  }
  
  // MARK: - Polling Methods
  
  /// Starts polling for conversation updates
  func startConversationsPolling() {
    stopConversationsPolling()
    
    conversationsPollingTask = Task { [weak self] in
      guard let self = self else { return }
      
      while !Task.isCancelled {
        let interval = self.isAppActive ? self.activeListPollInterval : self.backgroundPollInterval
        
        do {
          try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        } catch {
          break
        }
        
        if !Task.isCancelled {
          await self.loadConversations(refresh: true)
        }
      }
    }
    
    logger.debug("Started conversations polling")
  }
  
  /// Stops polling for conversation updates
  func stopConversationsPolling() {
    conversationsPollingTask?.cancel()
    conversationsPollingTask = nil
    logger.debug("Stopped conversations polling")
  }
  
  /// Starts polling for messages in a specific conversation
  func startMessagePolling(for convoId: String) {
    stopMessagePolling(for: convoId)
    
    messagePollingTasks[convoId] = Task { [weak self] in
      guard let self = self else { return }
      
      while !Task.isCancelled {
        let interval = self.isAppActive ? self.activeConversationPollInterval : self.backgroundPollInterval
        
        do {
          try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        } catch {
          break
        }
        
        if !Task.isCancelled {
          await self.loadMessages(convoId: convoId, refresh: true)
        }
      }
    }
    
    logger.debug("Started message polling for conversation \(convoId)")
  }
  
  /// Stops polling for messages in a specific conversation
  func stopMessagePolling(for convoId: String) {
    messagePollingTasks[convoId]?.cancel()
    messagePollingTasks[convoId] = nil
    logger.debug("Stopped message polling for conversation \(convoId)")
  }
  
  /// Stops all polling tasks
  private func stopAllPolling() {
    stopConversationsPolling()
    
    for convoId in messagePollingTasks.keys {
      stopMessagePolling(for: convoId)
    }
    
    logger.debug("Stopped all polling tasks")
  }

  // MARK: - Supporting Types
  
  struct PendingMessage {
    let tempId: String
    let convoId: String
    let text: String
    let timestamp: Date
    var retryCount: Int = 0
  }
  
  enum MessageDeliveryStatus: Equatable {
    case sending
    case sent
    case delivered
    case failed(Error?)
    
    static func == (lhs: MessageDeliveryStatus, rhs: MessageDeliveryStatus) -> Bool {
      switch (lhs, rhs) {
      case (.sending, .sending), (.sent, .sent), (.delivered, .delivered):
        return true
      case (.failed, .failed):
        return true
      default:
        return false
      }
    }
  }

  // MARK: - Error Enum

  enum ChatError: Error, LocalizedError, Equatable {
    case noClient
    case networkError(code: Int)
    case emptyResponse
    case generalError(Error)

    var errorDescription: String? {
      switch self {
      case .noClient:
        return NSLocalizedString("Not connected to Bluesky service.", comment: "Chat error")
      case .networkError(let code):
        return String(
          format: NSLocalizedString("Network error (HTTP %d)", comment: "Chat error"), code)
      case .emptyResponse:
        return NSLocalizedString(
          "Received an empty response from the server.", comment: "Chat error")
      case .generalError(let error):
        return error.localizedDescription
      }
    }

    // Equatable conformance for potential UI state comparison
    static func == (lhs: ChatError, rhs: ChatError) -> Bool {
      switch (lhs, rhs) {
      case (.noClient, .noClient):
        return true
      case (.networkError(let lCode), .networkError(let rCode)):
        return lCode == rCode
      case (.emptyResponse, .emptyResponse):
        return true
      case (.generalError(let lError), .generalError(let rError)):
        // Comparing underlying errors can be tricky, often comparing descriptions is sufficient for UI
        return lError.localizedDescription == rError.localizedDescription
      default:
        return false
      }
    }
  }
  
  // MARK: - Error Handling Helpers
  
  /// Helper method to determine if an error should be shown to the user
  private func shouldShowError(_ error: Error) -> Bool {
    // Don't show cancellation errors to users - these are expected during normal operation
    if error is CancellationError {
      logger.debug("Ignoring cancellation error: \(error.localizedDescription)")
      return false
    }
    
    // Check if the error description contains "cancelled" (case insensitive)
    let errorDescription = error.localizedDescription.lowercased()
    if errorDescription.contains("cancelled") || errorDescription.contains("canceled") {
      logger.debug("Ignoring cancellation-related error: \(error.localizedDescription)")
      return false
    }
    
    return true
  }
  
  /// Helper method to safely set error state, filtering out cancellation errors
  private func setErrorState(_ error: Error) {
    if shouldShowError(error) {
      errorState = .generalError(error)
    }
  }
}
#endif
