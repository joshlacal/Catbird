#if DEBUG
import CatbirdMLSCore
import Petrel
import SwiftUI

/// Presentation fixture for the two conversation kinds, launched with
/// `--conversation-kind-ui-fixture=<state>`. It renders the real views against canned data and
/// makes no network or MLS calls.
///
/// States: `capable`, `incapable` and `unknown` show the new conversation screen after a
/// person is picked; `inbox` shows a Bluesky DM and an encrypted chat with the same person as
/// two separate rows.
struct ConversationKindUIFixture: View {
  static let launchPrefix = "--conversation-kind-ui-fixture="
  static let accountDID = "did:plc:kindfixtureself0000000000"
  static let peer = NewConversationRecipient(
    did: "did:plc:kindfixturepeer0000000000", handle: "alex.example", displayName: "Alex Rivera",
    avatarURL: nil)

  static var isRequested: Bool {
    ProcessInfo.processInfo.arguments.contains { $0.hasPrefix(launchPrefix) }
  }

  private var state: String {
    ProcessInfo.processInfo.arguments.first { $0.hasPrefix(Self.launchPrefix) }
      .map { String($0.dropFirst(Self.launchPrefix.count)) } ?? "capable"
  }

  @State private var appState: AppState?
  @State private var model: NewConversationKindModel?

  var body: some View {
    Group {
      if let appState {
        NavigationStack {
          if state == "inbox" {
            inbox
              .navigationTitle("Messages")
          } else if let model {
            ConversationKindChooserView(model: model, onChoose: { _ in }, onChangePerson: {})
              .navigationTitle("Start a Conversation")
              .toolbarTitleDisplayMode(.inline)
          }
        }
        .environment(appState)
      } else {
        ProgressView()
      }
    }
    .task {
      let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
      appState = AppState(userDID: Self.accountDID, client: client)
      let capability: MLSChatCapability
      switch state {
      case "incapable": capability = .incapable(.missingKEMKey)
      case "unknown": capability = .unknown(.network)
      default: capability = .capable
      }
      let model = NewConversationKindModel(
        recipient: Self.peer,
        checkCapability: { _, _ in capability },
        selfReadiness: { .ready }
      )
      self.model = model
      await model.load()
    }
  }

  @ViewBuilder
  private var inbox: some View {
    List {
      if let convo = Self.blueskyConversation() {
        ConversationRow(convo: convo, currentUserDID: Self.accountDID)
      }
      MLSConversationRowView(
        conversation: MLSConversationModel(
          conversationID: "550e8400-e29b-41d4-a716-446655440000",
          currentUserDID: Self.accountDID,
          groupID: Data([0x01]),
          title: Self.peer.displayName
        ),
        participants: [Self.peer.participant],
        recentMemberChange: nil,
        unreadCount: 0
      )
    }
    .listStyle(.plain)
  }

  private static func blueskyConversation() -> ChatBskyConvoDefs.ConvoView? {
    guard let me = try? ChatBskyActorDefs.ProfileViewBasic(
      did: DID(didString: accountDID), handle: Handle(handleString: "me.example"),
      displayName: "Me", avatar: nil, associated: nil, viewer: nil, labels: nil,
      createdAt: nil, chatDisabled: nil, verification: nil, kind: nil),
      let alex = try? ChatBskyActorDefs.ProfileViewBasic(
        did: DID(didString: peer.did), handle: Handle(handleString: peer.handle),
        displayName: peer.displayName, avatar: nil, associated: nil, viewer: nil, labels: nil,
        createdAt: nil, chatDisabled: nil, verification: nil, kind: nil)
    else { return nil }
    return ChatBskyConvoDefs.ConvoView(
      id: "3kfixtureconvo", rev: "rev-1", members: [me, alex], lastMessage: nil,
      lastReaction: nil, muted: false, status: .accepted, unreadCount: 0, kind: nil)
  }
}
#endif
