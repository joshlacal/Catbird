import OSLog
import Petrel
import SwiftUI

/// What an accepted request should open.
enum MessageRequestAcceptance: Hashable, Sendable {
  case bluesky(convoID: String)
  case encrypted(conversationID: String)
}

/// Data and actions behind the Message Requests sheet. The live store talks to
/// Bluesky chat and the MLS manager; the DEBUG UI fixture supplies canned data.
@MainActor
protocol MessageRequestsStore: AnyObject, Observable {
  var blueskyRequests: [MessageRequestItem] { get }
  var encryptedRequests: [MessageRequestItem] { get }
  var groupInvitationNotes: [MLSGroupInvitationNotes] { get }
  var savedInvitationNotes: [MLSDirectComposeDraft] { get }
  var isLoading: Bool { get }
  var hasLoaded: Bool { get }
  var inFlight: [MessageRequestItem.ID: MessageRequestDecision] { get }
  var errorMessage: String? { get set }
  /// Verified encrypted requests open through `MLSRequestConversationGate`.
  var usesVerifiedEncryptedDetail: Bool { get }

  func refresh() async
  /// Accepts the request. Returns where to go on success, nil on failure.
  func accept(_ item: MessageRequestItem) async -> MessageRequestAcceptance?
  /// Declines the request. Returns true once it has been removed.
  func decline(_ item: MessageRequestItem) async -> Bool
  /// Blocks the sender and closes the request. Returns true on success.
  func blockAndClose(_ item: MessageRequestItem) async -> Bool
  /// Declines every pending Bluesky request.
  func declineAllBluesky() async
  func blueskyConversation(for item: MessageRequestItem) -> ChatBskyConvoDefs.ConvoView?
  func mlsReportClient() async -> MLSAPIClient?
  /// Stops in-flight loads from publishing; called when the sheet goes away.
  func invalidate()
}

extension MessageRequestsStore {
  func item(withID id: MessageRequestItem.ID) -> MessageRequestItem? {
    blueskyRequests.first { $0.id == id } ?? encryptedRequests.first { $0.id == id }
  }

  var isEmpty: Bool {
    blueskyRequests.isEmpty && encryptedRequests.isEmpty
      && groupInvitationNotes.isEmpty && savedInvitationNotes.isEmpty
  }
}

// MARK: - Live Store

/// Live requests for one account. Every awaited MLS step re-checks that the
/// account, manager, and load generation are still current, so a switched or
/// signed-out account can never publish into (or act through) this sheet.
@MainActor
@Observable
final class LiveMessageRequestsStore: MessageRequestsStore {
  let accountDID: String

  private(set) var encryptedRequests: [MessageRequestItem] = []
  private(set) var groupInvitationNotes: [MLSGroupInvitationNotes] = []
  private(set) var savedInvitationNotes: [MLSDirectComposeDraft] = []
  private(set) var isLoading = false
  private(set) var hasLoaded = false
  private(set) var inFlight: [MessageRequestItem.ID: MessageRequestDecision] = [:]
  var errorMessage: String?

  let usesVerifiedEncryptedDetail = true

  @ObservationIgnored private let appState: AppState
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var isLoadingEncrypted = false
  @ObservationIgnored private var directRequests: [String: DirectRequestView] = [:]
  @ObservationIgnored private var legacyRequests: [String: MLSConversationModel] = [:]
  @ObservationIgnored private let logger = Logger(subsystem: "blue.catbird", category: "MessageRequests")

  init(appState: AppState) {
    self.appState = appState
    self.accountDID = appState.userDID
  }

  var blueskyRequests: [MessageRequestItem] {
    guard appState.userDID == accountDID else { return [] }
    let now = Date()
    return appState.chatManager.messageRequests.map {
      MessageRequestItem(bluesky: $0, currentUserDID: accountDID, now: now)
    }
  }

  func invalidate() {
    generation = UUID()
    isLoadingEncrypted = false
    isLoading = false
  }

  // MARK: Loading

  func refresh() async {
    guard appState.userDID == accountDID else { return }
    isLoading = true
    async let bluesky: Void = appState.chatManager.loadMessageRequests(refresh: true)
    async let encrypted: Void = loadEncrypted()
    _ = await (bluesky, encrypted)
    guard appState.userDID == accountDID else { return }
    isLoading = false
    hasLoaded = true
  }

  private func loadEncrypted() async {
    guard !isLoadingEncrypted else { return }
    let generation = self.generation
    isLoadingEncrypted = true
    defer { if self.generation == generation { isLoadingEncrypted = false } }

    do {
      let manager = try await currentManager(generation: generation)
      let notes = try await MLSDirectComposeDraftStore.savedInvitationNotes(accountDID: accountDID, database: manager.database)
      try ensureCurrent(manager, generation: generation)
      let initialNotes = try await MLSGroupInvitationNotesStore.list(accountDID: accountDID, database: manager.database)
      try ensureCurrent(manager, generation: generation)

      let verifiedRequests = try await manager.listDirectRequestViews()
      var incoming = verifiedRequests.filter { $0.consent == .incomingPending }
      let verifiedIDs = Set(verifiedRequests.map(\.conversationId))
      let candidates = try await manager.fetchPendingRequestConversations()
        .filter { $0.currentUserDID == accountDID && !verifiedIDs.contains($0.conversationID) }
      var legacy: [MLSConversationModel] = []
      for candidate in candidates {
        try ensureCurrent(manager, generation: generation)
        switch try await manager.classifyDirectRequestConversation(conversationId: candidate.conversationID) {
        case .legacyV1:
          legacy.append(candidate)
        case .verifiedRequest, .requestAwaitingProjection, .unknown:
          let verified = try await manager.refreshRequestPreview(conversationId: candidate.conversationID)
          if verified.consent == .incomingPending { incoming.append(verified) }
        }
      }
      for request in incoming {
        try ensureCurrent(manager, generation: generation)
        try await MLSRequestNotificationPreviewCache.project(request, accountDID: accountDID, database: manager.database)
      }

      var membersByConvo: [String: [String]] = [:]
      for request in legacy {
        try ensureCurrent(manager, generation: generation)
        membersByConvo[request.conversationID] = try await manager
          .fetchConversationMembers(convoId: request.conversationID).map(\.did)
      }
      let inviters = Dictionary(uniqueKeysWithValues: legacy.map { request in
        (request.conversationID, inviterDID(of: request.conversationID, manager: manager, members: membersByConvo[request.conversationID] ?? []))
      })
      let profileDIDs = Set(
        membersByConvo.values.flatMap { $0 } + incoming.compactMap { $0.introduction?.senderDid }
      ).subtracting([accountDID])
      let profiles = await appState.mlsProfileEnricher.ensureProfiles(
        for: Array(profileDIDs), using: appState.client, currentUserDID: accountDID)
      try ensureCurrent(manager, generation: generation)

      let groupIDs = Set(legacy.filter {
        manager.conversations[$0.conversationID]?.conversationKind == .value_group
      }.map(\.conversationID))

      let directItems = incoming.map { request in
        Self.item(direct: request, profiles: profiles)
      }
      let legacyItems = legacy.map { request in
        Self.item(
          legacy: request,
          isGroup: groupIDs.contains(request.conversationID),
          inviterDID: inviters[request.conversationID] ?? nil,
          memberDIDs: (membersByConvo[request.conversationID] ?? []).filter { $0 != accountDID },
          profiles: profiles)
      }

      savedInvitationNotes = notes
      groupInvitationNotes = initialNotes
      directRequests = Dictionary(incoming.map { ($0.conversationId, $0) }, uniquingKeysWith: { _, latest in latest })
      legacyRequests = Dictionary(uniqueKeysWithValues: legacy.map { ($0.conversationID, $0) })
      withAnimation {
        encryptedRequests = (directItems + legacyItems).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
      }
    } catch is CancellationError {
    } catch {
      guard isCurrentAccount(generation: generation) else { return }
      logger.error("Failed to load encrypted chat requests: \(error.localizedDescription, privacy: .public)")
      errorMessage = "Could not load encrypted chat requests. Please try again."
    }
  }

  /// The member who invited the current user, from the server's participant
  /// provenance. Falls back to the only other member of a two-person chat.
  private func inviterDID(of conversationID: String, manager: MLSConversationManager, members: [String]) -> String? {
    if let provenance = manager.conversations[conversationID]?.participants
      .first(where: { $0.userDid.didString() == accountDID })?.invitationProvenance {
      let inviter = provenance.invitedByDid.didString()
      if inviter != accountDID { return inviter }
    }
    let others = members.filter { $0 != accountDID }
    return others.count == 1 ? others.first : nil
  }

  // MARK: Actions

  func accept(_ item: MessageRequestItem) async -> MessageRequestAcceptance? {
    guard begin(.accept, on: item) else { return nil }
    defer { end(item) }
    switch item.origin {
    case .bluesky(let convoID):
      guard await appState.chatManager.acceptMessageRequest(convoId: convoID) else {
        errorMessage = "Could not accept this request. It has been kept so you can try again."
        return nil
      }
      return appState.userDID == accountDID ? .bluesky(convoID: convoID) : nil
    case .encryptedDirect(let conversationID), .encryptedLegacy(let conversationID):
      let generation = self.generation
      do {
        let manager = try await currentManager(generation: generation)
        try await validateStillPending(item, manager: manager)
        try await MLSChatRequestAcceptance.perform(
          conversationID: conversationID,
          isCurrent: { self.isCurrent(manager, generation: generation) },
          accept: { try await manager.acceptConversationRequest(convoId: $0) },
          didAccept: { _ in })
        withAnimation { encryptedRequests.removeAll { $0.id == item.id } }
        return .encrypted(conversationID: conversationID)
      } catch is CancellationError {
        return nil
      } catch let error as MessageRequestStoreError {
        await loadEncrypted()
        errorMessage = error.message
        return nil
      } catch {
        guard isCurrentAccount(generation: generation) else { return nil }
        logger.error("Failed to accept encrypted request: \(error.localizedDescription, privacy: .public)")
        errorMessage = "Could not accept this chat request. It has been kept so you can try again."
        return nil
      }
    }
  }

  func decline(_ item: MessageRequestItem) async -> Bool {
    guard begin(.decline, on: item) else { return false }
    defer { end(item) }
    switch item.origin {
    case .bluesky(let convoID):
      return await appState.chatManager.declineMessageRequest(convoId: convoID)
    case .encryptedDirect(let conversationID), .encryptedLegacy(let conversationID):
      let generation = self.generation
      do {
        let manager = try await currentManager(generation: generation)
        try await validateStillPending(item, manager: manager)
        try ensureCurrent(manager, generation: generation)
        try await manager.declineConversationRequest(convoId: conversationID)
        try ensureCurrent(manager, generation: generation)
        withAnimation { encryptedRequests.removeAll { $0.id == item.id } }
        await reconcileEncrypted()
        return true
      } catch is CancellationError {
        return false
      } catch let error as MessageRequestStoreError {
        await loadEncrypted()
        errorMessage = error.message
        return false
      } catch {
        guard isCurrentAccount(generation: generation) else { return false }
        logger.error("Failed to decline encrypted request: \(error.localizedDescription, privacy: .public)")
        errorMessage = "Could not decline this chat request. Please try again."
        return false
      }
    }
  }

  func blockAndClose(_ item: MessageRequestItem) async -> Bool {
    guard let senderDID = item.sender?.did, senderDID != accountDID,
          begin(.block, on: item) else { return false }
    defer { end(item) }
    let generation = self.generation
    do {
      switch item.origin {
      case .bluesky(let convoID):
        if !(await appState.graphManager.isBlocking(did: senderDID)) {
          guard try await appState.graphManager.block(did: senderDID) else {
            throw MessageRequestStoreError.blockFailed
          }
        }
        guard appState.userDID == accountDID else { return false }
        _ = await appState.chatManager.declineMessageRequest(convoId: convoID)
        return true
      case .encryptedDirect(let conversationID):
        let manager = try await currentManager(generation: generation)
        guard let request = directRequests[conversationID], request.consent == .incomingPending,
              request.introduction?.senderDid == senderDID else {
          throw MessageRequestStoreError.senderUnverified
        }
        if !(await appState.graphManager.isBlocking(did: senderDID)) {
          guard try await appState.graphManager.block(did: senderDID) else {
            throw MessageRequestStoreError.blockFailed
          }
        }
        try ensureCurrent(manager, generation: generation)
        _ = try await manager.closeDirectRequest(conversationId: conversationID)
        try ensureCurrent(manager, generation: generation)
        withAnimation { encryptedRequests.removeAll { $0.id == item.id } }
        await reconcileEncrypted()
        return true
      case .encryptedLegacy:
        // Legacy requests block through `BlockChatSenderSheet`, which also
        // records a reason with the delivery service.
        return false
      }
    } catch is CancellationError {
      return false
    } catch let error as MessageRequestStoreError {
      errorMessage = error.message
      return false
    } catch {
      guard isCurrentAccount(generation: generation) else { return false }
      logger.error("Failed to block request sender: \(error.localizedDescription, privacy: .public)")
      errorMessage = MessageRequestStoreError.blockFailed.message
      return false
    }
  }

  func declineAllBluesky() async {
    for item in blueskyRequests {
      _ = await decline(item)
    }
  }

  func blueskyConversation(for item: MessageRequestItem) -> ChatBskyConvoDefs.ConvoView? {
    guard case .bluesky(let convoID) = item.origin else { return nil }
    return appState.chatManager.messageRequests.first { $0.id == convoID }
  }

  func mlsReportClient() async -> MLSAPIClient? {
    guard appState.userDID == accountDID else { return nil }
    return await appState.getMLSAPIClient()
  }

  /// Reloads after a decision so server-side state wins over the local removal.
  func reconcileEncrypted() async {
    await loadEncrypted()
  }

  // MARK: Fencing

  private func begin(_ decision: MessageRequestDecision, on item: MessageRequestItem) -> Bool {
    guard appState.userDID == accountDID, inFlight[item.id] == nil else { return false }
    inFlight[item.id] = decision
    return true
  }

  private func end(_ item: MessageRequestItem) {
    inFlight[item.id] = nil
  }

  private func currentManager(generation: UUID) async throws -> MLSConversationManager {
    let candidate = await appState.getMLSConversationManager()
    guard !Task.isCancelled, isCurrentAccount(generation: generation) else { throw CancellationError() }
    guard let manager = candidate else { throw MLSAPIError.serverUnavailable }
    try ensureCurrent(manager, generation: generation)
    return manager
  }

  /// Re-reads pending state before acting so a request that was already
  /// handled on another device is refreshed instead of acted on twice.
  private func validateStillPending(_ item: MessageRequestItem, manager: MLSConversationManager) async throws {
    switch item.origin {
    case .bluesky:
      return
    case .encryptedDirect(let conversationID):
      let latest = try await manager.refreshRequestPreview(conversationId: conversationID)
      guard latest.consent == .incomingPending else { throw MessageRequestStoreError.noLongerPending }
      directRequests[conversationID] = latest
    case .encryptedLegacy(let conversationID):
      let pending = try await manager.fetchPendingRequestConversations()
      guard pending.contains(where: { $0.conversationID == conversationID && $0.currentUserDID == accountDID }) else {
        throw MessageRequestStoreError.noLongerPending
      }
    }
  }

  private func ensureCurrent(_ manager: MLSConversationManager, generation: UUID) throws {
    guard isCurrent(manager, generation: generation) else { throw CancellationError() }
  }

  private func isCurrent(_ manager: MLSConversationManager, generation: UUID) -> Bool {
    !Task.isCancelled && isCurrentAccount(generation: generation)
      && manager.currentUserDID == accountDID && !manager.isShuttingDown
      && appState.mlsConversationManager === manager
  }

  private func isCurrentAccount(generation: UUID) -> Bool {
    appState.userDID == accountDID && self.generation == generation
  }

  // MARK: Item Mapping

  private static func item(
    direct request: DirectRequestView,
    profiles: [String: MLSProfileEnricher.ProfileData]
  ) -> MessageRequestItem {
    let sender = request.introduction.map { participant(did: $0.senderDid, profiles: profiles) }
    let preview: MessageRequestPreview
    if request.capabilities.canPreview, case .ready(let text, _) = request.preview,
       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      preview = .message(text)
    } else {
      preview = .description(MessageRequestPresentation.encryptedDirectDescription)
    }
    var context: String?
    if request.capabilities.canPreview, case .ready(_, .some) = request.preview {
      context = "Includes a group invitation"
    }
    return MessageRequestItem(
      id: "mls:\(request.conversationId)",
      origin: .encryptedDirect(conversationID: request.conversationId),
      sender: sender,
      participants: sender.map { [$0] } ?? [],
      groupTitle: nil,
      memberCount: nil,
      date: request.introduction.flatMap { MessageRequestPresentation.parseTimestamp($0.receivedAt) },
      context: context,
      preview: preview,
      isUnread: false
    )
  }

  private static func item(
    legacy request: MLSConversationModel,
    isGroup: Bool,
    inviterDID: String?,
    memberDIDs: [String],
    profiles: [String: MLSProfileEnricher.ProfileData]
  ) -> MessageRequestItem {
    let participants = memberDIDs.map { participant(did: $0, profiles: profiles) }
    let sender = inviterDID.map { participant(did: $0, profiles: profiles) }
    let memberCount = memberDIDs.count + 1
    let groupTitle = isGroup ? MLSChatRequestPresentation.groupTitle(request.title) : nil
    return MessageRequestItem(
      id: "mls:\(request.conversationID)",
      origin: .encryptedLegacy(conversationID: request.conversationID),
      sender: sender,
      participants: participants,
      groupTitle: groupTitle,
      memberCount: isGroup ? memberCount : nil,
      date: request.lastMessageAt ?? request.createdAt,
      context: nil,
      preview: isGroup
        ? .description(MessageRequestPresentation.groupInvitationDescription(title: request.title, memberCount: memberCount))
        : .description(MessageRequestPresentation.encryptedDirectDescription),
      isUnread: false
    )
  }

  private static func participant(did: String, profiles: [String: MLSProfileEnricher.ProfileData]) -> RequestParticipant {
    let profile = profiles[did]
    return RequestParticipant(
      did: did,
      handle: profile?.handle,
      displayName: profile?.displayName,
      avatarURL: profile?.avatarURL
    )
  }
}

/// Failures the store explains to the user in its own words.
enum MessageRequestStoreError: Error {
  case noLongerPending
  case senderUnverified
  case blockFailed

  var message: String {
    switch self {
    case .noLongerPending:
      "This request was already handled, possibly on another device. The list has been refreshed."
    case .senderUnverified:
      "The verified sender identity is unavailable. Refresh this request and try again."
    case .blockFailed:
      "The sender could not be blocked. Please try again."
    }
  }
}
