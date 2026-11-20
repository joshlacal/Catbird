import CatbirdMLSCore
import Foundation

/// Starts a one-to-one encrypted chat and delivers the text typed for it.
///
/// A new one-to-one chat begins as a request, and the request itself carries the first
/// message; nothing else can be sent until the other person accepts. Sending the text as a
/// separate message straight after creating the request is refused by the delivery service.
/// That used to surface as "Couldn't start the encrypted chat" although the request had
/// gone out, and the request carried a placeholder instead of what was typed.
enum MLSDirectChatStart {
  /// What became of the typed text.
  enum Delivery: Equatable, Sendable {
    /// It went out inside the request.
    case sentWithRequest
    /// It was sent as an ordinary message into a chat that is already open.
    case sentAsMessage
    /// A request you sent this person earlier is still waiting, and it carries other text.
    case earlierRequestWaiting
    /// This person's request to you is waiting for your answer.
    case theirRequestWaiting

    /// Whether the other person will receive the text.
    var delivered: Bool { self == .sentWithRequest || self == .sentAsMessage }

    /// What to tell the user when the text was not delivered.
    var notice: String? {
      switch self {
      case .sentWithRequest, .sentAsMessage:
        return nil
      case .earlierRequestWaiting:
        return "You’ve already sent this person a request. You can send more messages once they accept it."
      case .theirRequestWaiting:
        return "This person has sent you a request. Accept it in Requests to reply."
      }
    }
  }

  struct Outcome: Sendable {
    let conversationID: String
    let delivery: Delivery
    /// The message that carries the text, when it was delivered.
    let messageID: String?
    let sentAtMs: Int64?
  }

  /// The part of a request the decision needs.
  struct RequestState: Equatable, Sendable {
    let consent: String
    let openingText: String?
  }

  enum Plan: Equatable, Sendable {
    /// The request that now exists carries the text; send nothing more.
    case carriedByRequest
    /// The chat is open; send the text as a message.
    case sendMessage
    case earlierRequestWaiting
    case theirRequestWaiting
  }

  /// Decides what to do with `typedText` once the conversation exists.
  ///
  /// `request` is the request for that conversation, or nil when it has none (a chat that
  /// was accepted long ago, or was never a request).
  static func plan(typedText: String, request: RequestState?) -> Plan {
    guard let request else { return .sendMessage }
    switch request.consent {
    case "outgoingPending", "outgoing_pending":
      let typed = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
      let carried = request.openingText?.trimmingCharacters(in: .whitespacesAndNewlines)
      return carried == typed ? .carriedByRequest : .earlierRequestWaiting
    case "incomingPending", "incoming_pending":
      return .theirRequestWaiting
    default:
      return .sendMessage
    }
  }

  /// Creates the request (or finds the existing chat) with `recipientDID` and delivers `text`.
  static func start(
    coordinator: MLSClientCoordinator,
    sequencerDID: String,
    recipientDID: String,
    text: String
  ) async throws -> Outcome {
    let created = try await coordinator.createGroup(
      conversationId: UUID().uuidString.lowercased(),
      sequencerDid: sequencerDID,
      memberDids: [recipientDID],
      // A title would make this a two-person group, not a request.
      title: nil,
      // The engine sends this as the request's encrypted first message.
      description: text
    )
    let conversationID = created.conversationId
    let request = ((try? await coordinator.listRequests()) ?? []).first {
      $0.conversationId == conversationID
    }
    let state = request.map { RequestState(consent: $0.consent, openingText: $0.previewText) }

    switch plan(typedText: text, request: state) {
    case .carriedByRequest:
      return Outcome(
        conversationID: conversationID,
        delivery: .sentWithRequest,
        messageID: request?.firstMessageId,
        sentAtMs: request?.updatedAtMs
      )
    case .sendMessage:
      let row = try await coordinator.sendMessage(conversationId: conversationID, text: text)
      return Outcome(
        conversationID: conversationID,
        delivery: .sentAsMessage,
        messageID: row.messageId,
        sentAtMs: row.createdAtMs
      )
    case .earlierRequestWaiting:
      return Outcome(
        conversationID: conversationID, delivery: .earlierRequestWaiting, messageID: nil, sentAtMs: nil)
    case .theirRequestWaiting:
      return Outcome(
        conversationID: conversationID, delivery: .theirRequestWaiting, messageID: nil, sentAtMs: nil)
    }
  }
}
