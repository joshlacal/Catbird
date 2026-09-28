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
    let did = try DID(didString: account)
    let bytes = Bytes(data: Data([1]))
    let prior = BlueCatbirdChatDefs.MlsAadPriorContext(
      conversationId: bytes, generation: 1, stateVersion: 1, groupId: bytes,
      epoch: 1, groupContextHash: bytes, confirmationTag: bytes, lifecycle: "active")
    let coordinates = BlueCatbirdChatDefs.ConversationCoordinates(
      conversationId: conversationID, generation: 1, stateVersion: 1, groupId: bytes,
      epoch: 1, groupContextHash: bytes, confirmationTag: bytes, lifecycle: .value_active)
    let body = BlueCatbirdChatDefs.ApplicationSendBody(
      signatureDomain: "blue.catbird.chat.application",
      messageId: "650e8400-e29b-41d4-a716-446655440000",
      actorDid: did, actorDeviceId: "device-1", keyId: "key-1", authGeneration: 1,
      prior: coordinates,
      aad: BlueCatbirdChatDefs.ApplicationAad(
        protocolVersion: .value_1, conversationId: bytes, generation: 1,
        messageId: bytes, prior: prior),
      applicationMessage: BlueCatbirdChatDefs.PrivateApplicationMessage(
        framing: "mls", contentType: "application/octet-stream",
        bytes: bytes, sha256: bytes),
      blobBindings: [], signedAt: ATProtocolDate(date: Date()))
    let entry = BlueCatbirdChatDefs.ApplicationEntry(
      entryId: "650e8400-e29b-41d4-a716-446655440000",
      conversationId: conversationID, seq: 5,
      signedRequest: .init(
        body: .blueCatbirdChatDefsApplicationSendBody(body), signature: bytes),
      receivedAt: ATProtocolDate(date: Date()))
    return try #require(MLSMessageAdapter(
      messageView: entry, payload: payload, senderDID: account, currentUserDID: account))
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
