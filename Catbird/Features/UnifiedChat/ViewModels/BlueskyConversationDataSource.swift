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

  struct PendingBlueskySend: Equatable {
    let id: String
    let text: String
    let sentAt: Date
    let embedInput: ChatBskyConvoDefs.MessageInputEmbedUnion?
    let unifiedEmbed: UnifiedEmbed?
    let replyTo: ChatBskyConvoDefs.ReplyRef?
    let replyContext: UnifiedMessageReplyContext?
    var sendState: MessageSendState
  }

  /// Sends one message and reports the server's MessageView before ChatManager
  /// updates its maps. The default is `ChatManager.sendMessage`; tests supply
  /// their own to control when each send finishes.
  typealias MessageSender = @MainActor (
    _ convoID: String,
    _ text: String,
    _ embed: ChatBskyConvoDefs.MessageInputEmbedUnion?,
    _ replyTo: ChatBskyConvoDefs.ReplyRef?,
    _ onConfirmed: @escaping (ChatBskyConvoDefs.MessageView) -> Void
  ) async -> Bool

  /// Prefix of the local ID an optimistic send carries until the server confirms it.
  static let pendingIDPrefix = "pending-"

  private(set) var messages: [BlueskyMessageAdapter] = []
  private(set) var pendingSends: [PendingBlueskySend] = []
  private var confirmedDiffableIDByMessageID: [String: String] = [:]
  private let messageSender: MessageSender
  /// The send queued last. Each send waits for the one queued before it, so
  /// messages reach the server in the order they were sent even when an earlier
  /// one takes longer before its POST (an @mention's handle lookup, say).
  @ObservationIgnored private var sendQueueTail: Task<Bool, Never>?
  private(set) var scrollToBottomTrigger: Int = 0
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

  init(
    chatManager: ChatManager,
    convoID: String,
    currentUserDID: String,
    appState: AppState? = nil,
    messageSender: MessageSender? = nil
  ) {
    self.chatManager = chatManager
    self.convoID = convoID
    self.currentUserDID = currentUserDID
    self.appState = appState
    self.messageSender = messageSender ?? { [chatManager] convoID, text, embed, replyTo, onConfirmed in
      await chatManager.sendMessage(
        convoId: convoID,
        text: text,
        embed: embed,
        replyTo: replyTo,
        onConfirmedMessage: onConfirmed
      )
    }
    updateMessagesFromManager()
    hasReceivedInitialMessages = false
    startObservingChatManager()
  }
  
  // MARK: - UnifiedChatDataSource

  func message(for id: String) -> BlueskyMessageAdapter? {
    messages.first { $0.diffableID == id || $0.id == id }
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
    let pendingID = beginPendingSend(
      text: trimmed,
      embedInput: embed,
      unifiedEmbed: Self.optimisticUnifiedEmbed(from: embed),
      replyTo: replyTo,
      replyContext: replyTo.flatMap { ref in
        message(for: ref.messageId).map { target in
          UnifiedMessageReplyContext(
            kind: .message(
              id: target.id,
              senderDID: target.senderID,
              senderDisplayName: target.senderDisplayName,
              text: target.text
            ),
            referencedMessageID: target.id,
            senderDisplayName: target.senderDisplayName,
            previewText: target.text,
            isTappable: true
          )
        }
      }
    )
    return await enqueueSend(id: pendingID).value
  }

  func submitDraft() {
    guard let submission = draft.beginSend() else { return }
    draft.finishSend(submission, succeeded: true)
    let pendingID = enqueuePendingDraft(submission.value)
    enqueueSend(id: pendingID)
  }

  func sendDraft(_ submission: MessageDraft<BlueskyConversationDraft>.Submission) async {
    draft.finishSend(submission, succeeded: true)
    let pendingID = enqueuePendingDraft(submission.value)
    _ = await enqueueSend(id: pendingID).value
  }

  /// Sends a failed message again. It goes to the back of the queue, after any
  /// message sent since it failed, and its row moves to the bottom with it.
  func retryFailedSend(pendingID: String) async {
    guard let index = pendingSends.firstIndex(where: { $0.id == pendingID }),
          case .failed = pendingSends[index].sendState else { return }
    var pending = pendingSends.remove(at: index)
    pending.sendState = .sending
    pendingSends.append(pending)
    updateMessagesFromManager()
    scrollToBottomTrigger &+= 1
    _ = await enqueueSend(id: pendingID).value
  }

  /// Queues `pendingID` behind every send already queued in this conversation.
  /// A send that fails does not hold back the ones queued after it: they still
  /// go out, and the failed row stays in the transcript with Retry, which
  /// queues it again at the back.
  ///
  /// Each queued send holds the data source strongly: only the conversation
  /// view's state owns it, so a send waiting behind another when the user
  /// leaves the conversation must keep it alive to go out at all. A finished
  /// task releases its captures, so the source is freed once the queue drains.
  @discardableResult
  private func enqueueSend(id pendingID: String) -> Task<Bool, Never> {
    let previous = sendQueueTail
    let send = Task { @MainActor [self] () -> Bool in
      _ = await previous?.value
      return await self.performPendingSend(id: pendingID)
    }
    sendQueueTail = send
    return send
  }

  @discardableResult
  private func enqueuePendingDraft(_ value: BlueskyConversationDraft) -> String {
    let embed: ChatBskyConvoDefs.MessageInputEmbedUnion?
    let unifiedEmbed: UnifiedEmbed?
    if value.attachedEmbed != nil, let postRef = value.postRef {
      embed = .appBskyEmbedRecord(AppBskyEmbedRecord(record: postRef))
      unifiedEmbed = .blueskyRecord(
        recordData: BlueskyRecordEmbedData(
          uri: postRef.uri.uriString(),
          cid: postRef.cid.string
        )
      )
    } else {
      embed = nil
      unifiedEmbed = nil
    }
    let reply = value.replyTarget.map { ChatBskyConvoDefs.ReplyRef(messageId: $0.id) }
    let replyContext = value.replyTarget.map { target in
      UnifiedMessageReplyContext(
        kind: .message(
          id: target.id,
          senderDID: target.senderID,
          senderDisplayName: target.senderDisplayName,
          text: target.text
        ),
        referencedMessageID: target.id,
        senderDisplayName: target.senderDisplayName,
        previewText: target.text,
        isTappable: true
      )
    }
    return beginPendingSend(
      text: value.text.trimmingCharacters(in: .whitespacesAndNewlines),
      embedInput: embed,
      unifiedEmbed: unifiedEmbed,
      replyTo: reply,
      replyContext: replyContext
    )
  }

  @discardableResult
  func beginPendingSend(
    text: String,
    embedInput: ChatBskyConvoDefs.MessageInputEmbedUnion? = nil,
    unifiedEmbed: UnifiedEmbed? = nil,
    replyTo: ChatBskyConvoDefs.ReplyRef? = nil,
    replyContext: UnifiedMessageReplyContext? = nil,
    sentAt: Date = Date()
  ) -> String {
    let pendingID = "\(Self.pendingIDPrefix)\(UUID().uuidString)"
    let pending = PendingBlueskySend(
      id: pendingID,
      text: text,
      sentAt: sentAt,
      embedInput: embedInput,
      unifiedEmbed: unifiedEmbed,
      replyTo: replyTo,
      replyContext: replyContext,
      sendState: .sending
    )
    pendingSends.append(pending)
    updateMessagesFromManager()
    scrollToBottomTrigger &+= 1
    return pendingID
  }

  func completePendingSend(id pendingID: String, realMessageID: String) {
    confirmedDiffableIDByMessageID[realMessageID] = pendingID
    pendingSends.removeAll { $0.id == pendingID }
  }

  func failPendingSend(id pendingID: String, reason: String = "Failed to send") {
    guard let index = pendingSends.firstIndex(where: { $0.id == pendingID }) else { return }
    pendingSends[index].sendState = .failed(reason)
    updateMessagesFromManager()
  }

  private func performPendingSend(id pendingID: String) async -> Bool {
    guard !Task.isCancelled,
          let pending = pendingSends.first(where: { $0.id == pendingID }) else { return false }
    error = nil
    let success = await messageSender(
      convoID,
      pending.text,
      pending.embedInput,
      serverReplyRef(for: pending.replyTo)
    ) { [weak self] messageView in
      self?.completePendingSend(id: pendingID, realMessageID: messageView.id)
    }
    if success {
      // Ensure any pending row is cleaned up if originalMessagesMap was already updated
      pendingSends.removeAll { $0.id == pendingID }
      updateMessagesFromManager()
    } else if !Task.isCancelled, pendingSends.contains(where: { $0.id == pendingID }) {
      failPendingSend(id: pendingID, reason: "Failed to send")
      self.error = NSError(domain: "ChatError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to send message"])
    }
    return success
  }

  /// The reply reference to send. A reply naming a local `pending-` ID names the
  /// server ID that send was confirmed under; one whose target was never
  /// confirmed has no server ID to name, so the message goes out without the
  /// reply rather than failing on every Retry.
  func serverReplyRef(for replyTo: ChatBskyConvoDefs.ReplyRef?) -> ChatBskyConvoDefs.ReplyRef? {
    guard let replyTo, replyTo.messageId.hasPrefix(Self.pendingIDPrefix) else { return replyTo }
    guard let serverID = confirmedDiffableIDByMessageID.first(where: { $0.value == replyTo.messageId })?.key
    else { return nil }
    return ChatBskyConvoDefs.ReplyRef(messageId: serverID)
  }

  private static func optimisticUnifiedEmbed(
    from embedInput: ChatBskyConvoDefs.MessageInputEmbedUnion?
  ) -> UnifiedEmbed? {
    guard case .appBskyEmbedRecord(let record)? = embedInput else { return nil }
    return .blueskyRecord(
      recordData: BlueskyRecordEmbedData(
        uri: record.record.uri.uriString(),
        cid: record.record.cid.string
      )
    )
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
    let target = message(for: messageID)
    // A send the server has not confirmed has no server ID to react to.
    if let target, !target.canReact { return }
    let realID = target?.id ?? messageID
    Task {
      do {
        try await chatManager.toggleReaction(convoId: convoID, messageId: realID, emoji: emoji)
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
    if let pending = pendingSends.first(where: { $0.id == messageID }) {
      // A send still queued or in flight may already have reached the server,
      // so removing its row would not stop the message; only a failed send,
      // which is neither, is discarded.
      guard case .failed = pending.sendState else { return }
      pendingSends.removeAll { $0.id == messageID }
      updateMessagesFromManager()
      return
    }
    let realID = message(for: messageID)?.id ?? messageID
    let success = await chatManager.deleteMessageForSelf(convoId: convoID, messageId: realID)
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

    // 1. Convert user messages to BlueskyMessageAdapter (preserving stable diffableID across pending→confirmed handover)
    let userAdapters = originalMessages.values.map { messageView in
      let senderDID = messageView.sender.did.didString()
      let profile = allProfiles[senderDID]
      let reactions = messageView.reactions ?? []
      let stableDiffableID = confirmedDiffableIDByMessageID[messageView.id]

      return BlueskyMessageAdapter(
        messageView: messageView,
        currentUserDID: currentUserDID,
        senderProfile: profile,
        reactions: reactions,
        diffableID: stableDiffableID,
        sendState: .sent
      )
    }

    // 1b. Convert optimistic pending/failed sends not yet confirmed in originalMessages
    let currentUserProfile = allProfiles[currentUserDID]
    let confirmedDiffableIDs = Set(originalMessages.keys.compactMap { confirmedDiffableIDByMessageID[$0] })
    let pendingAdapters = pendingSends
      .filter { !confirmedDiffableIDs.contains($0.id) }
      .map { pending in
        BlueskyMessageAdapter(
          pendingID: pending.id,
          text: pending.text,
          currentUserDID: currentUserDID,
          senderProfile: currentUserProfile,
          sentAt: pending.sentAt,
          sendState: pending.sendState,
          embed: pending.unifiedEmbed,
          replyContext: pending.replyContext
        )
      }

    // 2. Convert system messages to BlueskyMessageAdapter
    let systemAdapters = systemMessages.values.map { systemMessageView in
      BlueskyMessageAdapter(
        systemMessageView: systemMessageView,
        relatedProfiles: allProfiles
      )
    }

    // 3. Confirmed, system and failed rows sort chronologically by sentAt. Sends
    // still queued or in flight stay at the bottom in queue order, which is the
    // order the server will give them, whatever the device clock says.
    let inFlightAdapters = pendingAdapters.filter { $0.sendState == .sending }
    let settledPendingAdapters = pendingAdapters.filter { $0.sendState != .sending }
    let combined = (userAdapters + settledPendingAdapters + systemAdapters)
      .sorted { $0.sentAt < $1.sentAt } + inFlightAdapters

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
