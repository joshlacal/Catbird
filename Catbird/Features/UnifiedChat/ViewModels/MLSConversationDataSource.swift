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
  let clientMessageID: String
  let text: String
  let embed: MLSEmbedData?
  let createdAt: Date
  var state: MessageSendState
  var confirmedMessageID: String?

  static let idPrefix = "pending:"

  init(
    text: String,
    embed: MLSEmbedData?,
    clientMessageID: String = UUID().uuidString.lowercased(),
    state: MessageSendState = .sending
  ) {
    self.id = Self.idPrefix + UUID().uuidString
    self.clientMessageID = clientMessageID
    self.text = text
    self.embed = embed
    self.createdAt = Date()
    self.state = state
  }
}

struct MLSMessageActionPerformer {
  let edit: @MainActor (_ conversationID: String, _ messageID: String, _ text: String) async throws -> Void
  let unsend: @MainActor (_ conversationID: String, _ messageID: String) async throws -> Void
  var react: (@MainActor (_ conversationID: String, _ messageID: String, _ emoji: String, _ action: MLSReactionPayload.ReactionAction) async throws -> Void)? = nil
}

private enum DecodedMLSRowEvent {
  case display(text: String, isSystemMessage: Bool, embed: MLSEmbedData?)
  case edit(MLSEditPayload)
  case reaction(MLSReactionPayload)
}

private struct OptimisticReactionMutation {
  let emoji: String
  let action: MLSReactionPayload.ReactionAction
  let reactedAt: Date
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
  @ObservationIgnored private var profileRetryTask: Task<Void, Never>?
  @ObservationIgnored private var profileRetryAttempt = 0
  private static let profileRetryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(45)]

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

  private var loadedRowsByID: [String: MLSMessageRow] = [:]
  private var optimisticReactionsByMessageID: [String: [OptimisticReactionMutation]] = [:]
  private static let pageSize = 50
  private var requestedRowCount = MLSConversationDataSource.pageSize
  private var refreshRequest: UUID?
  private var oldestLoadedSeq: Int64?
  private var remoteReadCutoff: (epoch: Int64, sequenceNumber: Int64)?
  private var observationID = UUID()
  private var isObservingCoordinator = false
  private var hasReceivedInitialMessages = false

  var enrichedProfilesSnapshot: [String: MLSProfileEnricher.ProfileData] {
    profileCache
  }

  /// Canonical DIDs of non-self participants observed in the conversation.
  var participantDIDs: [String] {
    var seen = Set<String>()
    var result: [String] = []
    for message in confirmedMessages where !message.isSystemMessage {
      let rootDID = MLSCredentialBinding.credentialRootDID(message.senderID)
      guard !rootDID.isEmpty,
            !MLSCredentialBinding.isSameAccount(rootDID, as: currentUserDID),
            seen.insert(rootDID).inserted else {
        continue
      }
      result.append(rootDID)
    }
    return result
  }

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
    profileRetryTask?.cancel()
    profileRetryTask = nil
    profileRetryAttempt = 0
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
  func beginPendingSend(
    text: String,
    embed: MLSEmbedData?,
    clientMessageID: String = UUID().uuidString.lowercased()
  ) -> String {
    let pending = PendingMLSSend(text: text, embed: embed, clientMessageID: clientMessageID)
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

  func ingestRowsForTesting(_ rows: [MLSMessageRow]) {
    for row in rows {
      loadedRowsByID[row.messageId] = row
    }
    confirmedMessages = MLSMessageAdapter.sortedForDisplay(
      buildAdapters(from: Array(loadedRowsByID.values))
    )
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
    guard !isLoading, hasMoreMessages, let coordinator = activeCoordinator else { return }
    isLoading = true
    defer { isLoading = false }
    requestedRowCount = max(loadedRowsByID.count, requestedRowCount) + Self.pageSize
    await refreshFromCoordinator(coordinator, observationID: observationID)
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
        self.observeNextCoordinatorChange(coordinator, observationID: observationID)
        await self.refreshFromCoordinator(coordinator, observationID: observationID)
      }
    }
  }

  private func refreshFromCoordinator(
    _ coordinator: MLSClientCoordinator,
    observationID: UUID
  ) async {
    guard self.observationID == observationID, !coordinator.isHandleClosed else { return }
    let request = UUID()
    refreshRequest = request
    await resolveConsentAndRecovery(using: coordinator, request: request)
    guard self.observationID == observationID, refreshRequest == request else { return }
    do {
      let window = try await Self.readMessageWindow(minimumCount: requestedRowCount, through: oldestLoadedSeq) { cursor, limit in
        try await coordinator.listMessages(conversationId: self.conversationId, beforeSeq: cursor, limit: limit)
      }
      // Another notification or pagination request may have read a newer SQLite state.
      guard self.observationID == observationID, refreshRequest == request else { return }
      loadedRowsByID = Dictionary(window.rows.map { ($0.messageId, $0) }, uniquingKeysWith: { _, latest in latest })
      oldestLoadedSeq = window.rows.lazy.map(\.seq).filter { $0 > 0 }.min()
      let maxSeq = window.rows.lazy.map(\.seq).max() ?? 0
      optimisticReactionsByMessageID.removeAll()
      var adapters = buildAdapters(from: Array(loadedRowsByID.values))
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
      hasMoreMessages = window.hasMore

      // Hydrate sender names/avatars before the read-state round trips below,
      // which can take seconds on a slow delivery service.
      await enrichMissingProfilesIfNeeded(observationID: observationID)

      if maxSeq > 0 {
        try? await coordinator.acknowledgeEntriesUpTo(conversationId: conversationId, upToSeq: maxSeq)
        if let advanced = try? await coordinator.advanceReadState(
          conversationId: conversationId,
          candidateSeq: UInt64(maxSeq)
        ) {
          remoteReadCutoff = (epoch: 0, sequenceNumber: Int64(clamping: advanced.readThroughSeq))
        }
      } else if let readState = try? await coordinator.getReadState(conversationId: conversationId) {
        remoteReadCutoff = (epoch: 0, sequenceNumber: Int64(clamping: readState.readThroughSeq))
      }
    } catch {
      guard self.observationID == observationID, refreshRequest == request else { return }
      self.error = error
      logger.error("Failed to load MLS messages from SDK: \(error.localizedDescription)")
    }
  }

  /// Read through the oldest already displayed sequence, even if newer arrivals pushed it
  /// onto another page. The resulting window is authoritative for edits, reactions and erasures.
  static func readMessageWindow(
    minimumCount: Int, through oldestSequence: Int64?,
    list: @MainActor (Int64?, UInt32) async throws -> [MLSMessageRow]
  ) async throws -> (rows: [MLSMessageRow], hasMore: Bool) {
    var rows: [MLSMessageRow] = []
    var before: Int64?
    while true {
      // Native caps a single listMessages call at 500 rows.
      let limit = min(500, max(pageSize, minimumCount - rows.count))
      let page = try await list(before, UInt32(limit))
      rows.append(contentsOf: page)
      guard page.count == limit,
            let next = page.lazy.map(\.seq).filter({ $0 > 0 }).min(),
            before.map({ next < $0 }) ?? true else {
        return (rows, false)
      }
      if rows.count >= minimumCount && (oldestSequence.map { next <= $0 } ?? true) {
        return (rows, true)
      }
      before = next
    }
  }

  private func resolveConsentAndRecovery(using coordinator: MLSClientCoordinator, request: UUID? = nil) async {
    let conversations = (try? await coordinator.listConversations(limit: 200)) ?? []
    let requests = (try? await coordinator.listRequests()) ?? []
    guard !coordinator.isHandleClosed, request == nil || refreshRequest == request else { return }
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
    let chronologicalRows = rows.sorted { lhs, rhs in
      if lhs.seq > 0 && rhs.seq > 0 && lhs.seq != rhs.seq {
        return lhs.seq < rhs.seq
      }
      if lhs.createdAtMs != rhs.createdAtMs {
        return lhs.createdAtMs < rhs.createdAtMs
      }
      return lhs.messageId < rhs.messageId
    }

    struct BaseDisplayEntry {
      let row: MLSMessageRow
      var text: String
      let isSystemMessage: Bool
      let embed: MLSEmbedData?
      var isEdited: Bool
      var editedAt: Date?
    }

    var baseByID: [String: BaseDisplayEntry] = [:]
    var orderedIDs: [String] = []
    var pendingEdits: [(row: MLSMessageRow, payload: MLSEditPayload)] = []
    var foldedReactions: [String: [MLSMessageReaction]] = [:]

    for row in chronologicalRows {
      guard let event = decodeRowEvent(row) else { continue }
      switch event {
      case let .display(text, isSystemMessage, embed):
        baseByID[row.messageId] = BaseDisplayEntry(
          row: row,
          text: text,
          isSystemMessage: isSystemMessage,
          embed: embed,
          isEdited: false,
          editedAt: nil
        )
        orderedIDs.append(row.messageId)
      case let .edit(editPayload):
        pendingEdits.append((row, editPayload))
      case let .reaction(reactionPayload):
        let targetID = reactionPayload.messageId
        let emoji = reactionPayload.emoji
        guard !targetID.isEmpty, !emoji.isEmpty else { continue }
        var list = foldedReactions[targetID] ?? []
        let senderRootDID = MLSCredentialBinding.credentialRootDID(row.senderDid)
        let senderIdentity = senderRootDID.isEmpty ? row.senderDid : senderRootDID
        switch reactionPayload.action {
        case .add:
          if !list.contains(where: {
            $0.reaction == emoji && MLSCredentialBinding.isSameAccount($0.senderDID, as: senderIdentity)
          }) {
            list.append(
              MLSMessageReaction(
                messageId: targetID,
                reaction: emoji,
                senderDID: senderIdentity,
                reactedAt: Date(timeIntervalSince1970: Double(row.createdAtMs) / 1_000.0)
              )
            )
          }
        case .remove:
          list.removeAll {
            $0.reaction == emoji && MLSCredentialBinding.isSameAccount($0.senderDID, as: senderIdentity)
          }
        }
        foldedReactions[targetID] = list.isEmpty ? nil : list
      }
    }

    // Apply edits in chronological order, enforcing same-account authorship.
    for (editRow, editPayload) in pendingEdits {
      let targetID = editPayload.targetMessageId
      let trimmedNewText = editPayload.newText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedNewText.isEmpty,
            var target = baseByID[targetID],
            !target.isSystemMessage,
            MLSCredentialBinding.isSameAccount(editRow.senderDid, as: target.row.senderDid)
      else {
        continue
      }
      target.text = trimmedNewText
      target.isEdited = true
      target.editedAt = Date(timeIntervalSince1970: Double(editRow.createdAtMs) / 1_000.0)
      baseByID[targetID] = target
    }

    return orderedIDs.compactMap { id -> MLSMessageAdapter? in
      guard let entry = baseByID[id] else { return nil }
      let row = entry.row
      let canonicalSender = MLSProfileEnricher.canonicalDID(row.senderDid)
      let profile = profileCache[canonicalSender]
      let effectiveReactions = mergedReactions(
        base: foldedReactions[id] ?? [],
        messageID: id
      )
      return MLSMessageAdapter(
        id: row.messageId,
        convoID: row.conversationId,
        text: entry.text,
        senderDID: row.senderDid,
        currentUserDID: currentUserDID,
        sentAt: Date(timeIntervalSince1970: Double(row.createdAtMs) / 1_000.0),
        isSystemMessage: entry.isSystemMessage,
        isEdited: entry.isEdited,
        editedAt: entry.editedAt,
        senderProfile: profile.map {
          .init(displayName: $0.displayName, avatarURL: $0.avatarURL, handle: $0.handle)
        },
        reactions: effectiveReactions,
        embed: entry.embed,
        sendState: .sent,
        epoch: Int(row.epoch),
        sequence: Int(row.seq),
        diffableID: pendingIDAliases[row.messageId]
      )
    }
  }

  private func mergedReactions(
    base: [MLSMessageReaction],
    messageID: String
  ) -> [MLSMessageReaction] {
    guard let mutations = optimisticReactionsByMessageID[messageID], !mutations.isEmpty else {
      return base
    }
    var result = base
    for mutation in mutations {
      switch mutation.action {
      case .add:
        if !result.contains(where: {
          $0.reaction == mutation.emoji && MLSCredentialBinding.isSameAccount($0.senderDID, as: currentUserDID)
        }) {
          result.append(
            MLSMessageReaction(
              messageId: messageID,
              reaction: mutation.emoji,
              senderDID: currentUserDID,
              reactedAt: mutation.reactedAt
            )
          )
        }
      case .remove:
        result.removeAll {
          $0.reaction == mutation.emoji && MLSCredentialBinding.isSameAccount($0.senderDID, as: currentUserDID)
        }
      }
    }
    return result
  }

  private func decodeRowEvent(_ row: MLSMessageRow) -> DecodedMLSRowEvent? {
    let rawData = Data(row.plaintextJson.utf8)
    if let payload = try? MLSMessagePayload.decodeFromJSON(rawData) {
      return classifyPayload(payload)
    }

    if let simple = try? JSONDecoder().decode(SimpleTextEnvelope.self, from: rawData),
       let text = simple.text
    {
      if let nestedPayload = try? MLSMessagePayload.decodeFromJSON(Data(text.utf8)) {
        return classifyPayload(nestedPayload)
      }
      return .display(text: text, isSystemMessage: false, embed: nil)
    }

    guard !row.plaintextJson.hasPrefix("[control:") else { return nil }
    return .display(text: row.plaintextJson, isSystemMessage: false, embed: nil)
  }

  private func classifyPayload(_ payload: MLSMessagePayload) -> DecodedMLSRowEvent? {
    switch payload.messageType {
    case .text:
      return .display(text: payload.text ?? "", isSystemMessage: false, embed: payload.embed)
    case .system:
      return .display(text: MLSSystemMessagePresentation.text(payload), isSystemMessage: true, embed: nil)
    case .edit:
      guard let edit = payload.edit else { return nil }
      return .edit(edit)
    case .reaction:
      guard let reaction = payload.reaction else { return nil }
      return .reaction(reaction)
    case .readReceipt, .typing, .deliveryAck, .recoveryRequest,
         .adminRoster, .adminAction, .unknown:
      return nil
    }
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

  func sendVoiceMessage(_ audioEmbed: MLSAudioEmbed) async {
    guard hasResolvedConsent, !isPendingRequest, directRequestCapabilities?.canSend != false else { return }
    await submitMessage(text: "", embed: .audio(audioEmbed))
  }

  func retryFailedSend(pendingID: String) async {
    guard let pending = takeFailedPendingSend(id: pendingID) else { return }
    await submitMessage(
      text: pending.text,
      embed: pending.embed,
      clientMessageID: pending.clientMessageID
    )
  }

  private func submitMessage(
    text trimmedText: String,
    embed: MLSEmbedData?,
    clientMessageID: String = UUID().uuidString.lowercased()
  ) async {
    if isSendBlockedByRecovery {
      let pendingID = beginPendingSend(
        text: trimmedText,
        embed: embed,
        clientMessageID: clientMessageID
      )
      failPendingSend(
        id: pendingID,
        reason: String(
          localized: "Sending is paused while this conversation's secure session is restored.",
          comment: "Error status when sending an encrypted message is paused during MLS session recovery"
        )
      )
      return
    }

    let pendingID = beginPendingSend(
      text: trimmedText,
      embed: embed,
      clientMessageID: clientMessageID
    )
    guard let coordinator = activeCoordinator else {
      let unavailableMessage = String(
        localized: "MLS service not available",
        comment: "Error message when the encrypted messaging service is unavailable"
      )
      failPendingSend(id: pendingID, reason: unavailableMessage)
      error = NSError(
        domain: "MLS",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: unavailableMessage]
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
        messageId: clientMessageID,
        text: wireText
      )
      loadedRowsByID[sentRow.messageId] = sentRow
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
    guard hasResolvedConsent, !isPendingRequest, directRequestCapabilities?.canSend != false,
          !isSendBlockedByRecovery
    else { return }
    let resolvedID = resolveRealMessageID(messageID)
    guard !resolvedID.hasPrefix(PendingMLSSend.idPrefix),
          let target = confirmedMessages.first(where: { $0.id == resolvedID })
    else { return }

    let hasExisting = target.mlsReactions.contains {
      $0.reaction == emoji && MLSCredentialBinding.isSameAccount($0.senderDID, as: currentUserDID)
    }
    let action: MLSReactionPayload.ReactionAction = hasExisting ? .remove : .add
    applyAndSendReaction(messageID: resolvedID, emoji: emoji, action: action)
  }

  func addReaction(messageID: String, emoji: String) {
    guard hasResolvedConsent, !isPendingRequest, directRequestCapabilities?.canSend != false,
          !isSendBlockedByRecovery
    else { return }
    let resolvedID = resolveRealMessageID(messageID)
    guard !resolvedID.hasPrefix(PendingMLSSend.idPrefix),
          let target = confirmedMessages.first(where: { $0.id == resolvedID })
    else { return }

    let hasExisting = target.mlsReactions.contains {
      $0.reaction == emoji && MLSCredentialBinding.isSameAccount($0.senderDID, as: currentUserDID)
    }
    guard !hasExisting else { return }
    applyAndSendReaction(messageID: resolvedID, emoji: emoji, action: .add)
  }

  private func applyAndSendReaction(
    messageID: String,
    emoji: String,
    action: MLSReactionPayload.ReactionAction
  ) {
    let mutation = OptimisticReactionMutation(emoji: emoji, action: action, reactedAt: Date())
    var list = optimisticReactionsByMessageID[messageID] ?? []
    list.append(mutation)
    optimisticReactionsByMessageID[messageID] = list
    applyOptimisticReactionToConfirmedAdapter(messageID: messageID, mutation: mutation)

    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        if let reactPerformer = self.actionPerformer?.react {
          try await reactPerformer(self.conversationId, messageID, emoji, action)
        } else if let coordinator = self.activeCoordinator {
          let payloadData = try MLSMessagePayload.reaction(
            messageId: messageID,
            emoji: emoji,
            action: action
          ).encodeToJSON()
          if let json = String(data: payloadData, encoding: .utf8) {
            let sentRow = try await coordinator.sendMessage(
              conversationId: self.conversationId,
              text: json
            )
            self.loadedRowsByID[sentRow.messageId] = sentRow
            self.optimisticReactionsByMessageID[messageID] = nil
            self.confirmedMessages = MLSMessageAdapter.sortedForDisplay(
              self.buildAdapters(from: Array(self.loadedRowsByID.values))
            )
          }
        }
      } catch {
        self.error = error
        self.logger.error("Failed to send MLS reaction: \(error.localizedDescription)")
        self.optimisticReactionsByMessageID[messageID] = nil
        if !self.loadedRowsByID.isEmpty {
          self.confirmedMessages = MLSMessageAdapter.sortedForDisplay(
            self.buildAdapters(from: Array(self.loadedRowsByID.values))
          )
        } else {
          let inverseAction: MLSReactionPayload.ReactionAction = action == .add ? .remove : .add
          self.applyOptimisticReactionToConfirmedAdapter(
            messageID: messageID,
            mutation: OptimisticReactionMutation(emoji: emoji, action: inverseAction, reactedAt: Date())
          )
        }
        await self.refreshRecoveryState()
      }
    }
  }

  private func applyOptimisticReactionToConfirmedAdapter(
    messageID: String,
    mutation: OptimisticReactionMutation
  ) {
    guard let idx = confirmedMessages.firstIndex(where: { $0.id == messageID }) else { return }
    let existing = confirmedMessages[idx]
    var updatedReactions = existing.mlsReactions
    switch mutation.action {
    case .add:
      if !updatedReactions.contains(where: {
        $0.reaction == mutation.emoji && MLSCredentialBinding.isSameAccount($0.senderDID, as: currentUserDID)
      }) {
        updatedReactions.append(
          MLSMessageReaction(
            messageId: messageID,
            reaction: mutation.emoji,
            senderDID: currentUserDID,
            reactedAt: mutation.reactedAt
          )
        )
      }
    case .remove:
      updatedReactions.removeAll {
        $0.reaction == mutation.emoji && MLSCredentialBinding.isSameAccount($0.senderDID, as: currentUserDID)
      }
    }
    confirmedMessages[idx] = MLSMessageAdapter(
      id: existing.id,
      convoID: existing.mlsConversationID,
      text: existing.text,
      senderDID: existing.senderID,
      currentUserDID: currentUserDID,
      sentAt: existing.sentAt,
      isSystemMessage: existing.isSystemMessage,
      isEdited: existing.isEdited,
      editedAt: existing.editedAt,
      isTombstone: existing.isTombstone,
      deletedAt: existing.deletedAt,
      senderProfile: existing.mlsProfile,
      reactions: updatedReactions,
      embed: existing.mlsEmbed,
      sendState: existing.sendState,
      epoch: existing.mlsEpoch,
      sequence: existing.mlsSequence,
      processingError: existing.processingError,
      processingAttempts: existing.processingAttempts,
      validationFailureReason: existing.validationFailureReason,
      diffableID: existing.diffableID
    )
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
            userInfo: [NSLocalizedDescriptionKey: String(localized: "MLS service not available")]
          )
        }
        let payload = try MLSMessagePayload.edit(targetMessageId: resolvedMessageID, newText: trimmedText).encodeToJSON()
        if let json = String(data: payload, encoding: .utf8) {
          let editRow = try await coordinator.sendMessage(conversationId: conversationId, text: json)
          loadedRowsByID[editRow.messageId] = editRow
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
          reactions: old.mlsReactions,
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
            userInfo: [NSLocalizedDescriptionKey: String(localized: "MLS service not available")]
          )
        }
        _ = try await coordinator.unsendMessage(
          conversationId: conversationId,
          messageId: resolvedMessageID
        )
      }

      confirmedMessages.removeAll { $0.id == resolvedMessageID }
      loadedRowsByID.removeValue(forKey: resolvedMessageID)
      pendingIDAliases.removeValue(forKey: resolvedMessageID)
      optimisticReactionsByMessageID.removeValue(forKey: resolvedMessageID)
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
    guard self.observationID == observationID else { return }
    let missingDIDs = missingSenderProfileDIDs()
    guard !missingDIDs.isEmpty else {
      profileRetryTask?.cancel()
      profileRetryTask = nil
      profileRetryAttempt = 0
      return
    }
    // The client can be briefly unavailable (session restore, account switch);
    // treat that like a failed fetch and retry rather than giving up.
    if let appState, let client = appState.atProtoClient {
      let profiles = await appState.mlsProfileEnricher.ensureProfiles(
        for: Array(missingDIDs),
        using: client,
        currentUserDID: currentUserDID
      )
      guard self.observationID == observationID else { return }
      for (did, profile) in profiles {
        profileCache[MLSProfileEnricher.canonicalDID(did)] = profile
      }
      if !profiles.isEmpty {
        rebuildMessagesWithProfiles()
      }
    }
    scheduleProfileRetryIfNeeded(observationID: observationID)
  }

  private func missingSenderProfileDIDs() -> Set<String> {
    Set(confirmedMessages.map { MLSProfileEnricher.canonicalDID($0.senderID) })
      .filter { profileCache[$0] == nil }
  }

  /// A failed or partial profile fetch used to wait for the next incoming
  /// message to retry, so a quiet conversation could stay nameless for good.
  /// Retry with backoff while the conversation stays open.
  private func scheduleProfileRetryIfNeeded(observationID: UUID) {
    guard !missingSenderProfileDIDs().isEmpty,
          profileRetryTask == nil,
          profileRetryAttempt < Self.profileRetryDelays.count
    else { return }
    let delay = Self.profileRetryDelays[profileRetryAttempt]
    profileRetryAttempt += 1
    profileRetryTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
      guard let self, !Task.isCancelled else { return }
      self.profileRetryTask = nil
      await self.enrichMissingProfilesIfNeeded(observationID: observationID)
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
        reactions: adapter.isDecryptedAndValid ? adapter.mlsReactions : [],
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
