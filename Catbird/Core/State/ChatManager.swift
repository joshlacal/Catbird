import ExyteChat
import Foundation
import OSLog
import Petrel
import SwiftUI

/// Manages chat operations for the Bluesky chat feature
@Observable
final class ChatManager {
  private let logger = Logger(subsystem: "blue.catbird", category: "ChatManager")

  // AT Protocol client reference
  private(set) var client: ATProtoClient?  // Made private(set) for controlled access

  // Conversations and messages
  private(set) var conversations: [ChatBskyConvoDefs.ConvoView] = []
  private(set) var messagesMap: [String: [Message]] = [:]
  // Store original message views for reactions and other advanced features
  private(set) var originalMessagesMap: [String: [String: ChatBskyConvoDefs.MessageView]] = [:]  // [convoId: [messageId: MessageView]]
  private(set) var loadingConversations: Bool = false
  private(set) var loadingMessages: [String: Bool] = [:]
  var errorState: ChatError?

  // Profile caching
  private var profileCache: [String: AppBskyActorDefs.ProfileViewDetailed] = [:]

  // Pagination control
  var conversationsCursor: String? = nil
  private var messagesCursors: [String: String?] = [:]

  init(client: ATProtoClient? = nil) {
    self.client = client
    logger.debug("ChatManager initialized")
  }

  // Update client when auth changes
  func updateClient(_ client: ATProtoClient?) async {
    self.client = client
    logger.debug("ChatManager client updated")

    let currentClientDid = try? await client?.getDid()
    // Clear existing data when client changes (e.g., logout or account switch)
    if client == nil || currentClientDid != currentClientDid {
      conversations = []
      messagesMap = [:]
      originalMessagesMap = [:]
      conversationsCursor = nil
      messagesCursors = [:]
      loadingConversations = false
      loadingMessages = [:]
      errorState = nil
      profileCache = [:]  // Clear profile cache on client change
      logger.debug("Chat data cleared due to client change.")
    }
  }

  // MARK: - Conversation Loading

  @MainActor
  func loadConversations(refresh: Bool = false) async {
    guard let client = client else {
      logger.error("Cannot load conversations: client is nil")
      errorState = .noClient
      return
    }

    // Skip if already loading and not refreshing
    if loadingConversations && !refresh {
      logger.debug("Already loading conversations, skipping.")
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
      await client.setProxyHeader(did: "did:web:api.bsky.chat", service: "bsky_chat")
      let (responseCode, response) = try await client.chat.bsky.convo.listConvos(input: params)
      await client.clearProxyHeader()

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

      logger.debug(
        "Loaded \(convosData.convos.count) conversations. New cursor: \(convosData.cursor ?? "nil")"
      )

    } catch {
      logger.error("Error loading conversations: \(error.localizedDescription)")
      errorState = .generalError(error)
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

    // Skip if already loading this conversation and not refreshing
    if loadingMessages[convoId] == true && !refresh {
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
      await client.setProxyHeader(did: "did:web:api.bsky.chat", service: "bsky_chat")

      let (responseCode, response) = try await client.chat.bsky.convo.getMessages(input: params)
      await client.clearProxyHeader()

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
      errorState = .generalError(error)
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
    await client.setProxyHeader(did: "did:web:api.bsky.chat", service: "bsky_chat")
    do {
      let (responseCode, _) = try await client.chat.bsky.convo.leaveConvo(input: leaveInput)
      await client.clearProxyHeader()

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
      errorState = .generalError(error)
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
    await client.setProxyHeader(did: "did:web:api.bsky.chat", service: "bsky_chat")
    do {
      let (responseCode, response) = try await client.chat.bsky.convo.muteConvo(input: muteInput)
      await client.clearProxyHeader()

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
      errorState = .generalError(error)
    }
  }

  // MARK: - Message Actions

  @MainActor
  func sendMessage(convoId: String, text: String) async -> Bool {
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

    do {
      // TODO: Add facet generation if needed
      let messageInput = ChatBskyConvoDefs.MessageInput(
        text: text,
        facets: nil,  // Placeholder for rich text facets
        embed: nil  // Placeholder for embeds
      )

      let input = ChatBskyConvoSendMessage.Input(
        convoId: convoId,
        message: messageInput
      )

      logger.debug("Sending message to conversation \(convoId)")

      await client.setProxyHeader(did: "did:web:api.bsky.chat", service: "bsky_chat")

      let (responseCode, response) = try await client.chat.bsky.convo.sendMessage(input: input)

      await client.clearProxyHeader()

      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Error sending message to \(convoId): HTTP \(responseCode)")
        errorState = .networkError(code: responseCode)
        return false
      }

      guard let messageView = response else {
        logger.error("No message view returned after sending to \(convoId)")
        errorState = .emptyResponse  // Or a more specific error
        return false
      }

      let newMessage = await createChatMessage(from: messageView)

      // Update local state immediately
      if var existing = messagesMap[convoId] {
        existing.append(newMessage)  // Append new message to the end (newest)
        messagesMap[convoId] = existing
      } else {
        messagesMap[convoId] = [newMessage]
      }

      if var existingOriginals = originalMessagesMap[convoId] {
        existingOriginals[messageView.id] = messageView
        originalMessagesMap[convoId] = existingOriginals
      } else {
        originalMessagesMap[convoId] = [messageView.id: messageView]
      }

      // Optionally update the conversation list's last message preview
      updateConversationLastMessage(convoId: convoId, messageView: messageView)

      logger.debug("Message sent successfully to conversation \(convoId)")
      return true

    } catch {
      logger.error("Error sending message to \(convoId): \(error.localizedDescription)")
      errorState = .generalError(error)
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
      await client.setProxyHeader(did: "did:web:api.bsky.chat", service: "bsky_chat")

      let (responseCode, response) = try await client.chat.bsky.convo.updateRead(input: input)

      await client.clearProxyHeader()

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
        }
      } else {
        // Fallback if response doesn't contain the updated convo view
        if let index = conversations.firstIndex(where: { $0.id == convoId }) {
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

  // MARK: - Reaction Actions (Live)
  @MainActor
  func toggleReaction(convoId: String, messageId: String, emoji: String) async throws {
    // Check if the user has already reacted with this emoji
    guard let messageView = originalMessagesMap[convoId]?[messageId] else { return }

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
  }

  @MainActor
  private func addReaction(convoId: String, messageId: String, emoji: String) async -> Bool {
    guard let client = client else { return false }
    do {
      let input = ChatBskyConvoAddReaction.Input(
        convoId: convoId, messageId: messageId, value: emoji)
      await client.setProxyHeader(did: "did:web:api.bsky.chat", service: "bsky_chat")
      let (responseCode, response) = try await client.chat.bsky.convo.addReaction(input: input)
      await client.clearProxyHeader()
      guard responseCode >= 200 && responseCode < 300, let updated = response?.message else {
        return false
      }
      await updateMessageInLocalState(updated)
      return true
    } catch {
      logger.error("Failed to add reaction: \(error.localizedDescription)")
      return false
    }
  }

  @MainActor
  private func removeReaction(convoId: String, messageId: String, emoji: String) async -> Bool {
    guard let client = client else { return false }
    do {
      let input = ChatBskyConvoRemoveReaction.Input(
        convoId: convoId, messageId: messageId, value: emoji)
      await client.setProxyHeader(did: "did:web:api.bsky.chat", service: "bsky_chat")
      let (responseCode, response) = try await client.chat.bsky.convo.removeReaction(input: input)
      await client.clearProxyHeader()
      guard responseCode >= 200 && responseCode < 300, let updated = response?.message else {
        return false
      }
      await updateMessageInLocalState(updated)
      return true
    } catch {
      logger.error("Failed to remove reaction: \(error.localizedDescription)")
      return false
    }
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
//    if let embedUnion = messageView.embed {
//      switch embedUnion {
//      case .appBskyEmbedRecordView(let recordView):
//        logger.debug("Message contains record embed: \(String(describing: recordView))")
//        // Handle the specific record type within the recordView.record
//        switch recordView.record {
//        case .appBskyFeedDefsPostView(let postView):
//          // Now you have access to postView which is of type AppBskyFeedDefs.PostView
//          // You can use postView.uri, postView.author.handle, postView.record.text etc.
//          // For now, let's append a simple text representation to the message.
//          // You might create a custom attachment type or a more complex representation later.
//          let postAuthorHandle = postView.author.handle
//          let postTextSnippet = String(postView.record.text.prefix(50)) // Take a snippet
//          processedText += "\n\n[Shared Post by @\(postAuthorHandle): \"\(postTextSnippet)...\"]"
//          // If you want to make it an attachment, you'd need a suitable AttachmentType
//          // and decide how to represent it. For example, as a generic link if supported.
//          // attachments.append(Attachment(id: postView.uri, url: URL(string: postView.uri)!, type: .image)) // Placeholder type
//
//        case .appBskyGraphDefsListView(let listView):
//          logger.debug("Embed is a list view: \(listView.name)")
//          processedText += "\n\n[Shared List: \(listView.name)]"
//        case .appBskyLabelerDefsLabelerView(let labelerView):
//          logger.debug("Embed is a labeler view: \(labelerView.creator.handle)")
//          processedText += "\n\n[Shared Labeler: @\(labelerView.creator.handle)]"
//        case .appBskyGraphDefsStarterPackViewBasic(let starterPackView):
//          logger.debug("Embed is a starter pack: \(starterPackView.record.text)")
//          processedText += "\n\n[Shared Starter Pack]"
//        case .unexpected(let data):
//          logger.warning("Unexpected record type in embed: \(String(describing: data))")
//        default:
//          logger.warning("Unhandled record type in embed: \(String(describing: recordView.record))")
//        }
//      case .unexpected(let data):
//        logger.debug("Unexpected embed type: \(String(describing: data))")
//      }
//    }
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
  private func updateMessageInLocalState(_ updatedMessageView: ChatBskyConvoDefs.MessageView) async
  {
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
      var convoToUpdate = conversations[index]

      // Create the correct union type for the last message
      let updatedLastMessage = ChatBskyConvoDefs.ConvoViewLastMessageUnion
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
}
