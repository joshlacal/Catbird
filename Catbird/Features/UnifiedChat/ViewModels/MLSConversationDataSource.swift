import Foundation
import OSLog
import Petrel
import SwiftUI
import CatbirdMLSService

#if os(iOS)
  import CatbirdMLSCore

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

    var draftText: String = ""
    var attachedEmbed: MLSEmbedData?

    // Local reactions cache for optimistic updates
    private var localReactions: [String: [MLSMessageReaction]] = [:]
    private var reactionReloadTask: Task<Void, Never>?

    // Pagination tracking
    private var oldestLoadedEpoch: Int = Int.max
    private var oldestLoadedSeq: Int = Int.max

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
    
    /// Preload profiles for known participants before loading messages
    /// Call this with participant data from the conversation list to avoid blank names
    func preloadProfiles(_ profiles: [String: MLSProfileEnricher.ProfileData]) {
      var newProfilesAdded = false
      for (did, profile) in profiles {
        let canonical = MLSProfileEnricher.canonicalDID(did)
        if profileCache[canonical] == nil {
          profileCache[canonical] = profile
          newProfilesAdded = true
        }
      }
      if !profiles.isEmpty {
        hasLoadedInitialProfiles = true
        logger.debug("Preloaded \(profiles.count) profiles for conversation \(self.conversationId)")

        // If messages are already loaded, rebuild them with the new profile data
        if newProfilesAdded && !messages.isEmpty {
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
      guard !isLoading else { return }
      isLoading = true
      error = nil

      defer { isLoading = false }

      guard let appState = appState,
        let database = appState.mlsDatabase
      else {
        logger.error("Cannot load messages: database not available")
        return
      }

      do {
        let storage = MLSStorage.shared

        // IMPROVEMENT: Load member data from database first as fallback for display names
        // This ensures we always have at least handle info even before network profile fetch
        if memberCache.isEmpty {
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
        }

        // Fetch messages from local storage
        let messageModels = try await storage.fetchMessagesForConversation(
          conversationId,
          currentUserDID: currentUserDID,
          database: database,
          limit: 50
        )

        let messageIDs = messageModels.map(\.messageID)
        await loadCachedReactions(
          for: messageIDs,
          database: database,
          replaceExisting: true,
          refreshMessages: false
        )

        // Convert to adapters
        var adapters: [MLSMessageAdapter] = []
        var unknownDIDs: Set<String> = []

        for model in messageModels {
          guard let payload = model.parsedPayload, !model.payloadExpired else {
            continue
          }

          // Skip control messages (reactions, etc.)
          guard payload.messageType == .text else {
            continue
          }

          // SAFETY: Skip placeholder error messages that shouldn't be displayed
          // These are created when messages fail to decrypt (e.g., reactions, self-messages)
          // Check for known placeholder text patterns
          let text = payload.text ?? ""
          let isPlaceholderError =
            model.processingError != nil
            && (text.isEmpty || text.contains("Message unavailable")
              || text.contains("Decryption Failed") || text.contains("Self-sent message"))
          if isPlaceholderError {
            logger.debug("Skipping placeholder error message: \(model.messageID)")
            continue
          }

          let displayText = text

          let canonicalSenderDID = MLSProfileEnricher.canonicalDID(model.senderID)
          let profile = profileCache[canonicalSenderDID]
          
          // SAFETY: Don't attach reactions to messages with processing errors
          // They will remain cached but not displayed on error bubbles
          let hasError = model.processingError != nil || model.validationFailureReason != nil
          let reactions = hasError ? [] : (localReactions[model.messageID] ?? [])

          // Build profile data with fallbacks:
          // 1. Use cached profile if available
          // 2. Fall back to member database data (handle/displayName)
          // 3. Track unknown DIDs for async profile fetch
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
            // Use member database data as fallback
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
            sendState: .sent,
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

        // Sort by epoch/sequence (MLS ordering is authoritative, not timestamps)
        adapters.sort { lhs, rhs in
          let lhsEpoch = lhs.mlsEpoch ?? Int.max
          let rhsEpoch = rhs.mlsEpoch ?? Int.max
          if lhsEpoch != rhsEpoch {
            return lhsEpoch < rhsEpoch
          }
          let lhsSeq = lhs.mlsSequence ?? Int.max
          let rhsSeq = rhs.mlsSequence ?? Int.max
          if lhsSeq != rhsSeq {
            return lhsSeq < rhsSeq
          }
          // Fallback to timestamp for messages without epoch/seq
          return lhs.sentAt < rhs.sentAt
        }

        // Merge with existing messages instead of replacing
        // This preserves scroll position and avoids UI flicker
        let existingIDs = Set(messages.map { $0.id })
        let newMessages = adapters.filter { !existingIDs.contains($0.id) }

        if newMessages.isEmpty && messages.count == adapters.count {
          // No changes, just update existing messages in place for reactions/profiles
          self.messages = adapters
        } else {
          // Merge: keep existing, add new ones
          var merged = messages
          for adapter in adapters {
            if let existingIndex = merged.firstIndex(where: { $0.id == adapter.id }) {
              // Update existing message (for reactions, profile updates, etc.)
              merged[existingIndex] = adapter
            } else {
              // Add new message
              merged.append(adapter)
            }
          }
          // Re-sort after merge using MLS ordering
          merged.sort { lhs, rhs in
            let lhsEpoch = lhs.mlsEpoch ?? Int.max
            let rhsEpoch = rhs.mlsEpoch ?? Int.max
            if lhsEpoch != rhsEpoch {
              return lhsEpoch < rhsEpoch
            }
            let lhsSeq = lhs.mlsSequence ?? Int.max
            let rhsSeq = rhs.mlsSequence ?? Int.max
            if lhsSeq != rhsSeq {
              return lhsSeq < rhsSeq
            }
            return lhs.sentAt < rhs.sentAt
          }
          self.messages = merged
        }

        self.hasMoreMessages = messageModels.count >= 50
        scheduleDelayedReactionReload(messageIDs: messageIDs, database: database)

        // IMPROVEMENT: Only fetch profiles for DIDs we don't have yet
        // If no unknown DIDs, skip the network call entirely
        if !unknownDIDs.isEmpty {
          logger.debug("Fetching profiles for \(unknownDIDs.count) unknown sender DIDs")
          await loadProfilesForMessages(adapters)
        } else if !hasLoadedInitialProfiles {
          // First load - ensure we try to fetch even if we have member fallbacks
          await loadProfilesForMessages(adapters)
          hasLoadedInitialProfiles = true
        }

        logger.info("Loaded \(adapters.count) MLS messages")

      } catch {
        self.error = error
        logger.error("Failed to load MLS messages: \(error.localizedDescription)")
      }
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

        var adapters: [MLSMessageAdapter] = []
        var unknownDIDs: Set<String> = []

        for model in olderModels {
          guard let payload = model.parsedPayload, !model.payloadExpired else {
            continue
          }

          // Skip control messages (reactions, etc.)
          guard payload.messageType == .text else {
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

          let displayText = text

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
            sendState: .sent,
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

        // Prepend older messages
        self.messages = adapters + self.messages
        self.hasMoreMessages = olderModels.count >= 50

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

    func sendMessage(text: String) async {
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedEmbed != nil
      else { return }

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
          sendState: .sent
        )

        // Add to messages if not already present
        if !messages.contains(where: { $0.id == messageId }) {
          messages.append(adapter)
        }

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

    // MARK: - Refresh

    /// Debounce task for refreshFromStorage to avoid rapid reloads
    private var refreshDebounceTask: Task<Void, Never>?

    /// Called when new messages have been decrypted and stored
    /// Triggers a debounced refresh from storage to update the UI
    @MainActor
    func onMessagesDecrypted() {
      // Cancel any pending refresh
      refreshDebounceTask?.cancel()

      // Schedule a debounced refresh
      refreshDebounceTask = Task {
        do {
          try await Task.sleep(for: .milliseconds(100))
        } catch {
          return  // Task was cancelled
        }

        guard !Task.isCancelled else { return }
        await refreshFromStorage()
      }
    }

    /// Refresh messages from local storage (call after new messages arrive via SSE)
    func refreshFromStorage() async {
      await loadMessages()
    }
  }
#endif
