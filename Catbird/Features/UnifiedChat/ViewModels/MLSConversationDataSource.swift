//
//  MLSConversationDataSource.swift
//  Catbird
//
//  Spaces-only clean-slate UnifiedChatDataSource backed directly by MLSClientCoordinator
//  (CatbirdMlsClient). Zero Swift-side SQLite/GRDB queries.
//

import CatbirdMLSCore
import Foundation
import Observation
import OSLog
import Petrel
import SwiftUI

/// A locally-originated outgoing message that has no server row yet.
struct PendingMLSSend: Identifiable, Equatable, Sendable {
  let id: String
  let text: String
  let embed: MLSEmbedData?
  let createdAt: Date
  var state: MessageSendState
  var confirmedMessageID: String?

  static let idPrefix = "pending:"

  init(text: String, embed: MLSEmbedData?, state: MessageSendState = .sending) {
    self.id = Self.idPrefix + UUID().uuidString
    self.text = text
    self.embed = embed
    self.createdAt = Date()
    self.state = state
  }
}

struct MLSMessageActionPerformer {
  let edit: @MainActor (_ conversationID: String, _ messageID: String, _ text: String) async throws -> Void
  let unsend: @MainActor (_ conversationID: String, _ messageID: String) async throws -> Void
}

private struct SimpleTextEnvelope: Decodable {
  let text: String?
}

@MainActor
@Observable
final class MLSConversationDataSource: UnifiedChatDataSource {
  typealias Message = MLSMessageAdapter

  // MARK: - Properties

  let conversationId: String
  let currentUserDID: String
  private weak var appState: AppState?
  private weak var injectedCoordinator: MLSClientCoordinator?
  private let actionPerformer: MLSMessageActionPerformer?

  private var profileCache: [String: MLSProfileEnricher.ProfileData] = [:]
  private var hasLoadedInitialProfiles = false

  private var confirmedMessages: [MLSMessageAdapter] = []
  private(set) var pendingSends: [PendingMLSSend] = []
  private var pendingIDAliases: [String: String] = [:]

  var messages: [MLSMessageAdapter] {
    guard !pendingSends.isEmpty else { return confirmedMessages }
    return confirmedMessages + pendingAdapters()
  }

  private(set) var conversationRecoveryState: ConversationRecoveryState = .healthy
  private(set) var leavePresentation: MLSConversationLeavePresentation = .none
  private(set) var isPendingRequest = false
  private(set) var hasResolvedConsent = false
  private(set) var directRequestCapabilities: RequestCapabilities?

  var composerPlaceholder: String {
    SendBlockedNotice.composerPlaceholder(for: conversationRecoveryState, leave: leavePresentation)
  }

  var isSendBlockedByRecovery: Bool {
    !hasResolvedConsent
      || isPendingRequest
      || directRequestCapabilities?.canSend == false
      || conversationRecoveryState.blocksSending
  }

  private(set) var isLoading = false
  private(set) var hasMoreMessages = false
  private(set) var error: Error?
  private(set) var showsTypingIndicator = false
  private(set) var typingParticipantAvatarURL: URL?
  private(set) var scrollToBottomTrigger = 0

  var draftText = ""
  var attachedEmbed: MLSEmbedData?

  private var localReactions: [String: [MLSMessageReaction]] = [:]
  private var oldestLoadedSeq: Int = Int.max
  private var remoteReadCutoff: (epoch: Int64, sequenceNumber: Int64)?
  private var observationID = UUID()
  private var isObservingCoordinator = false
  private var hasReceivedInitialMessages = false

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSConversationDataSource")

  // MARK: - Init

  init(
    conversationId: String,
    currentUserDID: String,
    appState: AppState?,
    mlsCoordinator: MLSClientCoordinator? = nil,
    actionPerformer: MLSMessageActionPerformer? = nil
  ) {
    self.conversationId = conversationId
    self.currentUserDID = (try? MLSAppGroupStorage.canonicalizeAccountDid(currentUserDID)) ?? currentUserDID
    self.appState = appState
    self.injectedCoordinator = mlsCoordinator
    self.actionPerformer = actionPerformer
  }

  private var activeCoordinator: MLSClientCoordinator? {
    if let injectedCoordinator, !injectedCoordinator.isHandleClosed {
      return injectedCoordinator
    }
    guard let appState,
          let coordinator = appState.mlsCoordinator,
          coordinator.accountDid == currentUserDID,
          !coordinator.isHandleClosed
    else {
      return nil
    }
    return coordinator
  }

  func stopObserving() {
    observationID = UUID()
    isObservingCoordinator = false
  }

  // MARK: - Pending Sends (WS-6.5)

  private func pendingAdapters() -> [MLSMessageAdapter] {
    let confirmedIDs = Set(confirmedMessages.map(\.id))
    let profile = profileCache[MLSProfileEnricher.canonicalDID(currentUserDID)]
    return pendingSends.compactMap { pending in
      if let real = pending.confirmedMessageID, confirmedIDs.contains(real) {
        return nil
      }
      return MLSMessageAdapter(
        id: pending.id,
        convoID: conversationId,
        text: pending.text,
        senderDID: currentUserDID,
        currentUserDID: currentUserDID,
        sentAt: pending.createdAt,
        senderProfile: profile.map {
          .init(displayName: $0.displayName, avatarURL: $0.avatarURL, handle: $0.handle)
        },
        reactions: [],
        embed: pending.embed,
        sendState: pending.state
      )
    }
  }

  @discardableResult
  func beginPendingSend(text: String, embed: MLSEmbedData?) -> String {
    let pending = PendingMLSSend(text: text, embed: embed)
    pendingSends.append(pending)
    scrollToBottomTrigger += 1
    return pending.id
  }

  func completePendingSend(id: String, realMessageID: String) {
    guard let index = pendingSends.firstIndex(where: { $0.id == id }) else { return }
    if confirmedMessages.contains(where: { $0.id == realMessageID }) {
      pendingSends.remove(at: index)
      return
    }
    pendingIDAliases[realMessageID] = id
    pendingSends[index].confirmedMessageID = realMessageID
    pendingSends[index].state = .sent
  }

  private func prunePendingSendsSupersededByConfirmed() {
    guard !pendingSends.isEmpty else { return }
    let ids = Set(confirmedMessages.map(\.id))
    pendingSends.removeAll { entry in
      guard let real = entry.confirmedMessageID else { return false }
      return ids.contains(real)
    }
  }

  #if DEBUG
  func setActionConsentForTesting(resolved: Bool, pending: Bool) {
    precondition(appState == nil && injectedCoordinator == nil && actionPerformer != nil)
    hasResolvedConsent = resolved
    isPendingRequest = pending
  }
  #endif

  func ingestConfirmedMessageForTesting(_ adapter: MLSMessageAdapter) {
    confirmedMessages.append(adapter)
    confirmedMessages = MLSMessageAdapter.sortedForDisplay(confirmedMessages)
    prunePendingSendsSupersededByConfirmed()
  }

  private func resolveRealMessageID(_ id: String) -> String {
    guard id.hasPrefix(PendingMLSSend.idPrefix) else { return id }
    return confirmedMessages.first(where: { $0.diffableID == id })?.id ?? id
  }

  func updatePendingSendRetrying(id: String, attempt: Int, nextAttemptAt: Date, reason: String) {
    guard let index = pendingSends.firstIndex(where: { $0.id == id }) else { return }
    pendingSends[index].state = .retrying(attempt: attempt, nextAttemptAt: nextAttemptAt, reason: reason)
  }

  func setPendingSendWaiting(id: String, reason: String) {
    guard let index = pendingSends.firstIndex(where: { $0.id == id }) else { return }
    pendingSends[index].state = .waitingForPeer(reason: reason)
  }

  func failPendingSend(id: String, reason: String) {
    guard let index = pendingSends.firstIndex(where: { $0.id == id }) else { return }
    pendingSends[index].state = .failed(reason)
  }

  func takeFailedPendingSend(id: String) -> PendingMLSSend? {
    guard let index = pendingSends.firstIndex(where: { $0.id == id }) else { return nil }
    switch pendingSends[index].state {
    case .failed, .waitingForPeer:
      return pendingSends.remove(at: index)
    default:
      return nil
    }
  }

  // MARK: - UnifiedChatDataSource

  func message(for id: String) -> MLSMessageAdapter? {
    messages.first { $0.diffableID == id || $0.id == id }
  }

  func loadMessages() async {
    let coordinator: MLSClientCoordinator?
    if let existing = activeCoordinator {
      coordinator = existing
    } else if let opened = await appState?.getOrOpenMLSCoordinator(), opened.accountDid == currentUserDID {
      coordinator = opened
    } else {
      coordinator = nil
    }
    guard let coordinator else { return }

    let currentObservation = observationID
    startObservingCoordinatorIfNeeded(coordinator, observationID: currentObservation)
    if let appState {
      await appState.syncMLS(using: coordinator)
    } else {
      do {
        try await coordinator.sync()
      } catch {
        logger.error("MLS sync did not complete: \(error.localizedDescription)")
      }
    }
    await refreshFromCoordinator(coordinator, observationID: currentObservation)
  }

  func loadMoreMessages() async {
    guard !isLoading, hasMoreMessages, oldestLoadedSeq != Int.max,
          let coordinator = activeCoordinator
    else {
      hasMoreMessages = false
      return
    }
    isLoading = true
    defer { isLoading = false }
    let currentObservation = observationID

    do {
      let olderRows = try await coordinator.listMessages(
        conversationId: conversationId,
        beforeSeq: Int64(oldestLoadedSeq),
        limit: 50
      )
      guard currentObservation == observationID else { return }
      guard !olderRows.isEmpty else {
        hasMoreMessages = false
        return
      }
      let olderAdapters = buildAdapters(from: olderRows)
      for adapter in olderAdapters {
        if let seq = adapter.mlsSequence, seq > 0, seq < oldestLoadedSeq {
          oldestLoadedSeq = seq
        }
      }
      let existingIDs = Set(confirmedMessages.map(\.id))
      let unique = olderAdapters.filter { !existingIDs.contains($0.id) }
      confirmedMessages = MLSMessageAdapter.sortedForDisplay(unique + confirmedMessages)
      hasMoreMessages = olderRows.count >= 50 && !unique.isEmpty
      await enrichMissingProfilesIfNeeded(observationID: currentObservation)
    } catch {
      self.error = error
      logger.error("Failed to paginate MLS messages: \(error.localizedDescription)")
    }
  }

  func refreshRecoveryState() async {
    guard let coordinator = activeCoordinator else { return }
    await resolveConsentAndRecovery(using: coordinator)
  }

  private func startObservingCoordinatorIfNeeded(
    _ coordinator: MLSClientCoordinator,
    observationID: UUID
  ) {
    guard !isObservingCoordinator else { return }
    isObservingCoordinator = true
    observeNextCoordinatorChange(coordinator, observationID: observationID)
  }

  private func observeNextCoordinatorChange(
    _ coordinator: MLSClientCoordinator,
    observationID: UUID
  ) {
    guard self.observationID == observationID, !coordinator.isHandleClosed else {
      isObservingCoordinator = false
      return
    }
    withObservationTracking {
      _ = coordinator.changeRevision
      _ = coordinator.darwinWakeupCount
    } onChange: { [weak self, weak coordinator] in
      Task { @MainActor [weak self, weak coordinator] in
        guard let self, let coordinator, self.observationID == observationID else { return }
        await self.refreshFromCoordinator(coordinator, observationID: observationID)
        self.observeNextCoordinatorChange(coordinator, observationID: observationID)
      }
    }
  }

  private func refreshFromCoordinator(
    _ coordinator: MLSClientCoordinator,
    observationID: UUID
  ) async {
    guard self.observationID == observationID, !coordinator.isHandleClosed else { return }
    await resolveConsentAndRecovery(using: coordinator)
    do {
      let rows = try await coordinator.listMessages(
        conversationId: conversationId,
        beforeSeq: nil,
        limit: 50
      )
      guard self.observationID == observationID else { return }
      var adapters = buildAdapters(from: rows)
      var minSeq = Int.max
      var maxSeq: Int64 = 0
      for row in rows where row.seq > 0 {
        minSeq = min(minSeq, Int(row.seq))
        maxSeq = max(maxSeq, row.seq)
      }
      oldestLoadedSeq = minSeq
      adapters = MLSMessageAdapter.sortedForDisplay(adapters)

      let existingIDs = Set(confirmedMessages.map(\.id))
      let maxExistingTime = confirmedMessages.map(\.sentAt).max() ?? .distantPast
      var hasNewIncoming = false
      for adapter in adapters where !existingIDs.contains(adapter.id) {
        if hasReceivedInitialMessages && !adapter.isFromCurrentUser && adapter.sentAt > maxExistingTime {
          hasNewIncoming = true
        }
      }
      if hasNewIncoming {
        PlatformHaptics.light()
      }

      confirmedMessages = adapters
      prunePendingSendsSupersededByConfirmed()
      hasReceivedInitialMessages = true
      hasMoreMessages = rows.count >= 50

      if maxSeq > 0 {
        try? await coordinator.acknowledgeEntriesUpTo(conversationId: conversationId, upToSeq: maxSeq)
      }
      await enrichMissingProfilesIfNeeded(observationID: observationID)
    } catch {
      guard self.observationID == observationID else { return }
      self.error = error
      logger.error("Failed to load MLS messages from SDK: \(error.localizedDescription)")
    }
  }

  private func resolveConsentAndRecovery(using coordinator: MLSClientCoordinator) async {
    let conversations = (try? await coordinator.listConversations(limit: 200)) ?? []
    let requests = (try? await coordinator.listRequests()) ?? []
    let matchingRequest = requests.first {
      $0.conversationId == conversationId || $0.requestId == conversationId
    }
    let hasConvo = conversations.contains { $0.conversationId == conversationId }

    if let matchingRequest {
      let isIncoming = matchingRequest.consent == "incomingPending" || matchingRequest.consent == "incoming_pending"
      let isOutgoing = matchingRequest.consent == "outgoingPending" || matchingRequest.consent == "outgoing_pending"
      let pending = isIncoming || isOutgoing
      isPendingRequest = pending
      hasResolvedConsent = !pending
      directRequestCapabilities = RequestCapabilities(
        canPreview: true,
        canAccept: isIncoming,
        canClose: true,
        canSend: !pending,
        canEmitReceipts: !pending,
        canAdminister: false
      )
      let isClosed = matchingRequest.consent == "declined" || matchingRequest.consent == "closed"
      conversationRecoveryState = isClosed ? .closed : .healthy
    } else if hasConvo {
      isPendingRequest = false
      hasResolvedConsent = true
      directRequestCapabilities = nil
      conversationRecoveryState = .healthy
    } else {
      isPendingRequest = false
      hasResolvedConsent = false
      directRequestCapabilities = nil
      conversationRecoveryState = .healthy
    }
  }

  private func buildAdapters(from rows: [MLSMessageRow]) -> [MLSMessageAdapter] {
    rows.compactMap { row in
      guard let decoded = decodeRowPayload(row) else { return nil }
      let canonicalSender = MLSProfileEnricher.canonicalDID(row.senderDid)
      let profile = profileCache[canonicalSender]
      let sendState: MessageSendState = row.isOwn ? .sent : .sent
      return MLSMessageAdapter(
        id: row.messageId,
        convoID: row.conversationId,
        text: decoded.displayText,
        senderDID: row.senderDid,
        currentUserDID: currentUserDID,
        sentAt: Date(timeIntervalSince1970: Double(row.createdAtMs) / 1_000.0),
        isSystemMessage: decoded.isSystemMessage,
        senderProfile: profile.map {
          .init(displayName: $0.displayName, avatarURL: $0.avatarURL, handle: $0.handle)
        },
        reactions: localReactions[row.messageId] ?? [],
        embed: decoded.embed,
        sendState: sendState,
        epoch: Int(row.epoch),
        sequence: Int(row.seq),
        diffableID: pendingIDAliases[row.messageId]
      )
    }
  }

  private func decodeRowPayload(
    _ row: MLSMessageRow
  ) -> (displayText: String, isSystemMessage: Bool, embed: MLSEmbedData?)? {
    let rawData = Data(row.plaintextJson.utf8)
    if let payload = try? MLSMessagePayload.decodeFromJSON(rawData) {
      switch payload.messageType {
      case .text:
        return (payload.text ?? "", false, payload.embed)
      case .system:
        let text = MLSSystemMessagePresentation.text(payload)
        return (text, true, nil)
      case .reaction, .readReceipt, .typing, .deliveryAck, .recoveryRequest,
           .adminRoster, .adminAction, .edit, .unknown:
        return nil
      }
    }

    if let simple = try? JSONDecoder().decode(SimpleTextEnvelope.self, from: rawData),
       let text = simple.text
    {
      if let nestedPayload = try? MLSMessagePayload.decodeFromJSON(Data(text.utf8)) {
        switch nestedPayload.messageType {
        case .text:
          return (nestedPayload.text ?? "", false, nestedPayload.embed)
        case .system:
          return (MLSSystemMessagePresentation.text(nestedPayload), true, nil)
        default:
          return nil
        }
      }
      return (text, false, nil)
    }

    guard !row.plaintextJson.hasPrefix("[control:") else { return nil }
    return (row.plaintextJson, false, nil)
  }

  // MARK: - Sending, Reactions, Edit, Unsend

  func sendMessage(text: String) async {
    guard hasResolvedConsent, !isPendingRequest, directRequestCapabilities?.canSend != false else { return }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty || attachedEmbed != nil else { return }

    let embed = attachedEmbed
    draftText = ""
    attachedEmbed = nil
    await submitMessage(text: trimmed, embed: embed)
  }

  func retryFailedSend(pendingID: String) async {
    guard let pending = takeFailedPendingSend(id: pendingID) else { return }
    await submitMessage(text: pending.text, embed: pending.embed)
  }

  private func submitMessage(text trimmedText: String, embed: MLSEmbedData?) async {
    if isSendBlockedByRecovery {
      let pendingID = beginPendingSend(text: trimmedText, embed: embed)
      failPendingSend(
        id: pendingID,
        reason: "Sending is paused while this conversation's secure session is restored."
      )
      return
    }

    let pendingID = beginPendingSend(text: trimmedText, embed: embed)
    guard let coordinator = activeCoordinator else {
      failPendingSend(id: pendingID, reason: "MLS service not available")
      error = NSError(
        domain: "MLS",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "MLS service not available"]
      )
      return
    }

    do {
      let wireText: String
      if let embed,
         let encoded = try? MLSMessagePayload.text(trimmedText, embed: embed).encodeToJSON(),
         let jsonString = String(data: encoded, encoding: .utf8)
      {
        wireText = jsonString
      } else {
        wireText = trimmedText
      }

      let sentRow = try await coordinator.sendMessage(
        conversationId: conversationId,
        text: wireText
      )
      completePendingSend(id: pendingID, realMessageID: sentRow.messageId)

      let profile = profileCache[MLSProfileEnricher.canonicalDID(currentUserDID)]
      let adapter = MLSMessageAdapter(
        id: sentRow.messageId,
        convoID: conversationId,
        text: trimmedText,
        senderDID: currentUserDID,
        currentUserDID: currentUserDID,
        sentAt: Date(timeIntervalSince1970: Double(sentRow.createdAtMs) / 1_000.0),
        senderProfile: profile.map {
          .init(displayName: $0.displayName, avatarURL: $0.avatarURL, handle: $0.handle)
        },
        reactions: [],
        embed: embed,
        sendState: .sent,
        epoch: Int(sentRow.epoch),
        sequence: Int(sentRow.seq),
        diffableID: pendingIDAliases[sentRow.messageId]
      )
      if let idx = confirmedMessages.firstIndex(where: { $0.id == sentRow.messageId }) {
        confirmedMessages[idx] = adapter
      } else {
        confirmedMessages.append(adapter)
      }
      confirmedMessages = MLSMessageAdapter.sortedForDisplay(confirmedMessages)
      prunePendingSendsSupersededByConfirmed()
      scrollToBottomTrigger += 1
    } catch {
      self.error = error
      failPendingSend(id: pendingID, reason: error.localizedDescription)
      await refreshRecoveryState()
    }
  }

  func toggleReaction(messageID: String, emoji: String) {
    guard hasResolvedConsent, !isPendingRequest, directRequestCapabilities?.canSend != false else { return }
    let resolvedID = resolveRealMessageID(messageID)
    var current = localReactions[resolvedID] ?? []
    if let existingIndex = current.firstIndex(where: {
      $0.reaction == emoji && MLSCredentialBinding.isSameAccount($0.senderDID, as: currentUserDID)
    }) {
      current.remove(at: existingIndex)
    } else {
      current.append(
        MLSMessageReaction(
          messageId: resolvedID,
          reaction: emoji,
          senderDID: currentUserDID,
          reactedAt: Date()
        )
      )
    }
    localReactions[resolvedID] = current.isEmpty ? nil : current
    rebuildMessagesWithProfiles()
  }

  func addReaction(messageID: String, emoji: String) {
    guard hasResolvedConsent, !isPendingRequest, directRequestCapabilities?.canSend != false else { return }
    let resolvedID = resolveRealMessageID(messageID)
    var current = localReactions[resolvedID] ?? []
    guard !current.contains(where: {
      $0.reaction == emoji && MLSCredentialBinding.isSameAccount($0.senderDID, as: currentUserDID)
    }) else { return }
    current.append(
      MLSMessageReaction(
        messageId: resolvedID,
        reaction: emoji,
        senderDID: currentUserDID,
        reactedAt: Date()
      )
    )
    localReactions[resolvedID] = current
    rebuildMessagesWithProfiles()
  }

  @discardableResult
  func editMessage(messageID: String, newText: String) async -> Bool {
    guard hasResolvedConsent, !isPendingRequest, directRequestCapabilities?.canSend != false else { return false }
    let trimmedText = newText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty, let target = message(for: messageID), target.canEdit else {
      return false
    }
    let resolvedMessageID = target.id

    do {
      if let actionPerformer {
        try await actionPerformer.edit(conversationId, resolvedMessageID, trimmedText)
      } else {
        guard let coordinator = activeCoordinator else {
          throw NSError(
            domain: "MLS",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "MLS service not available"]
          )
        }
        let payload = try MLSMessagePayload.edit(targetMessageId: resolvedMessageID, newText: trimmedText).encodeToJSON()
        if let json = String(data: payload, encoding: .utf8) {
          _ = try await coordinator.sendMessage(conversationId: conversationId, text: json)
        }
      }
      if let index = confirmedMessages.firstIndex(where: { $0.id == resolvedMessageID }) {
        let old = confirmedMessages[index]
        confirmedMessages[index] = MLSMessageAdapter(
          id: old.id,
          convoID: old.mlsConversationID,
          text: trimmedText,
          senderDID: old.senderID,
          currentUserDID: currentUserDID,
          sentAt: old.sentAt,
          isSystemMessage: old.isSystemMessage,
          isEdited: true,
          editedAt: Date(),
          isTombstone: old.isTombstone,
          deletedAt: old.deletedAt,
          senderProfile: old.mlsProfile,
          reactions: localReactions[old.id] ?? [],
          embed: old.mlsEmbed,
          sendState: old.sendState,
          epoch: old.mlsEpoch,
          sequence: old.mlsSequence,
          diffableID: old.diffableID
        )
      }
      return true
    } catch {
      self.error = error
      logger.error("Failed to edit MLS message: \(error.localizedDescription)")
      await refreshRecoveryState()
      return false
    }
  }

  @discardableResult
  func unsendMessage(messageID: String) async -> Bool {
    guard hasResolvedConsent, !isPendingRequest, directRequestCapabilities?.canSend != false else {
      return false
    }
    guard let target = message(for: messageID), target.canUnsend else { return false }
    let resolvedMessageID = target.id

    do {
      if let actionPerformer {
        try await actionPerformer.unsend(conversationId, resolvedMessageID)
      } else {
        guard let coordinator = activeCoordinator else {
          throw NSError(
            domain: "MLS",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "MLS service not available"]
          )
        }
        _ = try await coordinator.unsendMessage(
          conversationId: conversationId,
          messageId: resolvedMessageID
        )
      }

      confirmedMessages.removeAll { $0.id == resolvedMessageID }
      pendingIDAliases.removeValue(forKey: resolvedMessageID)
      localReactions.removeValue(forKey: resolvedMessageID)
      return true
    } catch {
      self.error = error
      logger.error("Failed to unsend MLS message: \(error.localizedDescription)")
      await refreshRecoveryState()
      return false
    }
  }

  func deleteMessage(messageID: String) async {
    _ = await unsendMessage(messageID: messageID)
  }

  // MARK: - Profile Enrichment

  func preloadProfiles(_ profiles: [String: MLSProfileEnricher.ProfileData]) {
    var changed = false
    for (did, profile) in profiles {
      let canonical = MLSProfileEnricher.canonicalDID(did)
      let existing = profileCache[canonical]
      if existing == nil || (existing?.avatarURL == nil && profile.avatarURL != nil) {
        profileCache[canonical] = profile
        changed = true
      }
    }
    if !profiles.isEmpty {
      hasLoadedInitialProfiles = true
      if changed && !confirmedMessages.isEmpty {
        rebuildMessagesWithProfiles()
      }
    }
  }

  private func enrichMissingProfilesIfNeeded(observationID: UUID) async {
    guard let appState, let client = appState.atProtoClient else { return }
    let missingDIDs = Set(confirmedMessages.map { MLSProfileEnricher.canonicalDID($0.senderID) })
      .filter { profileCache[$0] == nil }
    guard !missingDIDs.isEmpty else { return }
    let profiles = await appState.mlsProfileEnricher.ensureProfiles(
      for: Array(missingDIDs),
      using: client,
      currentUserDID: currentUserDID
    )
    guard self.observationID == observationID else { return }
    for (did, profile) in profiles {
      profileCache[did] = profile
    }
    if !profiles.isEmpty {
      rebuildMessagesWithProfiles()
    }
  }

  private func rebuildMessagesWithProfiles() {
    confirmedMessages = confirmedMessages.map { adapter in
      let canonicalSender = MLSProfileEnricher.canonicalDID(adapter.senderID)
      let profile = profileCache[canonicalSender]
      let senderProfile = profile.map {
        MLSMessageAdapter.MLSProfileData(
          displayName: $0.displayName,
          avatarURL: $0.avatarURL,
          handle: $0.handle
        )
      } ?? adapter.mlsProfile

      return MLSMessageAdapter(
        id: adapter.id,
        convoID: adapter.mlsConversationID,
        text: adapter.text,
        senderDID: adapter.senderID,
        currentUserDID: currentUserDID,
        sentAt: adapter.sentAt,
        isSystemMessage: adapter.isSystemMessage,
        isEdited: adapter.isEdited,
        editedAt: adapter.editedAt,
        isTombstone: adapter.isTombstone,
        deletedAt: adapter.deletedAt,
        senderProfile: senderProfile,
        reactions: adapter.isDecryptedAndValid ? (localReactions[adapter.id] ?? []) : [],
        embed: adapter.mlsEmbed,
        sendState: adapter.sendState,
        epoch: adapter.mlsEpoch,
        sequence: adapter.mlsSequence,
        processingError: adapter.processingError,
        processingAttempts: adapter.processingAttempts,
        validationFailureReason: adapter.validationFailureReason,
        diffableID: adapter.diffableID
      )
    }
  }
}
