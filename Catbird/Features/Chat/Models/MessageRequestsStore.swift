import CatbirdMLSCore
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
  @ObservationIgnored private var pendingRowsByConvo: [String: CatbirdMLS.RequestRow] = [:]
  @ObservationIgnored private let logger = Logger(subsystem: "blue.catbird", category: "MessageRequests")
  @ObservationIgnored private var cachedSource: [ChatBskyConvoDefs.ConvoView] = []
  @ObservationIgnored private var cachedMappedRequests: [MessageRequestItem] = []
  init(appState: AppState) {
    self.appState = appState
    self.accountDID = appState.userDID
  }

  var blueskyRequests: [MessageRequestItem] {
    guard appState.userDID == accountDID else { return [] }
    let source = appState.chatManager.messageRequests
    if source == cachedSource {
      return cachedMappedRequests
    }
    let now = Date()
    let mapped = source.map {
      MessageRequestItem(bluesky: $0, currentUserDID: accountDID, now: now)
    }
    cachedSource = source
    cachedMappedRequests = mapped
    return mapped
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
      let coordinator = try await currentCoordinator(generation: generation)
      let notes = MLSDirectComposeDraftStore.savedInvitationNotes(accountDID: accountDID)
      let initialNotes = MLSGroupInvitationNotesStore.list(accountDID: accountDID)
      try ensureCurrent(coordinator, generation: generation)

      let allRequests = try await coordinator.listRequests()
      let incoming = allRequests.filter { Self.isIncomingPending($0.consent) }
      let profileDIDs = Set(incoming.map(\.senderDid)).subtracting([accountDID, ""])
      let profiles = await appState.mlsProfileEnricher.ensureProfiles(
        for: Array(profileDIDs),
        using: appState.client,
        currentUserDID: accountDID
      )
      try ensureCurrent(coordinator, generation: generation)

      let items = incoming.map { row in
        Self.item(row: row, profiles: profiles)
      }

      savedInvitationNotes = notes
      groupInvitationNotes = initialNotes
      pendingRowsByConvo = Dictionary(
        incoming.map { ($0.conversationId, $0) },
        uniquingKeysWith: { _, latest in latest }
      )
      withAnimation {
        encryptedRequests = items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
      }
    } catch is CancellationError {
    } catch {
      guard isCurrentAccount(generation: generation) else { return }
      logger.error("Failed to load encrypted chat requests: \(error.localizedDescription, privacy: .public)")
      errorMessage = "Could not load encrypted chat requests. Please try again."
    }
  }

  // MARK: Actions

  func accept(_ item: MessageRequestItem) async -> MessageRequestAcceptance? {
    guard begin(.accept, on: item) else { return nil }
    defer { end(item) }
    switch item.origin {
    case .bluesky(let convoID):
      guard await appState.chatManager.acceptMessageRequest(convoId: convoID) else {
        // Show the failure in the sheet, not as a Messages alert after it closes
        appState.chatManager.errorState = nil
        errorMessage = "Couldn’t accept this request. It’s been kept so you can try again."
        return nil
      }
      return appState.userDID == accountDID ? .bluesky(convoID: convoID) : nil
    case .encryptedDirect(let conversationID), .encryptedLegacy(let conversationID):
      let generation = self.generation
      do {
        let coordinator = try await currentCoordinator(generation: generation)
        let row = try await validateStillPending(conversationID: conversationID, coordinator: coordinator)
        try ensureCurrent(coordinator, generation: generation)
        try await coordinator.acceptDirectRequest(requestId: row.requestId)
        try ensureCurrent(coordinator, generation: generation)
        withAnimation { encryptedRequests.removeAll { $0.id == item.id } }
        await appState.loadMLSConversations()
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
      guard await appState.chatManager.declineMessageRequest(convoId: convoID) else {
        // Show the failure in the sheet, not as a Messages alert after it closes
        appState.chatManager.errorState = nil
        errorMessage = "Couldn’t decline this request. Please try again."
        return false
      }
      return true
    case .encryptedDirect(let conversationID), .encryptedLegacy(let conversationID):
      let generation = self.generation
      do {
        let coordinator = try await currentCoordinator(generation: generation)
        let row = try await validateStillPending(conversationID: conversationID, coordinator: coordinator)
        try ensureCurrent(coordinator, generation: generation)
        try await coordinator.declineDirectRequest(requestId: row.requestId)
        try ensureCurrent(coordinator, generation: generation)
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
      case .encryptedDirect(let conversationID), .encryptedLegacy(let conversationID):
        let coordinator = try await currentCoordinator(generation: generation)
        let row = try await validateStillPending(conversationID: conversationID, coordinator: coordinator)
        guard row.senderDid == senderDID else {
          throw MessageRequestStoreError.senderUnverified
        }
        if !(await appState.graphManager.isBlocking(did: senderDID)) {
          guard try await appState.graphManager.block(did: senderDID) else {
            throw MessageRequestStoreError.blockFailed
          }
        }
        try ensureCurrent(coordinator, generation: generation)
        try await coordinator.declineDirectRequest(requestId: row.requestId)
        try ensureCurrent(coordinator, generation: generation)
        withAnimation { encryptedRequests.removeAll { $0.id == item.id } }
        await reconcileEncrypted()
        return true
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

  private func currentCoordinator(generation: UUID) async throws -> MLSClientCoordinator {
    let candidate = await appState.getOrOpenMLSCoordinator()
    guard !Task.isCancelled, isCurrentAccount(generation: generation) else { throw CancellationError() }
    guard let coordinator = candidate else {
      throw CatbirdMLS.MlsError.Internal(message: "MLS coordinator unavailable")
    }
    try ensureCurrent(coordinator, generation: generation)
    return coordinator
  }

  private func validateStillPending(
    conversationID: String,
    coordinator: MLSClientCoordinator
  ) async throws -> CatbirdMLS.RequestRow {
    let latest = try await coordinator.listRequests()
    guard let row = latest.first(where: {
      ($0.conversationId == conversationID || $0.requestId == conversationID)
        && Self.isIncomingPending($0.consent)
    }) else {
      throw MessageRequestStoreError.noLongerPending
    }
    pendingRowsByConvo[conversationID] = row
    return row
  }

  private func ensureCurrent(_ coordinator: MLSClientCoordinator, generation: UUID) throws {
    guard isCurrent(coordinator, generation: generation) else { throw CancellationError() }
  }

  private func isCurrent(_ coordinator: MLSClientCoordinator, generation: UUID) -> Bool {
    !Task.isCancelled && isCurrentAccount(generation: generation)
      && coordinator.accountDid.lowercased() == accountDID.lowercased()
      && !coordinator.isClosedForSession
      && appState.mlsCoordinator === coordinator
  }

  private func isCurrentAccount(generation: UUID) -> Bool {
    appState.userDID == accountDID && self.generation == generation
  }

  private static func isIncomingPending(_ consent: String) -> Bool {
    let normalized = consent.lowercased()
    return normalized == "incoming_pending" || normalized == "incomingpending" || normalized == "pending"
  }

  // MARK: Item Mapping

  private static func item(
    row: CatbirdMLS.RequestRow,
    profiles: [String: MLSProfileEnricher.ProfileData]
  ) -> MessageRequestItem {
    let sender = row.senderDid.isEmpty ? nil : participant(did: row.senderDid, profiles: profiles)
    let parsedText = parsePreviewText(from: row.payloadJson)
    let preview: MessageRequestPreview
    if let parsedText, !parsedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      preview = .message(parsedText)
    } else {
      preview = .description(MessageRequestPresentation.encryptedDirectDescription)
    }
    let date = row.updatedAtMs > 0
      ? Date(timeIntervalSince1970: TimeInterval(row.updatedAtMs) / 1000.0)
      : nil
    return MessageRequestItem(
      id: "mls:\(row.conversationId)",
      origin: .encryptedDirect(conversationID: row.conversationId),
      sender: sender,
      participants: sender.map { [$0] } ?? [],
      groupTitle: nil,
      memberCount: nil,
      date: date,
      context: nil,
      preview: preview,
      isUnread: false
    )
  }

  private static func parsePreviewText(from payloadJson: String) -> String? {
    guard let data = payloadJson.data(using: .utf8),
          let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
      return nil
    }
    return (dict["text"] as? String) ?? (dict["plaintext"] as? String)
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
