import Foundation
import Testing
@testable import Catbird

@MainActor
struct ChatMessageMenuActionTests {
  private let quickReactions = ["👍", "❤️", "😂", "😮", "😢", "🙏"]
  private let allCallbacks = ChatMessageMenuCallbacks(canReply: true, canDelete: true, canReport: true)
  private let noCallbacks = ChatMessageMenuCallbacks(canReply: false, canDelete: false, canReport: false)

  private var reactionActions: [ChatMessageMenuAction] {
    quickReactions.map { .reaction($0) } + [.moreReactions]
  }

  @Test("Incoming messages expose supported actions; own messages cannot be reported")
  func incomingAndOwnMessageEligibility() {
    let incoming = Message()
    var own = incoming
    own.isFromCurrentUser = true

    #expect(ChatMessageMenuActions.available(for: incoming, callbacks: allCallbacks,
      quickReactions: quickReactions) == reactionActions + [.reply, .copy, .deleteForMe, .report])
    #expect(ChatMessageMenuActions.available(for: own, callbacks: allCallbacks,
      quickReactions: quickReactions) == reactionActions + [.reply, .copy, .deleteForMe])
  }

  @Test("Unavailable callbacks hide only their corresponding menu commands")
  func callbackAvailabilityDoesNotImplyOtherCapabilities() {
    let message = Message()
    #expect(ChatMessageMenuActions.available(for: message, callbacks: noCallbacks,
      quickReactions: quickReactions) == reactionActions + [.copy])

    let replyOnly = ChatMessageMenuCallbacks(canReply: true, canDelete: false, canReport: false)
    #expect(ChatMessageMenuActions.available(for: message, callbacks: replyOnly,
      quickReactions: quickReactions) == reactionActions + [.reply, .copy])

    let deleteOnly = ChatMessageMenuCallbacks(canReply: false, canDelete: true, canReport: false)
    #expect(ChatMessageMenuActions.available(for: message, callbacks: deleteOnly,
      quickReactions: quickReactions) == reactionActions + [.copy, .deleteForMe])

    let reportOnly = ChatMessageMenuCallbacks(canReply: false, canDelete: false, canReport: true)
    #expect(ChatMessageMenuActions.available(for: message, callbacks: reportOnly,
      quickReactions: quickReactions) == reactionActions + [.copy, .report])
  }

  @Test("Empty or whitespace-only embedded messages retain actions without an empty Copy command",
    arguments: ["", " \t\n\r", "\u{00A0}"])
  func embedWithoutCopyableText(_ text: String) throws {
    let url = try #require(URL(string: "https://menu-fixture.invalid/post"))
    var message = Message(text: text)
    message.embed = .link(LinkEmbedData(url: url, title: "Supplied local metadata",
      description: "The embed remains actionable without a message body.", thumbnailURL: nil))

    #expect(ChatMessageMenuActions.available(for: message, callbacks: allCallbacks,
      quickReactions: quickReactions) == reactionActions + [.reply, .deleteForMe, .report])
  }

  @Test("Surrounding whitespace does not hide Copy when the message has content")
  func copyRemainsAvailableForNonemptyText() {
    let message = Message(text: " \nA message with surrounding whitespace.\t ")
    #expect(ChatMessageMenuActions.available(for: message, callbacks: noCallbacks,
      quickReactions: []) == [.moreReactions, .copy])
  }

  @Test("Tombstones and system messages suppress every action, including privileged capabilities")
  func noninteractiveMessagesCannotExposeCommands() {
    var tombstone = Message(canEdit: true, canUnsend: true, isTombstone: true)
    let system = Message(canEdit: true, canUnsend: true, isSystemMessage: true)

    #expect(ChatMessageMenuActions.available(for: tombstone, callbacks: allCallbacks,
      quickReactions: quickReactions).isEmpty)
    #expect(ChatMessageMenuActions.available(for: system, callbacks: allCallbacks,
      quickReactions: quickReactions).isEmpty)

    tombstone.isSystemMessage = true
    #expect(ChatMessageMenuActions.available(for: tombstone, callbacks: allCallbacks,
      quickReactions: quickReactions).isEmpty)
  }

  @Test("Edit and unsend follow adapter capabilities independently of ownership and other callbacks",
    arguments: [false, true], [false, true])
  func editAndUnsendCapabilities(canEdit: Bool, canUnsend: Bool) {
    for isFromCurrentUser in [false, true] {
      let message = Message(isFromCurrentUser: isFromCurrentUser, canEdit: canEdit, canUnsend: canUnsend)
      let actions = ChatMessageMenuActions.available(for: message, callbacks: noCallbacks,
        quickReactions: quickReactions)
      let capabilityActions: [ChatMessageMenuAction] = (canEdit ? [.edit] : []) + (canUnsend ? [.unsend] : [])
      #expect(actions == reactionActions + [.copy] + capabilityActions)
    }
  }

  @Test("Custom quick reactions keep their supplied order and an empty list still opens the full picker")
  func configuredReactionsAndPickerRemainAvailable() {
    let message = Message(text: "")
    #expect(ChatMessageMenuActions.available(for: message, callbacks: noCallbacks,
      quickReactions: ["🦋", "🎉"]) == [.reaction("🦋"), .reaction("🎉"), .moreReactions])
    #expect(ChatMessageMenuActions.available(for: message, callbacks: noCallbacks,
      quickReactions: []) == [.moreReactions])
  }

  @Test("Menu metadata distinguishes reaction choices and marks only destructive commands")
  func metadataSupportsAccessibleDistinctCommands() {
    let message = Message(canEdit: true, canUnsend: true)
    let actions = ChatMessageMenuActions.available(for: message, callbacks: allCallbacks,
      quickReactions: quickReactions)

    #expect(Set(actions.map(\.identifier)).count == actions.count)
    #expect(actions.allSatisfy { !$0.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    #expect(actions.allSatisfy { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    #expect(actions.filter(\.isDestructive) == [.deleteForMe, .report, .unsend])
    #expect(ChatMessageMenuAction.reaction("👍").title != ChatMessageMenuAction.reaction("❤️").title)
    #expect(ChatMessageMenuAction.moreReactions.identifier != ChatMessageMenuAction.reaction("👍").identifier)
  }

  @Test("A menu identity rejects replacement messages, switched accounts, different scenes and later presentations")
  func staleMenuIdentityIsRejected() {
    let scene = SceneToken()
    let replacementScene = SceneToken()
    let generation = UUID()
    let nextGeneration = UUID()
    let identity = ChatMessageMenuIdentity(messageID: "message-1", accountID: "did:plc:viewer",
      sceneID: ObjectIdentifier(scene), generation: generation)

    // ObjectIdentifier does not retain its object; keep both scenes alive for every comparison.
    withExtendedLifetime((scene, replacementScene)) {
      #expect(identity.matches(messageID: "message-1", accountID: "did:plc:viewer",
        sceneID: ObjectIdentifier(scene), generation: generation))
      #expect(!identity.matches(messageID: "message-2", accountID: "did:plc:viewer",
        sceneID: ObjectIdentifier(scene), generation: generation))
      #expect(!identity.matches(messageID: "message-1", accountID: "did:plc:another-viewer",
        sceneID: ObjectIdentifier(scene), generation: generation))
      #expect(!identity.matches(messageID: "message-1", accountID: nil,
        sceneID: ObjectIdentifier(scene), generation: generation))
      #expect(!identity.matches(messageID: "message-1", accountID: "did:plc:viewer",
        sceneID: ObjectIdentifier(replacementScene), generation: generation))
      #expect(!identity.matches(messageID: "message-1", accountID: "did:plc:viewer",
        sceneID: ObjectIdentifier(scene), generation: nextGeneration))
    }
  }

  @Test("An accountless menu matches only another accountless context")
  func nilAccountIsAnIdentityValueNotAWildcard() {
    let scene = SceneToken()
    let generation = UUID()
    let identity = ChatMessageMenuIdentity(messageID: "message-1", accountID: nil,
      sceneID: ObjectIdentifier(scene), generation: generation)

    withExtendedLifetime(scene) {
      #expect(identity.matches(messageID: "message-1", accountID: nil,
        sceneID: ObjectIdentifier(scene), generation: generation))
      #expect(!identity.matches(messageID: "message-1", accountID: "did:plc:viewer",
        sceneID: ObjectIdentifier(scene), generation: generation))
    }
  }

  private final class SceneToken {}

  private struct Message: UnifiedChatMessage {
    var id = "message-1"
    var text = "A local message"
    var isFromCurrentUser = false
    var canEdit = false
    var canUnsend = false
    var isTombstone = false
    var isSystemMessage = false
    var reactions: [UnifiedReaction] = []
    var embed: UnifiedEmbed?
    var sendState: MessageSendState = .sent
    var senderID: String { isFromCurrentUser ? "did:plc:viewer" : "did:plc:peer" }
    var senderDisplayName: String? { isFromCurrentUser ? "Local viewer" : "Local peer" }
    var senderAvatarURL: URL? { nil }
    var sentAt: Date { Date(timeIntervalSince1970: 1_780_000_000) }
  }
}
