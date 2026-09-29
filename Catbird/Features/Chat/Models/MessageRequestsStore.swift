import OSLog
import Petrel
import SwiftUI

/// What an accepted request should open.
enum MessageRequestAcceptance: Hashable, Sendable {
  case bluesky(convoID: String)
}

/// Data and actions behind the Message Requests sheet. The live store talks to
/// Bluesky chat; the DEBUG UI fixture supplies canned data.
@MainActor
protocol MessageRequestsStore: AnyObject, Observable {
  var blueskyRequests: [MessageRequestItem] { get }
  var isLoading: Bool { get }
  var hasLoaded: Bool { get }
  var inFlight: [MessageRequestItem.ID: MessageRequestDecision] { get }
  var errorMessage: String? { get set }

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
  /// Stops in-flight loads from publishing; called when the sheet goes away.
  func invalidate()
}

extension MessageRequestsStore {
  func item(withID id: MessageRequestItem.ID) -> MessageRequestItem? {
    blueskyRequests.first { $0.id == id }
  }

  var isEmpty: Bool {
    blueskyRequests.isEmpty
  }
}

// MARK: - Live Store

/// Live Bluesky requests for one account. Results are only published while
/// the account that opened the sheet is still active.
@MainActor
@Observable
final class LiveMessageRequestsStore: MessageRequestsStore {
  let accountDID: String

  private(set) var isLoading = false
  private(set) var hasLoaded = false
  private(set) var inFlight: [MessageRequestItem.ID: MessageRequestDecision] = [:]
  var errorMessage: String?

  @ObservationIgnored private let appState: AppState
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
    isLoading = false
  }

  // MARK: Loading

  func refresh() async {
    guard appState.userDID == accountDID else { return }
    isLoading = true
    await appState.chatManager.loadMessageRequests(refresh: true)
    guard appState.userDID == accountDID else { return }
    isLoading = false
    hasLoaded = true
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
    }
  }

  func decline(_ item: MessageRequestItem) async -> Bool {
    guard begin(.decline, on: item) else { return false }
    defer { end(item) }
    switch item.origin {
    case .bluesky(let convoID):
      return await appState.chatManager.declineMessageRequest(convoId: convoID)
    }
  }

  func blockAndClose(_ item: MessageRequestItem) async -> Bool {
    guard let senderDID = item.sender?.did, senderDID != accountDID,
          begin(.block, on: item) else { return false }
    defer { end(item) }
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
      }
    } catch is CancellationError {
      return false
    } catch let error as MessageRequestStoreError {
      errorMessage = error.message
      return false
    } catch {
      guard appState.userDID == accountDID else { return false }
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

  // MARK: Fencing

  private func begin(_ decision: MessageRequestDecision, on item: MessageRequestItem) -> Bool {
    guard appState.userDID == accountDID, inFlight[item.id] == nil else { return false }
    inFlight[item.id] = decision
    return true
  }

  private func end(_ item: MessageRequestItem) {
    inFlight[item.id] = nil
  }
}

/// Failures the store explains to the user in its own words.
enum MessageRequestStoreError: Error {
  case blockFailed

  var message: String {
    switch self {
    case .blockFailed:
      "The sender could not be blocked. Please try again."
    }
  }
}
