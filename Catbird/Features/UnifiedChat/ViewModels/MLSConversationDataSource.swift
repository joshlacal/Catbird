import Foundation
import OSLog
import Petrel
import SwiftUI

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

    private(set) var messages: [MLSMessageAdapter] = []
    private(set) var isLoading: Bool = false
    private(set) var hasMoreMessages: Bool = true
    private(set) var error: Error?

    var draftText: String = ""
    var attachedEmbed: MLSEmbedData?

    // Local reactions cache for optimistic updates
    private var localReactions: [String: [MLSMessageReaction]] = [:]

    // Pagination tracking
    private var oldestLoadedEpoch: Int = Int.max
    private var oldestLoadedSeq: Int = Int.max

    private let logger = Logger(subsystem: "blue.catbird", category: "MLSConversationDataSource")

    // MARK: - Init

    init(conversationId: String, currentUserDID: String, appState: AppState?) {
      self.conversationId = conversationId
      self.currentUserDID = currentUserDID
      self.appState = appState
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
        // Fetch messages from local storage
        let storage = MLSStorage.shared
        let messageModels = try await storage.fetchMessagesForConversation(
          conversationId,
          currentUserDID: currentUserDID,
          database: database,
          limit: 50
        )

        // Also load cached reactions
        let cachedReactions = try await storage.fetchReactionsForConversation(
          conversationId,
          currentUserDID: currentUserDID,
          database: database
        )

        // Merge cached reactions into local cache
        for (messageId, models) in cachedReactions {
          let reactions = models.map { model in
            MLSMessageReaction(
              messageId: model.messageID,
              reaction: model.emoji,
              senderDID: model.actorDID,
              reactedAt: model.timestamp
            )
          }
          localReactions[messageId] = reactions
        }

        // Convert to adapters
        var adapters: [MLSMessageAdapter] = []

        for model in messageModels {
          guard let plaintext = model.plaintext, !model.plaintextExpired else {
            continue
          }

          // Skip control messages (reactions, read receipts, typing indicators, etc.)
          // These are cached with sentinel plaintext like "[control:reaction]"
          if plaintext.hasPrefix("[control:") {
            continue
          }

          let canonicalSenderDID = MLSProfileEnricher.canonicalDID(model.senderID)
          let profile = profileCache[canonicalSenderDID]
          let reactions = localReactions[model.messageID] ?? []

          let adapter = MLSMessageAdapter(
            id: model.messageID,
            convoID: conversationId,
            text: plaintext,
            senderDID: model.senderID,
            currentUserDID: currentUserDID,
            sentAt: model.timestamp,
            senderProfile: profile.map {
              .init(displayName: $0.displayName, avatarURL: $0.avatarURL, handle: $0.handle)
            },
            reactions: reactions,
            embed: model.parsedEmbed,
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

        // Sort by epoch/sequence
        adapters.sort { lhs, rhs in
          // For now, sort by sentAt since we don't have direct epoch/seq on adapter
          lhs.sentAt < rhs.sentAt
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
          // Re-sort after merge
          merged.sort { $0.sentAt < $1.sentAt }
          self.messages = merged
        }

        self.hasMoreMessages = messageModels.count >= 50

        // Load profiles for senders
        await loadProfilesForMessages(adapters)

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

        var adapters: [MLSMessageAdapter] = []

        for model in olderModels {
          guard let plaintext = model.plaintext, !model.plaintextExpired else {
            continue
          }

          // Skip control messages (reactions, read receipts, typing indicators, etc.)
          if plaintext.hasPrefix("[control:") {
            continue
          }

          let canonicalSenderDID = MLSProfileEnricher.canonicalDID(model.senderID)
          let profile = profileCache[canonicalSenderDID]
          let reactions = localReactions[model.messageID] ?? []

          let adapter = MLSMessageAdapter(
            id: model.messageID,
            convoID: conversationId,
            text: plaintext,
            senderDID: model.senderID,
            currentUserDID: currentUserDID,
            sentAt: model.timestamp,
            senderProfile: profile.map {
              .init(displayName: $0.displayName, avatarURL: $0.avatarURL, handle: $0.handle)
            },
            reactions: reactions,
            embed: model.parsedEmbed,
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

        // Load profiles for any senders in the newly prepended messages
        await loadProfilesForMessages(adapters)

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
            // Use encrypted reaction removal (E2EE via MLS)
            _ = try await manager.sendEncryptedReaction(
              emoji: emoji,
              to: messageID,
              in: conversationId,
              action: .remove
            )
            localReactions[messageID] = currentReactions.filter {
              !($0.reaction == emoji && $0.senderDID == currentUserDID)
            }
          } else {
            // Use encrypted reaction (E2EE via MLS)
            _ = try await manager.sendEncryptedReaction(
              emoji: emoji,
              to: messageID,
              in: conversationId,
              action: .add
            )
            let newReaction = MLSMessageReaction(
              messageId: messageID,
              reaction: emoji,
              senderDID: currentUserDID,
              reactedAt: Date()
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

          // Use encrypted reaction (E2EE via MLS)
          _ = try await manager.sendEncryptedReaction(
            emoji: emoji,
            to: messageID,
            in: conversationId,
            action: .add
          )

          let newReaction = MLSMessageReaction(
            messageId: messageID,
            reaction: emoji,
            senderDID: currentUserDID,
            reactedAt: Date()
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
    func applyReactionEvent(messageID: String, emoji: String, senderDID: String, action: String) {
      var reactions = localReactions[messageID] ?? []

      switch action {
      case "add":
        guard !reactions.contains(where: { $0.reaction == emoji && $0.senderDID == senderDID })
        else {
          return
        }
        reactions.append(
          MLSMessageReaction(
            messageId: messageID,
            reaction: emoji,
            senderDID: senderDID,
            reactedAt: Date()
          )
        )
        localReactions[messageID] = reactions

      case "remove":
        reactions.removeAll { $0.reaction == emoji && $0.senderDID == senderDID }
        if reactions.isEmpty {
          localReactions.removeValue(forKey: messageID)
        } else {
          localReactions[messageID] = reactions
        }

      default:
        logger.debug("Ignoring unknown reaction action '\(action)' for \(messageID)")
        return
      }

      // Update the message adapter's reactions if it's currently loaded.
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
