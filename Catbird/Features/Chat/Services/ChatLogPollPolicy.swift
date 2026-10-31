import Foundation

/// How one `chat.bsky.convo.getLog` request ended, classified for cursor recovery.
enum ChatLogFetchOutcome: Equatable, Sendable {
  case success
  /// A 4xx other than auth or rate limiting: the server will not accept this cursor.
  case rejected(statusCode: Int)
  /// A 5xx or an empty body. Repeated, these may also mean the cursor is bad.
  case serverError
  case rateLimited
  /// 401/403: the session needs attention; the cursor is not at fault.
  case unauthorized
  /// The request never got an HTTP answer (offline, timeout).
  case transportError
  /// Cancelled, superseded by an account switch, or no client.
  case skipped
}

/// Decides what the getLog poller does after each request. The persisted cursor
/// is the only thing that moves the open conversation forward, so a cursor the
/// server keeps refusing must be dropped and rebuilt rather than retried forever.
struct ChatLogPollPolicy: Sendable {
  enum Action: Equatable, Sendable {
    case none
    case backOff
    /// Drop the cursor, take a fresh baseline and reload what it would have delivered.
    case resetCursor
  }

  static let serverErrorsBeforeReset = 3

  private(set) var consecutiveServerErrors = 0

  mutating func record(_ outcome: ChatLogFetchOutcome) -> Action {
    switch outcome {
    case .success:
      consecutiveServerErrors = 0
      return .none
    case .rejected:
      consecutiveServerErrors = 0
      return .resetCursor
    case .serverError:
      consecutiveServerErrors += 1
      guard consecutiveServerErrors >= Self.serverErrorsBeforeReset else { return .backOff }
      consecutiveServerErrors = 0
      return .resetCursor
    case .rateLimited, .unauthorized, .transportError:
      return .backOff
    case .skipped:
      return .none
    }
  }

  static func outcome(forStatusCode code: Int) -> ChatLogFetchOutcome {
    switch code {
    case 200..<300: return .success
    case 429: return .rateLimited
    case 401, 403: return .unauthorized
    case 400..<500: return .rejected(statusCode: code)
    default: return .serverError
    }
  }

  /// Whether a createMessage event is news to the conversation list. The same
  /// event can arrive twice (a replayed page, or after a listConvos snapshot that
  /// already includes it); only the first sighting may raise the unread count.
  static func isNewMessage(logRev: String, convoRev: String, alreadySeen: Bool) -> Bool {
    !alreadySeen && logRev > convoRev
  }
}
