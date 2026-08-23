//
//  MessagesSchemaResolutionTests.swift
//  CatbirdTests
//
//  Network-free coverage for the MessagesSchema recipient / conversation
//  resolution helpers: the pure member-set conversation matcher, spoken-name
//  matching against a fixture ChatDirectory, and destination → recipient
//  mapping (including the multi-recipient and Siri-contact paths).
//
//  The runtime under test is @available(iOS 27.0, *), and Swift Testing's
//  @Suite/@Test macros reject @available annotations — so availability is
//  handled with a runtime guard in each test (they no-op below iOS 27, which
//  never happens under this project's Xcode 27 test destination).
//

import AppIntents
import CatbirdMLSCore
import Foundation
import Testing

@testable import Catbird

#if os(iOS) && canImport(GeoToolbox) && compiler(>=7.0)
/// Fixture builders for the iOS 27-gated MessagesSchema runtime types.
@available(iOS 27.0, *)
private enum Fixtures {
  static let selfDID = "did:plc:self00000000000000000000"
  static let alexDID = "did:plc:alex00000000000000000000"
  static let samDID = "did:plc:sam000000000000000000000"

  static func member(
    _ did: String, convo: String, displayName: String? = nil, handle: String? = nil
  ) -> MLSMemberModel {
    MLSMemberModel(
      memberID: "\(convo)-\(did)",
      conversationID: convo,
      currentUserDID: selfDID,
      did: did,
      handle: handle,
      displayName: displayName,
      leafIndex: 0
    )
  }

  static func conversation(_ id: String, title: String? = nil) -> MLSConversationModel {
    MLSConversationModel(
      conversationID: id, currentUserDID: selfDID, groupID: Data([0x01]), title: title)
  }

  /// Two real v4 identities: the first is a 1:1 with Alex, the second is a
  /// titled group with Alex + Sam.
  static func directory() -> MessagesSchemaRuntime.ChatDirectory {
    MessagesSchemaRuntime.ChatDirectory(
      conversations: [
        conversation("550e8400-e29b-41d4-a716-446655440000"),
        conversation("6ba7b810-9dad-41d1-80b4-00c04fd430c8", title: "Weekend Plans")
      ],
      membersByConvoID: [
        "550e8400-e29b-41d4-a716-446655440000": [
          member(selfDID, convo: "550e8400-e29b-41d4-a716-446655440000", displayName: "Me"),
          member(alexDID, convo: "550e8400-e29b-41d4-a716-446655440000", displayName: "Alex Rivera", handle: "alex.bsky.social"),
        ],
        "6ba7b810-9dad-41d1-80b4-00c04fd430c8": [
          member(selfDID, convo: "6ba7b810-9dad-41d1-80b4-00c04fd430c8", displayName: "Me"),
          member(alexDID, convo: "6ba7b810-9dad-41d1-80b4-00c04fd430c8", displayName: "Alex Rivera", handle: "alex.bsky.social"),
          member(samDID, convo: "6ba7b810-9dad-41d1-80b4-00c04fd430c8", displayName: "Sam Chen", handle: "sam.bsky.social"),
        ],
      ],
      currentUserDID: selfDID
    )
  }

  static func didsByConvo(
    _ directory: MessagesSchemaRuntime.ChatDirectory
  ) -> [String: [String]] {
    directory.membersByConvoID.mapValues { $0.map(\.did) }
  }
}
#endif

@Suite("MessagesSchema recipient & conversation resolution")
struct MessagesSchemaResolutionTests {

#if os(iOS) && canImport(GeoToolbox) && compiler(>=7.0)
  // MARK: - conversationID(matching:) — pure member-set matcher

  @Test func oneToOneConversationMatchesBySingleRecipient() {
    guard #available(iOS 27.0, *) else { return }
    let directory = Fixtures.directory()
    let match = MessagesSchemaRuntime.conversationID(
      matching: [Fixtures.alexDID],
      in: Fixtures.didsByConvo(directory),
      conversationOrder: ["550e8400-e29b-41d4-a716-446655440000", "6ba7b810-9dad-41d1-80b4-00c04fd430c8"],
      selfDID: Fixtures.selfDID
    )
    #expect(match == "550e8400-e29b-41d4-a716-446655440000")
  }

  @Test func groupConversationMatchesByFullMemberSet() {
    guard #available(iOS 27.0, *) else { return }
    let directory = Fixtures.directory()
    let match = MessagesSchemaRuntime.conversationID(
      matching: [Fixtures.samDID, Fixtures.alexDID],  // order must not matter
      in: Fixtures.didsByConvo(directory),
      conversationOrder: ["550e8400-e29b-41d4-a716-446655440000", "6ba7b810-9dad-41d1-80b4-00c04fd430c8"],
      selfDID: Fixtures.selfDID
    )
    #expect(match == "6ba7b810-9dad-41d1-80b4-00c04fd430c8")
  }

  @Test func matchingIsCaseInsensitiveAndExcludesSelf() {
    guard #available(iOS 27.0, *) else { return }
    let directory = Fixtures.directory()
    let match = MessagesSchemaRuntime.conversationID(
      matching: [Fixtures.alexDID.uppercased()],
      in: Fixtures.didsByConvo(directory),
      conversationOrder: ["550e8400-e29b-41d4-a716-446655440000", "6ba7b810-9dad-41d1-80b4-00c04fd430c8"],
      selfDID: Fixtures.selfDID.uppercased()
    )
    #expect(match == "550e8400-e29b-41d4-a716-446655440000")
  }

  @Test func unknownMemberSetMatchesNothing() {
    guard #available(iOS 27.0, *) else { return }
    let directory = Fixtures.directory()
    let match = MessagesSchemaRuntime.conversationID(
      matching: [Fixtures.samDID],  // Sam only exists alongside Alex in convo-2
      in: Fixtures.didsByConvo(directory),
      conversationOrder: ["550e8400-e29b-41d4-a716-446655440000", "6ba7b810-9dad-41d1-80b4-00c04fd430c8"],
      selfDID: Fixtures.selfDID
    )
    #expect(match == nil)
  }

  @Test func emptyRecipientListMatchesNothing() {
    guard #available(iOS 27.0, *) else { return }
    let match = MessagesSchemaRuntime.conversationID(
      matching: [],
      in: [:],
      conversationOrder: [],
      selfDID: Fixtures.selfDID
    )
    #expect(match == nil)
  }

  // MARK: - member(matchingName:) — spoken-name lookup

  @Test func memberMatchesByDisplayNameFragment() {
    guard #available(iOS 27.0, *) else { return }
    let directory = Fixtures.directory()
    let match = MessagesSchemaRuntime.member(matchingName: "alex", in: directory)
    #expect(match?.did == Fixtures.alexDID)
  }

  @Test func memberMatchesByHandle() {
    guard #available(iOS 27.0, *) else { return }
    let directory = Fixtures.directory()
    let match = MessagesSchemaRuntime.member(matchingName: "sam.bsky", in: directory)
    #expect(match?.did == Fixtures.samDID)
  }

  @Test func unknownNameMatchesNoMember() {
    guard #available(iOS 27.0, *) else { return }
    let directory = Fixtures.directory()
    #expect(MessagesSchemaRuntime.member(matchingName: "Nobody Realname", in: directory) == nil)
    #expect(MessagesSchemaRuntime.member(matchingName: "   ", in: directory) == nil)
  }

  // MARK: - recipients(for:directory:)

  @Test func recipientsMapsAllEntitiesNotJustFirst() throws {
    guard #available(iOS 27.0, *) else { return }
    let directory = Fixtures.directory()
    let destination = CatbirdMessagesDestination.recipients([
      CatbirdMessagesPersonEntity(id: Fixtures.alexDID, displayName: "Alex Rivera"),
      CatbirdMessagesPersonEntity(id: Fixtures.samDID, displayName: "Sam Chen"),
    ])
    let resolved = try MessagesSchemaRuntime.recipients(for: destination, directory: directory)
    #expect(resolved.map(\.did) == [Fixtures.alexDID, Fixtures.samDID])
  }

  @Test func emptyRecipientEntityListThrows() {
    guard #available(iOS 27.0, *) else { return }
    let directory = Fixtures.directory()
    #expect(throws: IntentError.self) {
      _ = try MessagesSchemaRuntime.recipients(
        for: CatbirdMessagesDestination.recipients([]), directory: directory)
    }
  }

  @Test func siriContactResolvesByNameAgainstChatDirectory() throws {
    guard #available(iOS 27.0, *) else { return }
    let directory = Fixtures.directory()
    let person = IntentPerson(
      identifier: .unknown, name: .displayName("Alex Rivera"), handle: nil, isMe: false)
    let resolved = try MessagesSchemaRuntime.recipients(
      for: CatbirdMessagesDestination.persons([person]), directory: directory)
    #expect(resolved.count == 1)
    #expect(resolved.first?.did == Fixtures.alexDID)
    #expect(resolved.first?.displayName == "Alex Rivera")
  }

  @Test func siriContactWithUnknownNameThrows() {
    guard #available(iOS 27.0, *) else { return }
    let directory = Fixtures.directory()
    let person = IntentPerson(
      identifier: .unknown, name: .displayName("Complete Stranger"), handle: nil, isMe: false)
    #expect(throws: IntentError.self) {
      _ = try MessagesSchemaRuntime.recipients(
        for: CatbirdMessagesDestination.persons([person]), directory: directory)
    }
  }

  // MARK: - spokenName(for:)

  @Test func spokenNameUsesDisplayNameAndComponents() {
    guard #available(iOS 27.0, *) else { return }
    let byDisplayName = IntentPerson(
      identifier: .unknown, name: .displayName("Alex Rivera"), handle: nil, isMe: false)
    #expect(MessagesSchemaRuntime.spokenName(for: byDisplayName) == "Alex Rivera")

    var components = PersonNameComponents()
    components.givenName = "Sam"
    components.familyName = "Chen"
    let byComponents = IntentPerson(
      identifier: .unknown, name: .components(components), handle: nil, isMe: false)
    #expect(MessagesSchemaRuntime.spokenName(for: byComponents)?.contains("Sam") == true)
  }
#endif

  @Test @MainActor func chatDraftHandoffConsumesMatchingDraftExactlyOnce() {
    ChatDraftHandoff.shared.store(
      PendingChatDraft(conversationID: "550e8400-e29b-41d4-a716-446655440000", text: "Draft from Siri"))

    #expect(ChatDraftHandoff.shared.consume(for: "6ba7b810-9dad-41d1-80b4-00c04fd430c8") == nil)
    #expect(ChatDraftHandoff.shared.consume(for: "550e8400-e29b-41d4-a716-446655440000") == "Draft from Siri")
    #expect(ChatDraftHandoff.shared.consume(for: "550e8400-e29b-41d4-a716-446655440000") == nil)
  }

  @Test @MainActor func wildcardChatDraftTargetsNextConversation() {
    ChatDraftHandoff.shared.store(
      PendingChatDraft(conversationID: nil, text: "Choose a conversation"))

    #expect(ChatDraftHandoff.shared.consume(for: "550e8400-e29b-41d4-a716-446655440000") == "Choose a conversation")
    #expect(ChatDraftHandoff.shared.consume(for: "6ba7b810-9dad-41d1-80b4-00c04fd430c8") == nil)
  }
}
