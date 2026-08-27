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
  var canEdit: Bool { get }
  var canUnsend: Bool { get }
  var isEdited: Bool { get }
  var editedAt: Date? { get }
  var isTombstone: Bool { get }
  var deletedAt: Date? { get }
  var isSystemMessage: Bool { get }
  var systemEvent: UnifiedSystemEvent? { get }
  var systemGroupEvents: [UnifiedSystemEvent]? { get }
  var isSystemGroup: Bool { get }
  var isExpanded: Bool { get }
  var replyContext: UnifiedMessageReplyContext? { get }
}

/// Hydrated reply context for a chat message
struct UnifiedMessageReplyContext: Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    case message(id: String, senderDID: String, senderDisplayName: String?, text: String)
    case deleted
    case beforeUserJoined
    case unexpected(String)
  }

  let kind: Kind
  let referencedMessageID: String?
  let senderDisplayName: String?
  let previewText: String
  let isTappable: Bool

  init(
    kind: Kind,
    referencedMessageID: String?,
    senderDisplayName: String?,
    previewText: String,
    isTappable: Bool
  ) {
    self.kind = kind
    self.referencedMessageID = referencedMessageID
    self.senderDisplayName = senderDisplayName
    self.previewText = previewText
    self.isTappable = isTappable
  }
}

/// Represents an in-stream system event (e.g. member joined, group edited, chat locked)
struct UnifiedSystemEvent: Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    case memberAdded(memberDID: String, role: String?)
    case memberRemoved(memberDID: String, removedByDID: String?)
    case memberJoined(memberDID: String, role: String?)
    case memberLeave(memberDID: String)
    case convoLocked(byDID: String?)
    case convoUnlocked(byDID: String?)
    case convoEnded(byDID: String?)
    case groupEdited(oldName: String?, newName: String?)
    case joinLinkCreated
    case joinLinkEdited
    case joinLinkEnabled
    case joinLinkDisabled
    case generic(String)
  }

  let id: String
  let kind: Kind
  let sentAt: Date
  let messageText: String
  let iconName: String
  let referencedDIDs: [String]
  let referencedNames: [String: String]

  init(
    id: String,
    kind: Kind,
    sentAt: Date,
    messageText: String,
    iconName: String,
    referencedDIDs: [String] = [],
    referencedNames: [String: String] = [:]
  ) {
    self.id = id
    self.kind = kind
    self.sentAt = sentAt
    self.messageText = messageText
    self.iconName = iconName
    self.referencedDIDs = referencedDIDs
    self.referencedNames = referencedNames
  }
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

  var canEdit: Bool { false }
  var canUnsend: Bool { false }
  var isEdited: Bool { false }
  var editedAt: Date? { nil }
  var isTombstone: Bool { false }
  var deletedAt: Date? { nil }
  var isSystemMessage: Bool { false }
  var systemEvent: UnifiedSystemEvent? { nil }
  var systemGroupEvents: [UnifiedSystemEvent]? { nil }
  var isSystemGroup: Bool { false }
  var isExpanded: Bool { false }
  var replyContext: UnifiedMessageReplyContext? { nil }
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
