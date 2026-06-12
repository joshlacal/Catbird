import Foundation

// MARK: - UnifiedChatMessage

/// Protocol that unifies Bluesky Chat and MLS Chat messages
protocol UnifiedChatMessage: Identifiable, Hashable, Sendable {
  var id: String { get }
  /// Identity used for collection-view diffing. Defaults to `id`. MLS keeps
  /// one stable item identity across the optimistic-pending → server-confirmed
  /// handover so the bubble reconfigures in place instead of being deleted and
  /// re-inserted (which flickers).
  var diffableID: String { get }
  var text: String { get }
  var attributedText: AttributedString { get }
  var senderID: String { get }
  var senderDisplayName: String? { get }
  var senderAvatarURL: URL? { get }
  var sentAt: Date { get }
  var isFromCurrentUser: Bool { get }
  var reactions: [UnifiedReaction] { get }
  var embed: UnifiedEmbed? { get }
  var sendState: MessageSendState { get }
}

// MARK: - MessageSendState

/// Message send state
enum MessageSendState: Hashable, Sendable {
  case sending
  case sent
  case delivered
  case read
  case failed(String)
}

// MARK: - UnifiedChatMessage Default Rich Text

extension UnifiedChatMessage {
  var diffableID: String { id }

  var attributedText: AttributedString {
    ChatTextRenderer.attributedString(for: text)
  }
}

// MARK: - ChatTextRenderer

enum ChatTextRenderer {
  private static let linkDetector = try? NSDataDetector(
    types: NSTextCheckingResult.CheckingType.link.rawValue
  )

  static func attributedString(for text: String) -> AttributedString {
    guard !text.isEmpty else { return AttributedString() }

    var attributed = AttributedString(text)
    let nsText = text as NSString

    linkDetector?.enumerateMatches(
      in: text,
      options: [],
      range: NSRange(location: 0, length: nsText.length)
    ) { match, _, _ in
      guard
        let match,
        let url = match.url,
        let stringRange = Range(match.range, in: text),
        let attributedRange = Range(stringRange, in: attributed)
      else {
        return
      }

      attributed[attributedRange].link = url
      attributed[attributedRange].underlineStyle = .single
    }

    return attributed
  }
}
