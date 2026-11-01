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
  private weak var appState: AppState?

  private(set) var messages: [BlueskyMessageAdapter] = []
  var messageLoadState: ChatManager.MessageLoadState {
    chatManager.messageLoadStates[convoID] ?? .idle
  }
  var isLoading: Bool { messageLoadState == .loading }
  private(set) var hasMoreMessages: Bool = true
  private(set) var error: Error?
  private(set) var expandedSystemGroupIDs: Set<String> = []
  private var hasReceivedInitialMessages: Bool = false

  /// Whether this is a group chat, which shows sender names above messages.
  var isGroupConversation: Bool {
    chatManager.conversations.first { $0.id == convoID }?.isGroupConversation ?? false
  }

  let draft = MessageDraft(BlueskyConversationDraft())
  var draftText: String {
    get { draft.value.text }
    set { draft.value.text = newValue }
  }
  // MARK: - Init

  init(chatManager: ChatManager, convoID: String, currentUserDID: String, appState: AppState? = nil) {
    self.chatManager = chatManager
    self.convoID = convoID
    self.currentUserDID = currentUserDID
    self.appState = appState
    updateMessagesFromManager()
    hasReceivedInitialMessages = false
    startObservingChatManager()
  }
  
  // MARK: - UnifiedChatDataSource

  func message(for id: String) -> BlueskyMessageAdapter? {
    messages.first { $0.id == id }
  }

  func loadMessages() async {
    guard !isLoading else { return }
    error = nil

    // The transcript owns load-error presentation; polling and Retry share this state.
    await chatManager.loadMessages(convoId: convoID, refresh: true)
    updateMessagesFromManager()
  }

  func loadMoreMessages() async {
    guard !isLoading, hasMoreMessages else { return }

    await chatManager.loadMessages(convoId: convoID, refresh: false)
    updateMessagesFromManager()
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
    // Explicit payloads do not own the editor draft, even when their text matches.
    return await transmitMessage(text: text, embed: embed, replyTo: replyTo)
  }

  func submitDraft() {
    draft.submitSend { value in
      await self.transmitDraft(value)
    }
  }

  func sendDraft(_ submission: MessageDraft<BlueskyConversationDraft>.Submission) async {
    let success = await transmitDraft(submission.value)
    draft.finishSend(submission, succeeded: success)
  }

  private func transmitDraft(_ value: BlueskyConversationDraft) async -> Bool {
    let embed: ChatBskyConvoDefs.MessageInputEmbedUnion?
    if value.attachedEmbed != nil, let postRef = value.postRef {
      embed = .appBskyEmbedRecord(AppBskyEmbedRecord(record: postRef))
    } else {
      embed = nil
    }
    let reply = value.replyTarget.map { ChatBskyConvoDefs.ReplyRef(messageId: $0.id) }
    return await transmitMessage(text: value.text, embed: embed, replyTo: reply)
  }

  private func transmitMessage(
    text: String,
    embed: ChatBskyConvoDefs.MessageInputEmbedUnion?,
    replyTo: ChatBskyConvoDefs.ReplyRef?
  ) async -> Bool {
    guard !Task.isCancelled else { return false }
    error = nil
    let success = await chatManager.sendMessage(
      convoId: convoID,
      text: text,
      embed: embed,
      replyTo: replyTo
    )
    if success {
      await loadMessages()
    } else if !Task.isCancelled {
      self.error = NSError(domain: "ChatError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to send message"])
    }
    return success
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

  /// The shared posts getMessages returned fully hydrated
  /// (`app.bsky.embed.record#view` holding a `#viewRecord`), newest message
  /// first, to seed ChatRecordEmbedStore. A seed carries the accept-labelers
  /// DIDs its page was hydrated under when ChatManager recorded that page and
  /// the message still holds the record the page returned; the store renders
  /// those on the first layout without a getPosts call. The rest name the posts
  /// the store confirms with getPosts under the current header before a card
  /// shows them. Posts the server could not hydrate (not found, blocked,
  /// detached) are left out.
  nonisolated static func hydratedSharedPosts<Messages: Sequence>(
    in messages: Messages,
    hydrations: [String: ChatManager.SharedPostHydration] = [:]
  ) -> [ChatRecordEmbedStore.Seed]
  where Messages.Element == ChatBskyConvoDefs.MessageView {
    messages
      .compactMap { messageView -> (message: ChatBskyConvoDefs.MessageView, seed: ChatRecordEmbedStore.Seed)? in
        guard case .appBskyEmbedRecordView(let recordView)? = messageView.embed,
          case .appBskyEmbedRecordViewRecord(let record) = recordView.record
        else { return nil }
        let uri = record.uri.uriString()
        let hydration = hydrations[uri].flatMap { $0.record == recordView.record ? $0 : nil }
        let seed = ChatRecordEmbedStore.Seed(uri: uri, record: recordView.record, hydratedUnder: hydration?.labelerDIDs)
        return (messageView, seed)
      }
      .sorted { lhs, rhs in
        let lhsSent = lhs.message.sentAt.date
        let rhsSent = rhs.message.sentAt.date
        return lhsSent == rhsSent ? lhs.message.id > rhs.message.id : lhsSent > rhsSent
      }
      .map(\.seed)
  }

  private func updateMessagesFromManager() {
    let existingIDs = Set(messages.map { $0.id })
    let maxExistingTimestamp = messages.map { $0.sentAt }.max() ?? .distantPast

    // Get original messages and system messages from ChatManager
    let originalMessages = chatManager.originalMessagesMap[convoID] ?? [:]
    let systemMessages = chatManager.systemMessagesMap[convoID] ?? [:]
    let relatedProfiles = chatManager.relatedProfilesMap[convoID] ?? [:]


    // Seed ChatRecordEmbedStore from hydrated record embeds in getMessages (P135)
    if let state = appState ?? AppStateManager.shared.lifecycle.appState {
      ChatRecordEmbedStore.shared.seed(
        Self.hydratedSharedPosts(
          in: originalMessages.values, hydrations: chatManager.sharedPostHydrations(for: convoID)),
        conversation: convoID, appState: state)
    }
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
    withObservationTracking {
      _ = chatManager.conversationRevision(for: convoID)
      _ = chatManager.originalMessagesMap[convoID]
      _ = chatManager.systemMessagesMap[convoID]
      _ = chatManager.relatedProfilesMap[convoID]
      _ = chatManager.hasMoreMessages(for: convoID)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.updateMessagesFromManager()
        self.startObservingChatManager()
      }
    }
  }
}
