import Foundation
import SwiftUI
import Observation
import Petrel

/// Data source that wraps ChatManager for Bluesky conversations
@MainActor
@Observable
final class BlueskyConversationDataSource: UnifiedChatDataSource {
  typealias Message = BlueskyMessageAdapter

  // MARK: - Properties

  private let chatManager: ChatManager
  private let convoID: String
  private let currentUserDID: String
  @ObservationIgnored private nonisolated(unsafe) var chatObservationTask: Task<Void, Never>?

  private(set) var messages: [BlueskyMessageAdapter] = []
  private(set) var isLoading: Bool = false
  private(set) var hasMoreMessages: Bool = true
  private(set) var error: Error?

  var draftText: String = ""

  // MARK: - Init

  init(chatManager: ChatManager, convoID: String, currentUserDID: String) {
    self.chatManager = chatManager
    self.convoID = convoID
    self.currentUserDID = currentUserDID
    startObservingChatManager()
  }
  
  deinit {
    chatObservationTask?.cancel()
    chatObservationTask = nil
  }

  // MARK: - UnifiedChatDataSource

  func message(for id: String) -> BlueskyMessageAdapter? {
    messages.first { $0.id == id }
  }

  func loadMessages() async {
    guard !isLoading else { return }
    isLoading = true
    error = nil

    await chatManager.loadMessages(convoId: convoID, refresh: true)
    updateMessagesFromManager()
    isLoading = false
  }

  func loadMoreMessages() async {
    guard !isLoading, hasMoreMessages else { return }
    isLoading = true

    await chatManager.loadMessages(convoId: convoID, refresh: false)
    updateMessagesFromManager()
    isLoading = false
  }

  func sendMessage(text: String) async {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

    let success = await chatManager.sendMessage(convoId: convoID, text: text, embed: nil)
    if success {
      draftText = ""
      // Refresh to get the sent message
      await loadMessages()
    } else {
      self.error = NSError(domain: "ChatError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to send message"])
    }
  }

  func toggleReaction(messageID: String, emoji: String) {
    Task {
      do {
        try await chatManager.toggleReaction(convoId: convoID, messageId: messageID, emoji: emoji)
        updateMessagesFromManager()
      } catch {
        self.error = error
      }
    }
  }

  func addReaction(messageID: String, emoji: String) {
    // For Bluesky, addReaction is the same as toggle (API handles add/remove based on state)
    toggleReaction(messageID: messageID, emoji: emoji)
  }

  func deleteMessage(messageID: String) async {
    let success = await chatManager.deleteMessageForSelf(convoId: convoID, messageId: messageID)
    if success {
      updateMessagesFromManager()
    } else {
      self.error = NSError(domain: "ChatError", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to delete message"])
    }
  }

  // MARK: - Private

  private func updateMessagesFromManager() {
    // Get original messages from ChatManager (now using native MessageView types)
    let originalMessages = chatManager.originalMessagesMap[convoID] ?? [:]

    // Get member profiles from the conversation
    let conversation = chatManager.conversations.first { $0.id == convoID }
    let memberProfiles: [String: ChatBskyActorDefs.ProfileViewBasic] = {
      guard let convo = conversation else { return [:] }
      var profiles: [String: ChatBskyActorDefs.ProfileViewBasic] = [:]
      for member in convo.members {
        profiles[member.did.didString()] = ChatBskyActorDefs.ProfileViewBasic(
          did: member.did,
          handle: member.handle,
          displayName: member.displayName,
          avatar: member.avatar,
          associated: member.associated,
          viewer: nil,
          labels: nil,
          chatDisabled: nil,
          verification: nil
        )
      }
      return profiles
    }()

    // Convert ChatBskyConvoDefs.MessageView to BlueskyMessageAdapter, sorted by sentAt
    self.messages = originalMessages.values
      .sorted { $0.sentAt.date < $1.sentAt.date }
      .map { messageView in
        let senderDID = messageView.sender.did.didString()
        let profile = memberProfiles[senderDID]
        let reactions = messageView.reactions ?? []

        return BlueskyMessageAdapter(
          messageView: messageView,
          currentUserDID: currentUserDID,
          senderProfile: profile,
          reactions: reactions
        )
      }

    // Update hasMoreMessages based on ChatManager's cursor system
    // Check if there's a cursor for this conversation - if there is, more messages may be available
    hasMoreMessages = chatManager.hasMoreMessages(for: convoID)
  }
  
  private func startObservingChatManager() {
    chatObservationTask?.cancel()
    chatObservationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      withObservationTracking {
        _ = chatManager.originalMessagesMap[convoID]
        _ = chatManager.conversations
        _ = chatManager.hasMoreMessages(for: convoID)
      } onChange: {
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.updateMessagesFromManager()
          self.startObservingChatManager()
        }
      }
    }
  }
}
