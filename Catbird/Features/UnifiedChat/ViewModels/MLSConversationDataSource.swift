import Foundation
import OSLog
import Petrel
import SwiftUI
import CatbirdMLSCore
import GRDB

/// Data source that provides MLS messages for the unified chat UI
/// Pulls messages from MLSStorage and provides them as MLSMessageAdapter objects
@MainActor
@Observable
final class MLSConversationDataSource: UnifiedChatDataSource {
  typealias Message = MLSMessageAdapter

  // MARK: - Properties

  private let conversationId: String
  private let currentUserDID: String
  private weak var appState: AppState?

  // Profile cache for display names/avatars
  private var profileCache: [String: MLSProfileEnricher.ProfileData] = [:]
  
  // Member cache for fallback display names (from database)
  private var memberCache: [String: (handle: String?, displayName: String?)] = [:]

  // Flag to track if initial profiles have been loaded
  private var hasLoadedInitialProfiles: Bool = false

  private(set) var messages: [MLSMessageAdapter] = []
  private(set) var isLoading: Bool = false
  private(set) var hasMoreMessages: Bool = true
  private(set) var error: Error?
  private(set) var showsTypingIndicator: Bool = false
  private(set) var typingParticipantAvatarURL: URL?
  private(set) var scrollToBottomTrigger: Int = 0

  var draftText: String = ""
  var attachedEmbed: MLSEmbedData?

  // Local reactions cache for optimistic updates
  private var localReactions: [String: [MLSMessageReaction]] = [:]
  private var reactionReloadTask: Task<Void, Never>?
  private var messageObservation: AnyDatabaseCancellable?
  private weak var observedDatabase: DatabasePool?
  private var typingParticipants: [String: Date] = [:]
  private var typingCleanupTask: Task<Void, Never>?
  private var localTypingActive: Bool = false
  private var localTypingStopTask: Task<Void, Never>?

  // Pagination tracking
  private var oldestLoadedEpoch: Int = Int.max
  private var oldestLoadedSeq: Int = Int.max
  private var remoteReadCutoff: (epoch: Int64, sequenceNumber: Int64)?

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSConversationDataSource")

  // MARK: - Plaintext Parsing

  /// Parse cached plaintext and extract display text for the message list.
  /// Parses JSON payloads to extract text content and detect control messages.
  /// - Returns: A tuple of (displayText, isControlMessage) or nil if parsing fails
  private func parseDisplayText(from plaintext: String) -> (text: String, isControlMessage: Bool)?
  {
    // Check for legacy control message sentinel format
    // These are stored by cacheControlMessageEnvelope and should not be displayed
    if plaintext.hasPrefix("[control:") {
      return (plaintext, true)
    }

    // Try parsing as JSON payload
    if plaintext.hasPrefix("{"),
      let data = plaintext.data(using: .utf8),
      let payload = try? MLSMessagePayload.decodeFromJSON(data)
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

  // MARK: - Init

  init(conversationId: String, currentUserDID: String, appState: AppState?) {
    self.conversationId = conversationId
    self.currentUserDID = MLSStorageHelpers.normalizeDID(currentUserDID)
    self.appState = appState
  }

  // MARK: - Observation

  /// Start observing the MLS messages table via GRDB ValueObservation.
  /// The first emission is synchronous (scheduling: .immediate), so cached
  /// messages appear on the very first frame.
  private func startObserving(database: DatabasePool) {
    // Guard against re-observing the same database instance
    guard observedDatabase !== database else { return }
    stopObserving()

    let convoId = conversationId
    let userDID = currentUserDID

    let observation = ValueObservation.tracking { db in
      try MLSMessageModel
        .filter(MLSMessageModel.Columns.conversationID == convoId)
        .filter(MLSMessageModel.Columns.currentUserDID == userDID)
        .filter(MLSMessageModel.Columns.payloadExpired == false)
        .order(MLSMessageModel.Columns.epoch.asc, MLSMessageModel.Columns.sequenceNumber.asc)
        .fetchAll(db)
    }

    messageObservation = observation.start(
      in: database,
      scheduling: .immediate,
      onError: { [weak self] error in
        self?.logger.error("ValueObservation error: \(error.localizedDescription)")
      },
      onChange: { [weak self] models in
        Task { @MainActor [weak self] in
          await self?.handleObservedModels(models)
        }
      }
    )
    observedDatabase = database
  }

  /// Stop the current database observation and release references.
  func stopObserving() {
    messageObservation?.cancel()
    messageObservation = nil
    observedDatabase = nil
  }

  /// Core conversion logic: turns raw `MLSMessageModel` rows into
  /// `MLSMessageAdapter` values and updates the published `messages` array.
  private func handleObservedModels(_ models: [MLSMessageModel]) async {
    guard let appState = appState,
      let database = appState.mlsDatabase
    else { return }

    let storage = MLSStorage.shared

    // Seed member cache from DB if empty
    if memberCache.isEmpty {
      do {
        let members = try await storage.fetchMembers(
          conversationID: conversationId,
          currentUserDID: currentUserDID,
          database: database
        )
        for member in members {
          memberCache[MLSProfileEnricher.canonicalDID(member.did)] = (
            handle: member.handle,
            displayName: member.displayName
          )
        }
        logger.debug("Loaded \(members.count) members from database for fallback names")
      } catch {
        logger.error("Failed to load members: \(error.localizedDescription)")
      }
    }

    // Seed profile cache from the enricher
    let enricher = appState.mlsProfileEnricher
    let memberDIDs = Array(memberCache.keys)
    let enricherProfiles = await enricher.getCachedProfiles(for: memberDIDs)
    for (canonical, profile) in enricherProfiles {
      if profileCache[canonical] == nil || profileCache[canonical]?.avatarURL == nil {
        profileCache[canonical] = profile
      }
    }

    // Load remote read cursors
    let remoteReadCursors: [MLSRemoteReadCursorModel]
    do {
      remoteReadCursors = try await storage.fetchRemoteReadCursors(
        conversationID: conversationId,
        currentUserDID: currentUserDID,
        database: database
      )
    } catch {
      remoteReadCursors = []
      logger.error("Failed to load remote read cursors: \(error.localizedDescription)")
    }

    var messageCoordinatesByID: [String: (epoch: Int64, sequenceNumber: Int64)] = [:]
    for model in models {
      messageCoordinatesByID[model.messageID] = (model.epoch, model.sequenceNumber)
    }
    remoteReadCutoff = resolveRemoteReadCutoff(
      from: remoteReadCursors,
      coordinatesByMessageID: messageCoordinatesByID
    )

    // Load cached reactions
    let messageIDs = models.map(\.messageID)
    await loadCachedReactions(
      for: messageIDs,
      database: database,
      replaceExisting: true,
      refreshMessages: false
    )

    // Convert models to adapters
    var adapters: [MLSMessageAdapter] = []
    var unknownDIDs: Set<String> = []

    for model in models {
      guard let payload = model.parsedPayload, !model.payloadExpired else {
        continue
      }

      // Skip control messages (reactions, etc.) but allow text and system messages
      guard payload.messageType == .text || payload.messageType == .system else {
        continue
      }

      // SAFETY: Skip placeholder error messages that shouldn't be displayed
      let text = payload.text ?? ""
      let isPlaceholderError =
        model.processingError != nil
        && (text.isEmpty || text.contains("Message unavailable")
          || text.contains("Decryption Failed") || text.contains("Self-sent message"))
      if isPlaceholderError {
        logger.debug("Skipping placeholder error message: \(model.messageID)")
        continue
      }

      // Map system message content keys to display text
      let displayText: String
      if payload.messageType == .system {
        switch text {
        case "history_boundary.new_member":
          displayText = "You joined this conversation"
        case "history_boundary.device_rejoined":
          displayText = "Messages before this point aren't available on this device"
        default:
          displayText = text
        }
      } else {
        displayText = text
      }

      let canonicalSenderDID = MLSProfileEnricher.canonicalDID(model.senderID)
      let profile = profileCache[canonicalSenderDID]

      // SAFETY: Don't attach reactions to messages with processing errors
      let hasError = model.processingError != nil || model.validationFailureReason != nil
      let reactions = hasError ? [] : (localReactions[model.messageID] ?? [])

      // Build profile data with fallbacks
      let senderProfile: MLSMessageAdapter.MLSProfileData?
      if let profile = profile {
        senderProfile = .init(
          displayName: profile.displayName,
          avatarURL: profile.avatarURL,
          handle: profile.handle
        )
      } else if let memberData = memberCache[canonicalSenderDID],
        (memberData.handle != nil || memberData.displayName != nil)
      {
        senderProfile = .init(
          displayName: memberData.displayName,
          avatarURL: nil,
          handle: memberData.handle
        )
      } else {
        senderProfile = nil
        unknownDIDs.insert(canonicalSenderDID)
      }

      // Determine send state
      let isFromCurrentUser = MLSStorageHelpers.normalizeDID(model.senderID) == currentUserDID
      let sendState: MessageSendState =
        (
          isFromCurrentUser
            && isReadByRemoteParticipant(
              epoch: Int(model.epoch),
              sequenceNumber: Int(model.sequenceNumber),
              cutoff: remoteReadCutoff
            )
        ) ? .read : .sent

      let adapter = MLSMessageAdapter(
        id: model.messageID,
        convoID: conversationId,
        text: displayText,
        senderDID: model.senderID,
        currentUserDID: currentUserDID,
        sentAt: model.timestamp,
        senderProfile: senderProfile,
        reactions: reactions,
        embed: payload.embed,
        sendState: sendState,
        epoch: Int(model.epoch),
        sequence: Int(model.sequenceNumber),
        processingError: model.processingError,
        processingAttempts: Int(model.processingAttempts),
        validationFailureReason: model.validationFailureReason
      )
      adapters.append(adapter)

      // Track oldest for pagination
      let epoch = Int(model.epoch)
      let seq = Int(model.sequenceNumber)
      if epoch < oldestLoadedEpoch || (epoch == oldestLoadedEpoch && seq < oldestLoadedSeq) {
        oldestLoadedEpoch = epoch
        oldestLoadedSeq = seq
      }
    }

    sortMessagesInDisplayOrder(&adapters)

    // Clear typing indicators for senders who just sent a message
    // Also detect new incoming messages for haptic feedback
    let existingIDs = Set(messages.map { $0.id })
    let isInitialLoad = messages.isEmpty && !adapters.isEmpty
    var hasNewIncomingMessage = false
    for adapter in adapters where !existingIDs.contains(adapter.id) {
      clearTypingForSender(adapter.senderID)
      if !isInitialLoad && !adapter.isFromCurrentUser {
        hasNewIncomingMessage = true
      }
    }
    if hasNewIncomingMessage {
      PlatformHaptics.light()
    }

    self.messages = adapters
    self.hasMoreMessages = models.count >= 50
    applyRemoteReadCutoffToLoadedMessages()
    scheduleDelayedReactionReload(messageIDs: messageIDs, database: database)

    // Fetch profiles for unknown senders
    if !unknownDIDs.isEmpty {
      logger.debug("Fetching profiles for \(unknownDIDs.count) unknown sender DIDs")
      await loadProfilesForMessages(adapters)
    } else if !hasLoadedInitialProfiles {
      await loadProfilesForMessages(adapters)
      hasLoadedInitialProfiles = true
    }

    logger.info("Loaded \(adapters.count) MLS messages via observation")
  }

  private func shouldAdvanceRemoteReadCutoff(
    existing: (epoch: Int64, sequenceNumber: Int64)?,
    candidate: (epoch: Int64, sequenceNumber: Int64)
  ) -> Bool {
    guard let existing else { return true }
    if candidate.epoch != existing.epoch {
      return candidate.epoch > existing.epoch
    }
    return candidate.sequenceNumber > existing.sequenceNumber
  }

  private func resolveRemoteReadCutoff(
    from cursors: [MLSRemoteReadCursorModel],
    coordinatesByMessageID: [String: (epoch: Int64, sequenceNumber: Int64)]
  ) -> (epoch: Int64, sequenceNumber: Int64)? {
    var best: (epoch: Int64, sequenceNumber: Int64)?

    for cursor in cursors {
      let candidate: (epoch: Int64, sequenceNumber: Int64)?
      if let epoch = cursor.epoch, let sequenceNumber = cursor.sequenceNumber {
        candidate = (epoch, sequenceNumber)
      } else if
        let messageID = cursor.messageID,
        let resolved = coordinatesByMessageID[messageID]
      {
        candidate = resolved
      } else {
        candidate = nil
      }

      guard let candidate else { continue }
      if shouldAdvanceRemoteReadCutoff(existing: best, candidate: candidate) {
        best = candidate
      }
    }

    return best
  }

  private func isReadByRemoteParticipant(
    epoch: Int?,
    sequenceNumber: Int?,
    cutoff: (epoch: Int64, sequenceNumber: Int64)?
  ) -> Bool {
    guard let cutoff, let epoch, let sequenceNumber else { return false }
    let epochValue = Int64(epoch)
    let sequenceValue = Int64(sequenceNumber)
    return epochValue < cutoff.epoch
      || (epochValue == cutoff.epoch && sequenceValue <= cutoff.sequenceNumber)
  }

  private func updateSendState(
    for adapter: MLSMessageAdapter,
    sendState: MessageSendState
  ) -> MLSMessageAdapter {
    MLSMessageAdapter(
      id: adapter.id,
      convoID: adapter.mlsConversationID,
      text: adapter.text,
      senderDID: adapter.senderID,
      currentUserDID: currentUserDID,
      sentAt: adapter.sentAt,
      senderProfile: adapter.mlsProfile,
      reactions: localReactions[adapter.id] ?? [],
      embed: adapter.mlsEmbed,
      sendState: sendState,
      epoch: adapter.mlsEpoch,
      sequence: adapter.mlsSequence,
      processingError: adapter.processingError,
      processingAttempts: adapter.processingAttempts,
      validationFailureReason: adapter.validationFailureReason
    )
  }

  private func applyRemoteReadCutoffToLoadedMessages() {
    guard let cutoff = remoteReadCutoff else { return }

    var didUpdate = false
    messages = messages.map { adapter in
      guard adapter.isFromCurrentUser else { return adapter }
      let shouldBeRead = isReadByRemoteParticipant(
        epoch: adapter.mlsEpoch,
        sequenceNumber: adapter.mlsSequence,
        cutoff: cutoff
      )
      guard shouldBeRead, adapter.sendState != .read else { return adapter }
      didUpdate = true
      return updateSendState(for: adapter, sendState: .read)
    }

    if didUpdate {
      logger.info("📬 [READ_RECEIPTS] Applied persisted remote read cutoff to loaded messages")
    }
  }

  /// Preload profiles for known participants before loading messages
  /// Call this with participant data from the conversation list to avoid blank names
  func preloadProfiles(_ profiles: [String: MLSProfileEnricher.ProfileData]) {
    var profilesChanged = false
    for (did, profile) in profiles {
      let canonical = MLSProfileEnricher.canonicalDID(did)
      let existing = profileCache[canonical]
      // Insert if missing, or upgrade if new profile has avatar and existing doesn't
      if existing == nil || (existing?.avatarURL == nil && profile.avatarURL != nil) {
        profileCache[canonical] = profile
        profilesChanged = true
      }
    }
    if !profiles.isEmpty {
      hasLoadedInitialProfiles = true
      logger.debug("Preloaded \(profiles.count) profiles for conversation \(self.conversationId)")

      // If messages are already loaded, rebuild them with the new profile data
      if profilesChanged && !messages.isEmpty {
        rebuildMessagesWithProfiles()
      }
    }
  }

  /// Rebuild all messages with current profile cache data
  private func rebuildMessagesWithProfiles() {
    messages = messages.map { adapter in
      let canonicalSenderDID = MLSProfileEnricher.canonicalDID(adapter.senderID)

      // Try profile cache first, then member cache
      let senderProfile: MLSMessageAdapter.MLSProfileData?
      if let profile = profileCache[canonicalSenderDID] {
        senderProfile = .init(
          displayName: profile.displayName,
          avatarURL: profile.avatarURL,
          handle: profile.handle
        )
      } else if let memberData = memberCache[canonicalSenderDID],
        (memberData.handle != nil || memberData.displayName != nil)
      {
        senderProfile = .init(
          displayName: memberData.displayName,
          avatarURL: nil,
          handle: memberData.handle
        )
      } else {
        senderProfile = adapter.mlsProfile
      }

      return MLSMessageAdapter(
        id: adapter.id,
        convoID: adapter.mlsConversationID,
        text: adapter.text,
        senderDID: adapter.senderID,
        currentUserDID: currentUserDID,
        sentAt: adapter.sentAt,
        senderProfile: senderProfile,
        reactions: localReactions[adapter.id] ?? [],
        embed: adapter.mlsEmbed,
        sendState: adapter.sendState,
        epoch: adapter.mlsEpoch,
        sequence: adapter.mlsSequence,
        processingError: adapter.processingError,
        processingAttempts: adapter.processingAttempts,
        validationFailureReason: adapter.validationFailureReason
      )
    }
    logger.debug("Rebuilt \(self.messages.count) messages with updated profile data")
  }

  private func adoptOrphanedReactionsIfNeeded(
    messageIDs: Set<String>,
    database: MLSDatabase
  ) async -> Bool {
    let storage = MLSStorage.shared

    do {
      let orphanStats = try await storage.fetchOrphanedReactionStats(
        for: conversationId,
        currentUserDID: currentUserDID,
        limit: 50,
        database: database
      )

      guard !orphanStats.isEmpty else { return false }

      logger.info(
        "[ORPHAN-UI] Found \(orphanStats.count) orphaned reaction parent(s) for \(self.conversationId.prefix(16))"
      )

      var adoptedAny = false
      for (messageID, _) in orphanStats {
        guard messageIDs.contains(messageID) else { continue }
        _ = try await storage.adoptOrphansForMessage(
          messageID,
          currentUserDID: currentUserDID,
          database: database
        )
        adoptedAny = true
      }
      return adoptedAny
    } catch {
      logger.error("Failed to adopt orphaned reactions: \(error.localizedDescription)")
    }
    return false
  }

  private func mergeCachedReactions(
    _ cachedReactions: [String: [MLSReactionModel]],
    replaceExisting: Bool
  ) -> Bool {
    var didUpdate = false

    for (messageId, models) in cachedReactions {
      var seen = Set<String>()
      let reactions = models.compactMap { model -> MLSMessageReaction? in
        let key = "\(model.actorDID)|\(model.emoji)"
        guard seen.insert(key).inserted else { return nil }
        return MLSMessageReaction(
          messageId: model.messageID,
          reaction: model.emoji,
          senderDID: model.actorDID,
          reactedAt: model.timestamp
        )
      }

      if replaceExisting {
        if reactions.isEmpty {
          if localReactions.removeValue(forKey: messageId) != nil {
            didUpdate = true
          }
        } else if localReactions[messageId] != reactions {
          localReactions[messageId] = reactions
          didUpdate = true
        }
      } else {
        if reactions.isEmpty {
          continue
        }
        if localReactions[messageId] == nil {
          localReactions[messageId] = reactions
          didUpdate = true
        } else {
          var existing = localReactions[messageId] ?? []
          let existingKeys = Set(existing.map { "\($0.senderDID)|\($0.reaction)" })
          for reaction in reactions {
            let key = "\(reaction.senderDID)|\(reaction.reaction)"
            if !existingKeys.contains(key) {
              existing.append(reaction)
              didUpdate = true
            }
          }
          localReactions[messageId] = existing
        }
      }
    }

    return didUpdate
  }

  private func rebuildMessagesWithReactions() {
    messages = messages.map { adapter in
      // SAFETY: Don't attach reactions to undecryptable/error messages
      let reactionsToShow =
        adapter.isDecryptedAndValid
        ? (localReactions[adapter.id] ?? [])
        : []
      return MLSMessageAdapter(
        id: adapter.id,
        convoID: adapter.mlsConversationID,
        text: adapter.text,
        senderDID: adapter.senderID,
        currentUserDID: currentUserDID,
        sentAt: adapter.sentAt,
        senderProfile: adapter.mlsProfile,
        reactions: reactionsToShow,
        embed: adapter.mlsEmbed,
        sendState: adapter.sendState,
        epoch: adapter.mlsEpoch,
        sequence: adapter.mlsSequence,
        processingError: adapter.processingError,
        processingAttempts: adapter.processingAttempts,
        validationFailureReason: adapter.validationFailureReason
      )
    }
  }

  private func loadCachedReactions(
    for messageIDs: [String],
    database: MLSDatabase,
    replaceExisting: Bool,
    refreshMessages: Bool
  ) async {
    guard !messageIDs.isEmpty else { return }

    let storage = MLSStorage.shared
    let messageIDSet = Set(messageIDs)
    _ = await adoptOrphanedReactionsIfNeeded(messageIDs: messageIDSet, database: database)

    let maxRetries = 3
    var lastError: Error?

    for attempt in 1...maxRetries {
      do {
        let cachedReactions = try await storage.fetchReactionsForMessages(
          messageIDs,
          currentUserDID: currentUserDID,
          database: database
        )

        if refreshMessages,
          mergeCachedReactions(cachedReactions, replaceExisting: replaceExisting)
        {
          rebuildMessagesWithReactions()
        } else {
          _ = mergeCachedReactions(cachedReactions, replaceExisting: replaceExisting)
        }
        return
      } catch {
        lastError = error
        let desc = error.localizedDescription
        let isRetryable =
          desc.contains("out of memory") || desc.contains("busy") || desc.contains("locked")
          || desc.contains("error 7") || desc.contains("error 5") || desc.contains("error 6")

        if isRetryable && attempt < maxRetries {
          logger.warning("⚠️ [REACTION-FETCH] Transient error (attempt \(attempt)): \(desc)")
          try? await Task.sleep(nanoseconds: UInt64(50 * attempt) * 1_000_000)
          continue
        }
        break
      }
    }

    if let error = lastError {
      logger.error("Failed to load cached reactions after retries: \(error.localizedDescription)")
    }
  }

  private func scheduleDelayedReactionReload(messageIDs: [String], database: MLSDatabase) {
    reactionReloadTask?.cancel()
    guard !messageIDs.isEmpty else { return }
    reactionReloadTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard let self, !Task.isCancelled else { return }
      await self.loadCachedReactions(
        for: messageIDs,
        database: database,
        replaceExisting: false,
        refreshMessages: true
      )
    }
  }

  // MARK: - UnifiedChatDataSource

  func message(for id: String) -> MLSMessageAdapter? {
    messages.first { $0.id == id }
  }

  func loadMessages() async {
    guard let appState = appState,
      let database = appState.mlsDatabase
    else {
      logger.error("Cannot load messages: database not available")
      return
    }
    startObserving(database: database)
  }

  func loadMoreMessages() async {
    guard !isLoading, hasMoreMessages else { return }
    isLoading = true

    defer { isLoading = false }

    guard let appState = appState,
      let database = appState.mlsDatabase
    else {
      return
    }

    do {
      let storage = MLSStorage.shared
      let olderModels = try await storage.fetchMessagesBeforeSequence(
        conversationId: conversationId,
        currentUserDID: currentUserDID,
        beforeEpoch: Int64(oldestLoadedEpoch),
        beforeSeq: Int64(oldestLoadedSeq),
        database: database,
        limit: 50
      )

      guard !olderModels.isEmpty else {
        hasMoreMessages = false
        return
      }

      let messageIDs = olderModels.map(\.messageID)
      await loadCachedReactions(
        for: messageIDs,
        database: database,
        replaceExisting: false,
        refreshMessages: false
      )

      let remoteReadCursors = try await storage.fetchRemoteReadCursors(
        conversationID: conversationId,
        currentUserDID: currentUserDID,
        database: database
      )

      var messageCoordinatesByID: [String: (epoch: Int64, sequenceNumber: Int64)] = [:]
      for adapter in messages {
        if let epoch = adapter.mlsEpoch, let sequenceNumber = adapter.mlsSequence {
          messageCoordinatesByID[adapter.id] = (Int64(epoch), Int64(sequenceNumber))
        }
      }
      for model in olderModels {
        messageCoordinatesByID[model.messageID] = (model.epoch, model.sequenceNumber)
      }
      if let resolvedCutoff = resolveRemoteReadCutoff(
        from: remoteReadCursors,
        coordinatesByMessageID: messageCoordinatesByID
      ), shouldAdvanceRemoteReadCutoff(existing: remoteReadCutoff, candidate: resolvedCutoff) {
        remoteReadCutoff = resolvedCutoff
      }

      var adapters: [MLSMessageAdapter] = []
      var unknownDIDs: Set<String> = []

      for model in olderModels {
        guard let payload = model.parsedPayload, !model.payloadExpired else {
          continue
        }

        // Skip control messages (reactions, etc.) but allow text and system messages
        guard payload.messageType == .text || payload.messageType == .system else {
          continue
        }

        // SAFETY: Skip placeholder error messages (same as loadMessages)
        let text = payload.text ?? ""
        let isPlaceholderError =
          model.processingError != nil
          && (text.isEmpty || text.contains("Message unavailable")
            || text.contains("Decryption Failed") || text.contains("Self-sent message"))
        if isPlaceholderError {
          logger.debug("Skipping placeholder error message in pagination: \(model.messageID)")
          continue
        }

        // Map system message content keys to display text
        let displayText: String
        if payload.messageType == .system {
          switch text {
          case "history_boundary.new_member":
            displayText = "You joined this conversation"
          case "history_boundary.device_rejoined":
            displayText = "Messages before this point aren't available on this device"
          default:
            displayText = text
          }
        } else {
          displayText = text
        }

        let canonicalSenderDID = MLSProfileEnricher.canonicalDID(model.senderID)
        let profile = profileCache[canonicalSenderDID]
        
        // SAFETY: Don't attach reactions to messages with processing errors
        let hasError = model.processingError != nil || model.validationFailureReason != nil
        let reactions = hasError ? [] : (localReactions[model.messageID] ?? [])

        // Build profile data with fallbacks (same as loadMessages)
        let senderProfile: MLSMessageAdapter.MLSProfileData?
        if let profile = profile {
          senderProfile = .init(
            displayName: profile.displayName,
            avatarURL: profile.avatarURL,
            handle: profile.handle
          )
        } else if let memberData = memberCache[canonicalSenderDID],
          (memberData.handle != nil || memberData.displayName != nil)
        {
          senderProfile = .init(
            displayName: memberData.displayName,
            avatarURL: nil,
            handle: memberData.handle
          )
        } else {
          senderProfile = nil
          unknownDIDs.insert(canonicalSenderDID)
        }

        let adapter = MLSMessageAdapter(
          id: model.messageID,
          convoID: conversationId,
          text: displayText,
          senderDID: model.senderID,
          currentUserDID: currentUserDID,
          sentAt: model.timestamp,
          senderProfile: senderProfile,
          reactions: reactions,
          embed: payload.embed,
          sendState: (
            MLSStorageHelpers.normalizeDID(model.senderID) == currentUserDID
              && isReadByRemoteParticipant(
                epoch: Int(model.epoch),
                sequenceNumber: Int(model.sequenceNumber),
                cutoff: remoteReadCutoff
              )
          ) ? .read : .sent,
          epoch: Int(model.epoch),
          sequence: Int(model.sequenceNumber),
          processingError: model.processingError,
          processingAttempts: Int(model.processingAttempts),
          validationFailureReason: model.validationFailureReason
        )
        adapters.append(adapter)

        // Update oldest
        let epoch = Int(model.epoch)
        let seq = Int(model.sequenceNumber)
        if epoch < oldestLoadedEpoch || (epoch == oldestLoadedEpoch && seq < oldestLoadedSeq) {
          oldestLoadedEpoch = epoch
          oldestLoadedSeq = seq
        }
      }

      // Prepend older messages, deduplicating against existing
      let existingIDs = Set(messages.map { $0.id })
      let uniqueAdapters = adapters.filter { !existingIDs.contains($0.id) }
      self.messages = uniqueAdapters + self.messages
      sortMessagesInDisplayOrder(&self.messages)
      applyRemoteReadCutoffToLoadedMessages()
      // Stop paginating if no displayable messages were found (all errors/placeholders)
      self.hasMoreMessages = olderModels.count >= 50 && !adapters.isEmpty

      // Only fetch profiles for unknown DIDs
      if !unknownDIDs.isEmpty {
        await loadProfilesForMessages(adapters)
      }

      logger.info("Loaded \(adapters.count) older MLS messages")

    } catch {
      self.error = error
      logger.error("Failed to load more MLS messages: \(error.localizedDescription)")
    }
  }

  func handleComposerTextChanged(_ text: String) {
    let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    if !hasText {
      stopLocalTypingIndicatorIfNeeded()
      return
    }

    localTypingStopTask?.cancel()

    if !localTypingActive {
      localTypingActive = true
      Task { [weak self] in
        await self?.sendTypingIndicator(isTyping: true)
      }
    }

    localTypingStopTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      guard let self, !Task.isCancelled, self.localTypingActive else { return }
      self.localTypingActive = false
      await self.sendTypingIndicator(isTyping: false)
    }
  }

  func stopLocalTypingIndicatorIfNeeded() {
    localTypingStopTask?.cancel()
    localTypingStopTask = nil

    guard localTypingActive else { return }
    localTypingActive = false
    Task { [weak self] in
      await self?.sendTypingIndicator(isTyping: false)
    }
  }

  func applyTypingEvent(participantID: String, isTyping: Bool) {
    let normalizedParticipantID = MLSStorageHelpers.normalizeDID(participantID)
    guard normalizedParticipantID != currentUserDID else { return }

    if isTyping {
      typingParticipants[normalizedParticipantID] = Date().addingTimeInterval(4)
    } else {
      typingParticipants.removeValue(forKey: normalizedParticipantID)
    }

    refreshTypingIndicatorState()
    scheduleTypingCleanup()
  }

  private func refreshTypingIndicatorState(now: Date = Date()) {
    typingParticipants = typingParticipants.filter { $0.value > now }
    showsTypingIndicator = !typingParticipants.isEmpty
    if let firstTypingDID = typingParticipants.keys.first {
      typingParticipantAvatarURL = profileCache[MLSProfileEnricher.canonicalDID(firstTypingDID)]?.avatarURL
    } else {
      typingParticipantAvatarURL = nil
    }
  }

  /// Clear typing indicator for a sender when their message arrives
  func clearTypingForSender(_ did: String) {
    let normalized = MLSStorageHelpers.normalizeDID(did)
    guard typingParticipants.removeValue(forKey: normalized) != nil else { return }
    refreshTypingIndicatorState()
  }

  private func scheduleTypingCleanup() {
    typingCleanupTask?.cancel()
    guard !typingParticipants.isEmpty else { return }

    typingCleanupTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        self.refreshTypingIndicatorState()
        if self.typingParticipants.isEmpty {
          break
        }
      }
    }
  }

  private func sendTypingIndicator(isTyping: Bool) async {
    guard let appState = appState,
      let manager = await appState.getMLSConversationManager()
    else {
      return
    }

    do {
      try await manager.sendTypingIndicator(convoId: conversationId, isTyping: isTyping)
    } catch {
      logger.debug("Typing indicator send failed: \(error.localizedDescription)")
    }
  }

  func sendMessage(text: String) async {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedEmbed != nil
    else { return }

    stopLocalTypingIndicatorIfNeeded()

    guard let appState = appState,
      let manager = await appState.getMLSConversationManager()
    else {
      error = NSError(
        domain: "MLS", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "MLS service not available"])
      return
    }

    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let embed = attachedEmbed

    // Clear draft immediately for better UX
    draftText = ""
    attachedEmbed = nil

    do {
      let (messageId, receivedAt, seq, epoch) = try await manager.sendMessage(
        convoId: conversationId,
        plaintext: trimmedText,
        embed: embed
      )

      // Create adapter for the sent message
      let profile = profileCache[MLSProfileEnricher.canonicalDID(currentUserDID)]
      let adapter = MLSMessageAdapter(
        id: messageId,
        convoID: conversationId,
        text: trimmedText,
        senderDID: currentUserDID,
        currentUserDID: currentUserDID,
        sentAt: receivedAt.date,
        senderProfile: profile.map {
          .init(displayName: $0.displayName, avatarURL: $0.avatarURL, handle: $0.handle)
        },
        reactions: [],
        embed: embed,
        sendState: .sent,
        epoch: Int(epoch),
        sequence: Int(seq)
      )

      if let existingIndex = messages.firstIndex(where: { $0.id == messageId }) {
        messages[existingIndex] = adapter
      } else {
        messages.append(adapter)
      }
      sortMessagesInDisplayOrder(&messages)
      scrollToBottomTrigger += 1

      logger.info("Sent MLS message: \(messageId)")

    } catch {
      self.error = error
      logger.error("Failed to send MLS message: \(error.localizedDescription)")
    }
  }

  func toggleReaction(messageID: String, emoji: String) {
    Task {
      guard let appState = appState,
        let manager = await appState.getMLSConversationManager()
      else {
        return
      }

      do {
        let currentReactions = localReactions[messageID] ?? []
        let hasReaction = currentReactions.contains {
          $0.reaction == emoji && $0.senderDID == currentUserDID
        }

        if hasReaction {
          _ = try await manager.removeReaction(
            convoId: conversationId,
            messageId: messageID,
            reaction: emoji
          )
          let updated = currentReactions.filter {
            !($0.reaction == emoji && $0.senderDID == currentUserDID)
          }
          if updated.isEmpty {
            localReactions.removeValue(forKey: messageID)
          } else {
            localReactions[messageID] = updated
          }
        } else {
          let result = try await manager.addReaction(
            convoId: conversationId,
            messageId: messageID,
            reaction: emoji
          )
          let newReaction = MLSMessageReaction(
            messageId: messageID,
            reaction: emoji,
            senderDID: currentUserDID,
            reactedAt: result.reactedAt ?? Date()
          )
          var updated = currentReactions
          updated.append(newReaction)
          localReactions[messageID] = updated
        }

        // Update the message adapter's reactions
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
          let oldAdapter = messages[index]
          let newAdapter = MLSMessageAdapter(
            id: oldAdapter.id,
            convoID: oldAdapter.mlsConversationID,
            text: oldAdapter.text,
            senderDID: oldAdapter.senderID,
            currentUserDID: currentUserDID,
            sentAt: oldAdapter.sentAt,
            senderProfile: oldAdapter.mlsProfile,
            reactions: localReactions[messageID] ?? [],
            embed: oldAdapter.mlsEmbed,
            sendState: oldAdapter.sendState,
            epoch: oldAdapter.mlsEpoch,
            sequence: oldAdapter.mlsSequence,
            processingError: oldAdapter.processingError,
            processingAttempts: oldAdapter.processingAttempts,
            validationFailureReason: oldAdapter.validationFailureReason
          )
          messages[index] = newAdapter
        }

      } catch {
        self.error = error
        logger.error("Failed to toggle reaction: \(error.localizedDescription)")
      }
    }
  }

  func addReaction(messageID: String, emoji: String) {
    // For MLS, addReaction always adds (doesn't toggle)
    Task {
      guard let appState = appState,
        let manager = await appState.getMLSConversationManager()
      else {
        return
      }

      do {
        let currentReactions = localReactions[messageID] ?? []

        // Only add if not already reacted with this emoji
        let hasReaction = currentReactions.contains {
          $0.reaction == emoji && $0.senderDID == currentUserDID
        }

        guard !hasReaction else {
          logger.debug("Already reacted with \(emoji) on \(messageID)")
          return
        }

        let result = try await manager.addReaction(
          convoId: conversationId,
          messageId: messageID,
          reaction: emoji
        )

        let newReaction = MLSMessageReaction(
          messageId: messageID,
          reaction: emoji,
          senderDID: currentUserDID,
          reactedAt: result.reactedAt ?? Date()
        )
        var updated = currentReactions
        updated.append(newReaction)
        localReactions[messageID] = updated

        // Update the message adapter's reactions
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
          let oldAdapter = messages[index]
          let newAdapter = MLSMessageAdapter(
            id: oldAdapter.id,
            convoID: oldAdapter.mlsConversationID,
            text: oldAdapter.text,
            senderDID: oldAdapter.senderID,
            currentUserDID: currentUserDID,
            sentAt: oldAdapter.sentAt,
            senderProfile: oldAdapter.mlsProfile,
            reactions: localReactions[messageID] ?? [],
            embed: oldAdapter.mlsEmbed,
            sendState: oldAdapter.sendState,
            epoch: oldAdapter.mlsEpoch,
            sequence: oldAdapter.mlsSequence,
            processingError: oldAdapter.processingError,
            processingAttempts: oldAdapter.processingAttempts,
            validationFailureReason: oldAdapter.validationFailureReason
          )
          messages[index] = newAdapter
        }

      } catch {
        self.error = error
        logger.error("Failed to add reaction: \(error.localizedDescription)")
      }
    }

  }
  /// Apply a reaction update received externally (e.g. via SSE) to the in-memory cache and adapters.
  /// SAFETY: Reactions are persisted to cache but only displayed if parent message is decrypted and valid.
  func applyReactionEvent(messageID: String, emoji: String, senderDID: String, action: String) {
    let normalizedSenderDID = MLSStorageHelpers.normalizeDID(senderDID)
    var reactions = localReactions[messageID] ?? []

    switch action {
    case "add":
      guard
        !reactions.contains(where: { $0.reaction == emoji && $0.senderDID == normalizedSenderDID })
      else {
        return
      }
      reactions.append(
        MLSMessageReaction(
          messageId: messageID,
          reaction: emoji,
          senderDID: normalizedSenderDID,
          reactedAt: Date()
        )
      )
      localReactions[messageID] = reactions

    case "remove":
      reactions.removeAll { $0.reaction == emoji && $0.senderDID == normalizedSenderDID }
      if reactions.isEmpty {
        localReactions.removeValue(forKey: messageID)
      } else {
        localReactions[messageID] = reactions
      }

    default:
      logger.debug("Ignoring unknown reaction action '\(action)' for \(messageID)")
      return
    }

    // SAFETY: Only update UI if parent message exists AND is decrypted/valid
    // Reactions for undecryptable placeholders are cached but not displayed
    guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
      logger.debug(
        "⚠️ [REACTION-SAFETY] Reaction cached but no message adapter found: \(messageID.prefix(16))"
      )
      return
    }

    let oldAdapter = messages[index]
    guard oldAdapter.isDecryptedAndValid else {
      logger.warning(
        "⚠️ [REACTION-SAFETY] Suppressing reaction display for undecryptable message: \(messageID.prefix(16))"
      )
      return
    }

    let newAdapter = MLSMessageAdapter(
      id: oldAdapter.id,
      convoID: oldAdapter.mlsConversationID,
      text: oldAdapter.text,
      senderDID: oldAdapter.senderID,
      currentUserDID: currentUserDID,
      sentAt: oldAdapter.sentAt,
      senderProfile: oldAdapter.mlsProfile,
      reactions: localReactions[messageID] ?? [],
      embed: oldAdapter.mlsEmbed,
      sendState: oldAdapter.sendState,
      epoch: oldAdapter.mlsEpoch,
      sequence: oldAdapter.mlsSequence,
      processingError: oldAdapter.processingError,
      processingAttempts: oldAdapter.processingAttempts,
      validationFailureReason: oldAdapter.validationFailureReason
    )
    messages[index] = newAdapter
  }

  /// Apply an incoming read receipt to update message send states.
  /// Marks all current user's sent messages up to (and including) the referenced message as `.read`.
  func applyReadReceipt(readUpToMessageID: String, readerDID: String) {
    // Only process receipts from other users (not our own)
    let normalizedReaderDID = MLSStorageHelpers.normalizeDID(readerDID)
    guard normalizedReaderDID != currentUserDID else { return }

    guard
      let targetMessage = messages.first(where: { $0.id == readUpToMessageID }),
      let epoch = targetMessage.mlsEpoch,
      let sequenceNumber = targetMessage.mlsSequence
    else {
      logger.debug(
        "📬 [READ_RECEIPTS] Target message \(readUpToMessageID.prefix(16)) not found in loaded messages"
      )
      return
    }

    applyReadReceipt(
      readUpToEpoch: Int64(epoch),
      sequenceNumber: Int64(sequenceNumber),
      readerDID: readerDID,
      messageID: readUpToMessageID
    )
  }


  /// Mark all current-user messages as read (when server sends readEvent with no specific messageId).
  func applyReadReceiptForAll(readerDID: String) {
    let normalizedReaderDID = MLSStorageHelpers.normalizeDID(readerDID)
    guard normalizedReaderDID != currentUserDID else { return }

    var latestCurrentUserCursor: (epoch: Int64, sequenceNumber: Int64)?
    for adapter in messages where adapter.isFromCurrentUser {
      guard let epoch = adapter.mlsEpoch, let sequenceNumber = adapter.mlsSequence else { continue }
      let candidate = (epoch: Int64(epoch), sequenceNumber: Int64(sequenceNumber))
      if shouldAdvanceRemoteReadCutoff(existing: latestCurrentUserCursor, candidate: candidate) {
        latestCurrentUserCursor = candidate
      }
    }

    guard let latestCurrentUserCursor else {
      logger.debug("📬 [READ_RECEIPTS] No loaded current-user messages available for all-read event")
      return
    }

    applyReadReceipt(
      readUpToEpoch: latestCurrentUserCursor.epoch,
      sequenceNumber: latestCurrentUserCursor.sequenceNumber,
      readerDID: readerDID
    )
  }

  func applyReadReceipt(
    readUpToEpoch epoch: Int64,
    sequenceNumber: Int64,
    readerDID: String,
    messageID: String? = nil
  ) {
    let normalizedReaderDID = MLSStorageHelpers.normalizeDID(readerDID)
    guard normalizedReaderDID != currentUserDID else { return }

    let candidate = (epoch: epoch, sequenceNumber: sequenceNumber)
    guard shouldAdvanceRemoteReadCutoff(existing: remoteReadCutoff, candidate: candidate) else {
      return
    }

    remoteReadCutoff = candidate
    applyRemoteReadCutoffToLoadedMessages()

    if let messageID {
      logger.info(
        "📬 [READ_RECEIPTS] Updated message states to .read up to \(messageID.prefix(16))"
      )
    } else {
      logger.info("📬 [READ_RECEIPTS] Updated message states to .read via persisted remote cursor")
    }
  }

  func deleteMessage(messageID: String) async {
    // MLS doesn't support message deletion
  }

  // MARK: - Profile Loading

  private func loadProfilesForMessages(_ adapters: [MLSMessageAdapter]) async {
    guard let appState = appState,
      let client = appState.atProtoClient
    else {
      return
    }

    // Collect unique sender DIDs that we don't have profiles for
    let uniqueDIDs = Set(adapters.map { MLSProfileEnricher.canonicalDID($0.senderID) })
      .filter { profileCache[$0] == nil }
    guard !uniqueDIDs.isEmpty else { return }

    let profiles = await appState.mlsProfileEnricher.ensureProfiles(
      for: Array(uniqueDIDs),
      using: client,
      currentUserDID: currentUserDID
    )

    // Update cache and rebuild affected messages
    for (did, profile) in profiles {
      profileCache[did] = profile
    }

    // Rebuild messages with updated profiles
    messages = messages.map { adapter in
      let canonicalSenderDID = MLSProfileEnricher.canonicalDID(adapter.senderID)
      guard let profile = profileCache[canonicalSenderDID] else { return adapter }
      return MLSMessageAdapter(
        id: adapter.id,
        convoID: adapter.mlsConversationID,
        text: adapter.text,
        senderDID: adapter.senderID,
        currentUserDID: currentUserDID,
        sentAt: adapter.sentAt,
        senderProfile: .init(
          displayName: profile.displayName, avatarURL: profile.avatarURL, handle: profile.handle),
        reactions: localReactions[adapter.id] ?? [],
        embed: adapter.mlsEmbed,
        sendState: adapter.sendState,
        epoch: adapter.mlsEpoch,
        sequence: adapter.mlsSequence,
        processingError: adapter.processingError,
        processingAttempts: adapter.processingAttempts,
        validationFailureReason: adapter.validationFailureReason
      )
    }
  }

  private func sortMessagesInDisplayOrder(_ messages: inout [MLSMessageAdapter]) {
    messages.sort(by: MLSMessageAdapter.sortsInDisplayOrder)
  }
}
