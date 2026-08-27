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
  private(set) var expandedSystemGroupIDs: Set<String> = []
  private var hasReceivedInitialMessages: Bool = false

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
    _ = await sendMessage(text: text, embed: nil, replyTo: nil)
  }

  func sendMessage(
    text: String,
    embed: ChatBskyConvoDefs.MessageInputEmbedUnion? = nil,
    replyTo: ChatBskyConvoDefs.ReplyRef? = nil
  ) async -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty || embed != nil else { return false }

    let success = await chatManager.sendMessage(
      convoId: convoID,
      text: text,
      embed: embed,
      replyTo: replyTo
    )
    if success {
      draftText = ""
      // Refresh to get the sent message
      await loadMessages()
      return true
    } else {
      self.error = NSError(domain: "ChatError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to send message"])
      return false
    }
  }

  func toggleSystemGroup(groupID: String) {
    if expandedSystemGroupIDs.contains(groupID) {
      expandedSystemGroupIDs.remove(groupID)
    } else {
      expandedSystemGroupIDs.insert(groupID)
    }
    updateMessagesFromManager()
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
    let existingIDs = Set(messages.map { $0.id })
    let maxExistingTimestamp = messages.map { $0.sentAt }.max() ?? .distantPast

    // Get original messages and system messages from ChatManager
    let originalMessages = chatManager.originalMessagesMap[convoID] ?? [:]
    let systemMessages = chatManager.systemMessagesMap[convoID] ?? [:]
    let relatedProfiles = chatManager.relatedProfilesMap[convoID] ?? [:]

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
          createdAt: member.createdAt,
          chatDisabled: nil,
          verification: nil,
          kind: nil
        )
      }
      return profiles
    }()

    let allProfiles = memberProfiles.merging(relatedProfiles) { current, _ in current }

    // 1. Convert user messages to BlueskyMessageAdapter
    let userAdapters = originalMessages.values.map { messageView in
      let senderDID = messageView.sender.did.didString()
      let profile = allProfiles[senderDID]
      let reactions = messageView.reactions ?? []

      return BlueskyMessageAdapter(
        messageView: messageView,
        currentUserDID: currentUserDID,
        senderProfile: profile,
        reactions: reactions
      )
    }

    // 2. Convert system messages to BlueskyMessageAdapter
    let systemAdapters = systemMessages.values.map { systemMessageView in
      BlueskyMessageAdapter(
        systemMessageView: systemMessageView,
        relatedProfiles: allProfiles
      )
    }

    // 3. Combine and sort chronologically by sentAt
    let combined = (userAdapters + systemAdapters).sorted { $0.sentAt < $1.sentAt }

    // 4. Group consecutive same-day system messages (1-3 separate, 4+ collapsed)
    self.messages = BlueskySystemMessageGrouper.group(
      messages: combined,
      expandedGroupIDs: expandedSystemGroupIDs
    )
    // Update hasMoreMessages based on ChatManager's cursor system
    // Check if there's a cursor for this conversation - if there is, more messages may be available
    hasMoreMessages = chatManager.hasMoreMessages(for: convoID)

    // Trigger haptic feedback for genuinely new incoming messages.
    // Guard with hasReceivedInitialMessages to skip the first load, and
    // sentAt > maxExistingTimestamp to exclude paginated historical messages.
    if hasReceivedInitialMessages {
      let hasNewIncoming = self.messages.contains {
        !existingIDs.contains($0.id) && !$0.isFromCurrentUser && $0.sentAt > maxExistingTimestamp
      }
      if hasNewIncoming {
        PlatformHaptics.light()
      }
    }
    hasReceivedInitialMessages = true
  }
  
  private func startObservingChatManager() {
    chatObservationTask?.cancel()
    chatObservationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      withObservationTracking {
        _ = chatManager.originalMessagesMap[convoID]
        _ = chatManager.systemMessagesMap[convoID]
        _ = chatManager.relatedProfilesMap[convoID]
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
