import Foundation

/// Both UIKit presentations use these actions and the same eligibility rules.
enum ChatMessageMenuAction: Equatable {
  case reaction(String)
  case moreReactions
  case reply
  case copy
  case deleteForMe
  case report
  case edit
  case unsend

  var title: String {
    switch self {
    case .reaction(let emoji): emoji
    case .moreReactions: "More Reactions"
    case .reply: "Reply"
    case .copy: "Copy"
    case .deleteForMe: "Delete for Me"
    case .report: "Report"
    case .edit: "Edit"
    case .unsend: "Unsend"
    }
  }

  var identifier: String {
    let key: String
    switch self {
    case .reaction(let emoji): key = "reaction.\(emoji)"
    case .moreReactions: key = "moreReactions"
    case .reply: key = "reply"
    case .copy: key = "copy"
    case .deleteForMe: key = "deleteForMe"
    case .report: key = "report"
    case .edit: key = "edit"
    case .unsend: key = "unsend"
    }
    return "chat.message.\(key)"
  }

  var isDestructive: Bool {
    switch self {
    case .deleteForMe, .report, .unsend: true
    default: false
    }
  }

  var symbolName: String? {
    switch self {
    case .reaction: nil
    case .moreReactions: "plus"
    case .reply: "arrowshape.turn.up.left"
    case .copy: "doc.on.doc"
    case .deleteForMe: "trash"
    case .report: "exclamationmark.bubble"
    case .edit: "square.and.pencil"
    case .unsend: "arrow.uturn.backward"
    }
  }
}

struct ChatMessageMenuCallbacks {
  var canReply: Bool
  var canDelete: Bool
  var canReport: Bool
}

enum ChatMessageMenuActions {
  static func available<Message: UnifiedChatMessage>(
    for message: Message,
    callbacks: ChatMessageMenuCallbacks,
    quickReactions: [String]
  ) -> [ChatMessageMenuAction] {
    guard !message.isSystemMessage, !message.isTombstone else { return [] }
    var actions: [ChatMessageMenuAction] = []
    if message.canReact {
      actions += quickReactions.map(ChatMessageMenuAction.reaction)
      actions.append(.moreReactions)
    }
    if callbacks.canReply && message.canReply { actions.append(.reply) }
    if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { actions.append(.copy) }
    if callbacks.canDelete && message.canDeleteForMe { actions.append(.deleteForMe) }
    if callbacks.canReport && !message.isFromCurrentUser { actions.append(.report) }
    if message.canEdit { actions.append(.edit) }
    if message.canUnsend { actions.append(.unsend) }
    return actions
  }
}

/// A menu may outlive its reusable cell, account, or navigation scene.
struct ChatMessageMenuIdentity: Equatable {
  let messageID: String
  let accountID: String?
  let sceneID: ObjectIdentifier
  let generation: UUID

  func matches(messageID: String, accountID: String?, sceneID: ObjectIdentifier, generation: UUID) -> Bool {
    self == Self(messageID: messageID, accountID: accountID, sceneID: sceneID, generation: generation)
  }
}

#if os(iOS)
import SwiftUI
import UIKit

#if DEBUG
@MainActor
protocol ChatMessageContextMenuFixtureReporting: AnyObject {
  var fixtureNativeContextMenuRequestCount: Int { get }
  var fixtureNativeContextMenuAttemptCount: Int { get }
  var fixtureNativeContextMenuLastStatus: String { get }
  func fixturePresentAccessibleMessageActions(messageID: String)
  func fixtureMessageMenuAnchorStatus(messageID: String) -> String
}
#endif

final class ChatMessageMenuConfigurationIdentifier: NSObject, NSCopying {
  let identity: ChatMessageMenuIdentity

  init(identity: ChatMessageMenuIdentity) {
    self.identity = identity
    super.init()
  }

  nonisolated func copy(with zone: NSZone? = nil) -> Any { self }
}

/// This transparent, noninteractive background supplies native bubble coordinates.
/// It neither replaces the rendered embed nor intercepts its controls or gestures.
struct ChatMessageContextMenuAnchor: UIViewRepresentable {
  let cornerRadius: CGFloat
  let onUpdate: (ChatMessageContextMenuAnchorView) -> Void

  func makeUIView(context: Context) -> ChatMessageContextMenuAnchorView {
    let view = ChatMessageContextMenuAnchorView()
    view.isUserInteractionEnabled = false
    view.isAccessibilityElement = false
    view.backgroundColor = .clear
    return view
  }

  func updateUIView(_ view: ChatMessageContextMenuAnchorView, context: Context) {
    view.cornerRadius = cornerRadius
    view.onUpdate = onUpdate
    onUpdate(view)
  }

  static func dismantleUIView(_ view: ChatMessageContextMenuAnchorView, coordinator: ()) {
    view.onUpdate = nil
  }
}

final class ChatMessageContextMenuAnchorView: UIView {
  var cornerRadius: CGFloat = 18
  var onUpdate: ((ChatMessageContextMenuAnchorView) -> Void)?

  override func didMoveToWindow() {
    super.didMoveToWindow()
    onUpdate?(self)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    onUpdate?(self)
  }
}

final class ChatMessageContextMenuAnchorReference {
  weak var view: ChatMessageContextMenuAnchorView?
  weak var cell: UICollectionViewCell?

  init(view: ChatMessageContextMenuAnchorView, cell: UICollectionViewCell) {
    self.view = view
    self.cell = cell
  }
}
#endif
