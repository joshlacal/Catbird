import CatbirdMLSCore
import Foundation
import Petrel
import PetrelCatbird
import Testing
@testable import Catbird

@MainActor
@Suite("MLS system message presentation")
struct MLSSystemMessageAdapterTests {
  private let account = "did:plc:tester"
  private let conversationID = "550e8400-e29b-41d4-a716-446655440000"

  private func adapter(payload: MLSMessagePayload) throws -> MLSMessageAdapter {
    let entry = BlueCatbirdChatDefs.ApplicationEntry(
      convoId: conversationID, id: "650e8400-e29b-41d4-a716-446655440000",
      senderDid: try DID(didString: account), ciphertext: Bytes(data: Data()), epoch: 1, seq: 5)
    return MLSMessageAdapter(messageView: entry, payload: payload, senderDID: account, currentUserDID: account)
  }

  @Test func onlyStructuredSystemMessagesGetNoticeStyleAndCannotBeEdited() throws {
    let system = try adapter(payload: MLSMessagePayload(messageType: .system, text: "history_boundary.new_member"))
    #expect(system.isSystemMessage)
    #expect(system.text == "You joined this conversation")
    #expect(!system.canEdit && !system.canUnsend)
    let ordinary = try adapter(payload: MLSMessagePayload(messageType: .text, text: "history_boundary.new_member"))
    #expect(!ordinary.isSystemMessage)
    #expect(ordinary.text == "history_boundary.new_member")
    #expect(ordinary.canEdit && ordinary.canUnsend)
    let unverifiedLeave = try adapter(payload: MLSMessagePayload(messageType: .system, text: "membership.left"))
    #expect(unverifiedLeave.text == "Conversation membership changed")
  }

  @Test func profileRebuildPreservesSystemStyleAndIdentity() throws {
    let original = try adapter(payload: MLSMessagePayload(messageType: .system, text: "history_boundary.new_member"))
    let source = MLSConversationDataSource(conversationId: conversationID, currentUserDID: account, appState: nil)
    source.ingestConfirmedMessageForTesting(original)
    source.preloadProfiles([account: .init(did: account, handle: "tester.example", displayName: "Tester", avatarURL: nil)])
    let rebuilt = try #require(source.messages.first)
    #expect(rebuilt.id == original.id)
    #expect(rebuilt.isSystemMessage)
    #expect(rebuilt.text == original.text)
    #expect(!rebuilt.canEdit && !rebuilt.canUnsend)
  }
}
