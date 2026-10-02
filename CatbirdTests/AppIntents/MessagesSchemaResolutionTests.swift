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
import Petrel
import Foundation
import Testing

@testable import Catbird

#if os(iOS) && canImport(GeoToolbox) && compiler(>=6.4)
/// Fixture builders for the iOS 27-gated MessagesSchema runtime types.
@available(iOS 27.0, *)
private enum Fixtures {
  static let selfDID = "did:plc:self00000000000000000000"
  static let alexDID = "did:plc:alex00000000000000000000"
  static let samDID = "did:plc:sam000000000000000000000"

  static func member(
    _ did: String, convo: String, displayName: String? = nil, handle: String? = nil
  ) -> MessagesSchemaRuntime.Member {
    MessagesSchemaRuntime.Member(did: did, displayName: displayName, handle: handle)
  }

  static func conversation(_ id: String, title: String? = nil) -> ChatBskyConvoDefs.ConvoView {
    ChatBskyConvoDefs.ConvoView(
      id: id, rev: "fixture", members: [], lastMessage: nil, lastReaction: nil,
      muted: false, status: .accepted, unreadCount: 0, kind: nil)
  }

  /// Two stable conversation identities: the first is a 1:1 with Alex, the second is a
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

#if os(iOS) && canImport(GeoToolbox) && compiler(>=6.4)
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
    let handoff = ChatDraftHandoff(schedulePublication: { $0() })
    let sceneID = UUID()
    let draft = PendingChatDraft(
      accountDID: "did:plc:alice", sceneID: sceneID,
      conversationID: "conversation-a", text: "Draft from Siri")
    handoff.store(draft)
    handoff.bind(
      id: draft.id, accountDID: draft.accountDID, sceneID: sceneID,
      conversationID: draft.conversationID)

    #expect(handoff.peek(
      sceneID: sceneID, accountDID: draft.accountDID, conversationID: "conversation-b") == nil)
    #expect(handoff.consume(
      sceneID: sceneID, accountDID: draft.accountDID, conversationID: "conversation-a",
      expectedID: draft.id)?.text == "Draft from Siri")
    #expect(handoff.consume(
      sceneID: sceneID, accountDID: draft.accountDID, conversationID: "conversation-a",
      expectedID: draft.id) == nil)
  }

  @Test @MainActor func wildcardChatDraftIsLimitedToBoundSceneAndAccount() {
    let handoff = ChatDraftHandoff(schedulePublication: { $0() })
    let sceneID = UUID()
    let draft = PendingChatDraft(
      accountDID: "did:plc:alice", conversationID: nil, text: "Choose a conversation")
    handoff.store(draft)
    handoff.bind(
      id: draft.id, accountDID: draft.accountDID, sceneID: sceneID, conversationID: nil)

    #expect(handoff.peek(
      sceneID: UUID(), accountDID: draft.accountDID, conversationID: "conversation-a") == nil)
    #expect(handoff.consume(
      sceneID: sceneID, accountDID: "did:plc:bob", conversationID: "conversation-a",
      expectedID: draft.id) == nil)
    #expect(handoff.consume(
      sceneID: sceneID, accountDID: draft.accountDID, conversationID: "conversation-a",
      expectedID: draft.id)?.text == "Choose a conversation")
  }

  @Test @MainActor func capturedSceneDraftRemainsUnclaimedUntilRouteAcceptance() {
    let handoff = ChatDraftHandoff(schedulePublication: { $0() })
    let sceneID = UUID()
    let draft = PendingChatDraft(
      accountDID: "did:plc:alice", sceneID: sceneID,
      conversationID: "conversation-a", text: "Keep this while the route waits")
    handoff.store(draft)

    #expect(handoff.peek(
      sceneID: sceneID, accountDID: draft.accountDID, conversationID: "conversation-a") == nil)
    #expect(handoff.consume(
      sceneID: sceneID, accountDID: draft.accountDID, conversationID: "conversation-a",
      expectedID: draft.id) == nil)
    #expect(handoff.bind(
      id: draft.id, accountDID: draft.accountDID, sceneID: UUID(),
      conversationID: draft.conversationID) == nil)
    #expect(handoff.bind(
      id: draft.id, accountDID: "did:plc:bob", sceneID: sceneID,
      conversationID: draft.conversationID) == nil)

    #expect(handoff.bind(
      id: draft.id, accountDID: draft.accountDID, sceneID: sceneID,
      conversationID: draft.conversationID) == draft)
  }

  @Test @MainActor func initiallyUnscopedDraftBindsOnlyOnce() {
    let handoff = ChatDraftHandoff(schedulePublication: { $0() })
    let sceneID = UUID()
    let draft = PendingChatDraft(
      accountDID: "did:plc:alice", conversationID: nil, text: "Retained with no scene")
    handoff.store(draft)
    #expect(handoff.peek(
      sceneID: sceneID, accountDID: draft.accountDID, conversationID: "conversation-a") == nil)

    let bound = handoff.bind(
      id: draft.id, accountDID: draft.accountDID, sceneID: sceneID,
      conversationID: "conversation-a")
    #expect(bound?.id == draft.id)
    #expect(bound?.text == draft.text)
    #expect(bound?.sceneID == sceneID)
    #expect(bound?.conversationID == "conversation-a")
    #expect(handoff.bind(
      id: draft.id, accountDID: draft.accountDID, sceneID: UUID(),
      conversationID: "conversation-a") == nil)
    #expect(handoff.bind(
      id: draft.id, accountDID: draft.accountDID, sceneID: sceneID,
      conversationID: "conversation-b") == nil)
    #expect(handoff.peek(
      sceneID: sceneID, accountDID: draft.accountDID, conversationID: "conversation-a") == bound)
  }

  @Test @MainActor func peekAndStaleClaimKeepQueuedDrafts() {
    let handoff = ChatDraftHandoff(schedulePublication: { $0() })
    let sceneID = UUID()
    let first = PendingChatDraft(
      accountDID: "did:plc:alice", sceneID: sceneID,
      conversationID: "conversation-a", text: "First draft")
    let second = PendingChatDraft(
      accountDID: first.accountDID, sceneID: sceneID,
      conversationID: first.conversationID, text: "Second draft")
    for draft in [first, second] {
      handoff.store(draft)
      handoff.bind(
        id: draft.id, accountDID: draft.accountDID, sceneID: sceneID,
        conversationID: draft.conversationID)
    }

    // A composer with existing text can inspect repeatedly without accepting.
    #expect(handoff.peek(
      sceneID: sceneID, accountDID: first.accountDID, conversationID: "conversation-a") == first)
    #expect(handoff.peek(
      sceneID: sceneID, accountDID: first.accountDID, conversationID: "conversation-a") == first)
    #expect(handoff.consume(
      sceneID: sceneID, accountDID: first.accountDID, conversationID: "conversation-a",
      expectedID: second.id) == nil)
    #expect(handoff.consume(
      sceneID: sceneID, accountDID: first.accountDID, conversationID: "conversation-a",
      expectedID: first.id) == first)
    #expect(handoff.consume(
      sceneID: sceneID, accountDID: first.accountDID, conversationID: "conversation-a",
      expectedID: first.id) == nil)
    #expect(handoff.peek(
      sceneID: sceneID, accountDID: second.accountDID, conversationID: "conversation-a") == second)
  }

  @Test @MainActor func storingSameTokenCannotReplaceItsTextOrScope() {
    let handoff = ChatDraftHandoff(schedulePublication: { $0() })
    let sceneID = UUID()
    let draft = PendingChatDraft(
      accountDID: "did:plc:alice", sceneID: sceneID,
      conversationID: "conversation-a", text: "Original text")
    #expect(handoff.store(draft))
    #expect(handoff.store(draft))
    #expect(!handoff.store(PendingChatDraft(
      id: draft.id, accountDID: "did:plc:bob", sceneID: UUID(),
      conversationID: "conversation-b", text: "Replacement text")))
    handoff.bind(
      id: draft.id, accountDID: draft.accountDID, sceneID: sceneID,
      conversationID: draft.conversationID)
    #expect(handoff.consume(
      sceneID: sceneID, accountDID: draft.accountDID, conversationID: "conversation-a",
      expectedID: draft.id) == draft)
    #expect(handoff.peek(
      sceneID: sceneID, accountDID: draft.accountDID, conversationID: "conversation-a") == nil)
    #expect(!handoff.store(draft), "A consumed token must not be replayed.")
  }

  @Test @MainActor func sceneInvalidationRetainsTextWithoutRevivingDelivery() {
    let handoff = ChatDraftHandoff(schedulePublication: { $0() })
    let sceneID = UUID()
    let draft = PendingChatDraft(
      accountDID: "did:plc:alice", sceneID: sceneID,
      conversationID: "conversation-a", text: "Keep my typed draft")
    handoff.store(draft)
    handoff.bind(
      id: draft.id, accountDID: draft.accountDID, sceneID: sceneID,
      conversationID: draft.conversationID)

    handoff.invalidate(sceneID: sceneID, accountDID: "did:plc:bob")
    #expect(handoff.peek(
      sceneID: sceneID, accountDID: draft.accountDID, conversationID: "conversation-a") == draft)
    handoff.invalidate(sceneID: sceneID, accountDID: draft.accountDID)
    #expect(handoff.peek(
      sceneID: sceneID, accountDID: draft.accountDID, conversationID: "conversation-a") == nil)
    #expect(handoff.consume(
      sceneID: sceneID, accountDID: draft.accountDID, conversationID: "conversation-a",
      expectedID: draft.id) == nil)
    #expect(handoff.bind(
      id: draft.id, accountDID: draft.accountDID, sceneID: sceneID,
      conversationID: draft.conversationID) == nil)
    #expect(handoff.retainedDraft(id: draft.id, accountDID: draft.accountDID)?.text == draft.text)
    #expect(handoff.retainedDraft(id: draft.id, accountDID: "did:plc:bob") == nil)
  }

  @MainActor
  private final class PublicationQueue {
    private var queued: [ChatDraftHandoff.Publication] = []

    func enqueue(_ publication: @escaping ChatDraftHandoff.Publication) {
      queued.append(publication)
    }

    func publish() {
      let ready = queued
      queued.removeAll()
      for publication in ready { publication() }
    }
  }

  @MainActor
  private final class PublicationObservation {
    var count = 0
    var appliedTexts: [String] = []
  }

  @Test @MainActor func deferredPublicationSurvivesNavigationRejectionWithoutConsumption() {
    let publications = PublicationQueue()
    let handoff = ChatDraftHandoff(schedulePublication: publications.enqueue)
    let observation = PublicationObservation()
    let sceneID = UUID()
    let conversationID = "550e8400-e29b-41d4-a716-446655440000"
    let draft = PendingChatDraft(
      accountDID: "did:plc:alice", sceneID: sceneID,
      conversationID: conversationID, text: "Keep this if tab selection invalidates the scene")
    let token = NotificationCenter.default.addObserver(
      forName: ChatDraftHandoff.didStoreDraft, object: handoff, queue: nil
    ) { _ in
      MainActor.assumeIsolated {
        observation.count += 1
        if let pending = handoff.peek(
          sceneID: sceneID, accountDID: draft.accountDID, conversationID: conversationID
        ), let claimed = handoff.consume(
          sceneID: sceneID, accountDID: draft.accountDID, conversationID: conversationID,
          expectedID: pending.id
        ) {
          observation.appliedTexts.append(claimed.text)
        }
      }
    }
    defer { NotificationCenter.default.removeObserver(token) }

    handoff.store(draft)
    handoff.bind(
      id: draft.id, accountDID: draft.accountDID, sceneID: sceneID, conversationID: conversationID)
    #expect(observation.count == 0)
    #expect(handoff.peek(
      sceneID: sceneID, accountDID: draft.accountDID, conversationID: conversationID) == nil)
    #expect(handoff.consume(
      sceneID: sceneID, accountDID: draft.accountDID, conversationID: conversationID,
      expectedID: draft.id) == nil)

    // Simulate a synchronous tab-selection callback retiring the receiving
    // context before the coordinator returns from delivery.
    handoff.invalidate(sceneID: sceneID, accountDID: draft.accountDID)
    publications.publish()
    #expect(observation.count == 0)
    #expect(observation.appliedTexts.isEmpty)
    #expect(handoff.retainedDraft(id: draft.id, accountDID: draft.accountDID)?.text == draft.text)
  }

  @Test @MainActor func acceptedPublicationClaimsOnceAndKeepsRecoveryText() {
    let publications = PublicationQueue()
    let handoff = ChatDraftHandoff(schedulePublication: publications.enqueue)
    let observation = PublicationObservation()
    let sceneID = UUID()
    let conversationID = "550e8400-e29b-41d4-a716-446655440000"
    let draft = PendingChatDraft(
      accountDID: "did:plc:alice", sceneID: sceneID,
      conversationID: conversationID, text: "Apply exactly once")
    let token = NotificationCenter.default.addObserver(
      forName: ChatDraftHandoff.didStoreDraft, object: handoff, queue: nil
    ) { _ in
      MainActor.assumeIsolated {
        observation.count += 1
        if let pending = handoff.peek(
          sceneID: sceneID, accountDID: draft.accountDID, conversationID: conversationID
        ), let claimed = handoff.consume(
          sceneID: sceneID, accountDID: draft.accountDID, conversationID: conversationID,
          expectedID: pending.id
        ) {
          observation.appliedTexts.append(claimed.text)
        }
      }
    }
    defer { NotificationCenter.default.removeObserver(token) }

    handoff.store(draft)
    handoff.bind(
      id: draft.id, accountDID: draft.accountDID, sceneID: sceneID, conversationID: conversationID)
    #expect(observation.appliedTexts.isEmpty)
    publications.publish()
    publications.publish()
    #expect(observation.count == 1)
    #expect(observation.appliedTexts == [draft.text])
    handoff.invalidate(sceneID: sceneID, accountDID: draft.accountDID)
    #expect(handoff.retainedDraft(id: draft.id, accountDID: draft.accountDID) == draft)
    #expect(handoff.retainedDraft(id: draft.id, accountDID: "did:plc:bob") == nil)
    #expect(handoff.consume(
      sceneID: sceneID, accountDID: draft.accountDID, conversationID: conversationID,
      expectedID: draft.id) == nil)
    #expect(!handoff.store(draft))
  }

  @Test @MainActor func invalidatingAnInFlightDraftPreventsLateBinding() {
    let handoff = ChatDraftHandoff(schedulePublication: { $0() })
    let sceneID = UUID()
    let draft = PendingChatDraft(
      accountDID: "did:plc:alice", sceneID: sceneID, conversationID: nil,
      text: "Still resolving a destination")
    handoff.store(draft)
    handoff.invalidate(sceneID: sceneID, accountDID: draft.accountDID)

    #expect(handoff.bind(
      id: draft.id, accountDID: draft.accountDID, sceneID: sceneID,
      conversationID: "conversation-a") == nil)
    #expect(handoff.retainedDraft(id: draft.id, accountDID: draft.accountDID) == draft)
  }
}
