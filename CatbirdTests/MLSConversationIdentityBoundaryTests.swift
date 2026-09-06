import CatbirdMLSCore
import Foundation
import PetrelCatbird
import Testing
@testable import Catbird

@Suite("MLS conversation identity boundary")
struct MLSConversationIdentityBoundaryTests {
  private let canonicalID = "550e8400-e29b-41d4-a716-446655440000"
  private let groupID = "00112233445566778899aabbccddeeff"

  @Test("only lowercase RFC 4122 UUIDv4 stable IDs are accepted")
  func strictStableIDValidation() {
    #expect(MLSConversationIdentityBoundary.isCanonicalStableID(canonicalID))
    #expect(MLSConversationIdentityBoundary.stableID(canonicalID)?.rawValue == canonicalID)
    #expect(MLSConversationIdentityBoundary.stableID(canonicalID.uppercased()) == nil)
    #expect(!MLSConversationIdentityBoundary.isCanonicalStableID(canonicalID.uppercased()))
    #expect(!MLSConversationIdentityBoundary.isCanonicalStableID("550e8400-e29b-11d4-a716-446655440000"))
    #expect(!MLSConversationIdentityBoundary.isCanonicalStableID("550e8400e29b41d4a716446655440000"))
    #expect(!MLSConversationIdentityBoundary.isCanonicalStableID("550e8400-e29b-41d4-c716-446655440000"))
  }

  @Test("an exact raw alias resolves only to its canonical row")
  func exactAliasResolvesCanonical() throws {
    let records = [
      MLSConversationIdentityBoundary.Record(conversationID: groupID, groupID: groupID),
      MLSConversationIdentityBoundary.Record(conversationID: canonicalID, groupID: groupID)
    ]

    #expect(try MLSConversationIdentityBoundary.resolve(groupID, in: records) == canonicalID)
    #expect(try MLSConversationIdentityBoundary.canonicalize(records).map(\.conversationID) == [canonicalID])
  }

  @Test("a list with healthy canonical rows and a raw-only alias returns the healthy rows and excludes the alias")
  func rawOnlyAliasExcludedWhileHealthyRowsSurvive() throws {
    let healthyID1 = "550e8400-e29b-41d4-a716-446655440000"
    let healthyGroup1 = "00112233445566778899aabbccddeeff"
    let healthyID2 = "6ba7b810-9dad-41d1-80b4-00c04fd430c8"
    let healthyGroup2 = "112233445566778899aabbccddeeff00"
    let rawOnlyGroup = "2233445566778899aabbccddeeff0011"

    let records = [
      MLSConversationIdentityBoundary.Record(conversationID: healthyID1, groupID: healthyGroup1),
      MLSConversationIdentityBoundary.Record(conversationID: rawOnlyGroup, groupID: rawOnlyGroup),
      MLSConversationIdentityBoundary.Record(conversationID: healthyID2, groupID: healthyGroup2),
    ]

    let canonical = try MLSConversationIdentityBoundary.canonicalize(records)
    #expect(canonical.map(\.conversationID) == [healthyID1, healthyID2])
    #expect(!canonical.contains { $0.conversationID == rawOnlyGroup })
    #expect(!canonical.contains { $0.groupID == rawOnlyGroup })
  }

  @Test("raw group id never appears in any canonicalized output")
  func rawGroupIDNeverEscapes() throws {
    let rawOnlyGroup = "2233445566778899aabbccddeeff0011"
    let records = [
      MLSConversationIdentityBoundary.Record(conversationID: rawOnlyGroup, groupID: rawOnlyGroup),
    ]

    let canonical = try MLSConversationIdentityBoundary.canonicalize(records)
    #expect(canonical.isEmpty)
  }

  @Test("a malformed non-canonical row is excluded while healthy rows survive")
  func noncanonicalRowExcludedWhileHealthyRowsSurvive() throws {
    let healthyID = "550e8400-e29b-41d4-a716-446655440000"
    let healthyGroup = "00112233445566778899aabbccddeeff"
    let malformedID = "550E8400-E29B-41D4-A716-446655440000" // uppercase UUID
    let malformedGroup = "112233445566778899aabbccddeeff00"

    let records = [
      MLSConversationIdentityBoundary.Record(conversationID: healthyID, groupID: healthyGroup),
      MLSConversationIdentityBoundary.Record(conversationID: malformedID, groupID: malformedGroup),
    ]

    let canonical = try MLSConversationIdentityBoundary.canonicalize(records)
    #expect(canonical.map(\.conversationID) == [healthyID])
  }

  @Test("resolveID throws for unresolvable, raw-only, noncanonical, or unknown requests")
  func resolveIDRejectionCases() {
    let rawOnlyGroup = "2233445566778899aabbccddeeff0011"
    let rawOnlyRecords = [
      MLSConversationIdentityBoundary.Record(conversationID: rawOnlyGroup, groupID: rawOnlyGroup)
    ]

    // Route lookup for a raw-only group throws unresolved
    #expect(throws: MLSConversationIdentityError.self) {
      try MLSConversationIdentityBoundary.resolve(rawOnlyGroup, in: rawOnlyRecords)
    }

    let healthyID = "550e8400-e29b-41d4-a716-446655440000"
    let healthyGroup = "00112233445566778899aabbccddeeff"
    let records = [
      MLSConversationIdentityBoundary.Record(conversationID: healthyID, groupID: healthyGroup)
    ]

    // Non-canonical request format throws invalidStableID
    #expect(throws: MLSConversationIdentityError.self) {
      try MLSConversationIdentityBoundary.resolve("NOT-A-VALID-ID", in: records)
    }

    // Uppercase UUID request throws invalidStableID
    #expect(throws: MLSConversationIdentityError.self) {
      try MLSConversationIdentityBoundary.resolve(healthyID.uppercased(), in: records)
    }

    // Unknown canonical UUID throws unresolved
    #expect(throws: MLSConversationIdentityError.self) {
      try MLSConversationIdentityBoundary.resolve("6ba7b810-9dad-41d1-80b4-00c04fd430c8", in: records)
    }

    // Unrelated group ID throws unresolved
    #expect(throws: MLSConversationIdentityError.self) {
      try MLSConversationIdentityBoundary.resolve("ffeeddccbbaa99887766554433221100", in: records)
    }
  }

  @Test("ambiguous identities fail closed globally")
  func ambiguousIdentitiesFailGlobally() {
    let canonicalID1 = "550e8400-e29b-41d4-a716-446655440000"
    let canonicalID2 = "6ba7b810-9dad-41d1-80b4-00c04fd430c8"
    let groupID1 = "00112233445566778899aabbccddeeff"
    let groupID2 = "112233445566778899aabbccddeeff00"

    // One group with two canonical rows
    let ambiguousGroup = [
      MLSConversationIdentityBoundary.Record(conversationID: canonicalID1, groupID: groupID1),
      MLSConversationIdentityBoundary.Record(conversationID: canonicalID2, groupID: groupID1)
    ]
    #expect(throws: MLSConversationIdentityError.self) {
      try MLSConversationIdentityBoundary.canonicalize(ambiguousGroup)
    }

    // One stable ID mapping two different groups
    let ambiguousStableID = [
      MLSConversationIdentityBoundary.Record(conversationID: canonicalID1, groupID: groupID1),
      MLSConversationIdentityBoundary.Record(conversationID: canonicalID1, groupID: groupID2)
    ]
    #expect(throws: MLSConversationIdentityError.self) {
      try MLSConversationIdentityBoundary.canonicalize(ambiguousStableID)
    }
  }

  @Test("live load transformation excludes non-canonical rows and cleans side maps")
  func liveLoadTransformationExcludesNoncanonicalRowsAndSideMaps() throws {
    let healthyID1 = "550e8400-e29b-41d4-a716-446655440000"
    let healthyGroup1Data = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
    let healthyGroup1 = healthyGroup1Data.hexEncodedString()

    let healthyID2 = "6ba7b810-9dad-41d1-80b4-00c04fd430c8"
    let healthyGroup2Data = Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00])
    let healthyGroup2 = healthyGroup2Data.hexEncodedString()

    let rawOnlyGroupData = Data([0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11])
    let rawOnlyGroupID = rawOnlyGroupData.hexEncodedString()

    let date1 = Date(timeIntervalSince1970: 1000)
    let date2 = Date(timeIntervalSince1970: 2000)
    let datePhantom = Date(timeIntervalSince1970: 3000)

    let convo1 = MLSConversationModel(
      conversationID: healthyID1,
      currentUserDID: "did:plc:alice",
      groupID: healthyGroup1Data,
      createdAt: date1
    )
    let phantomConvo = MLSConversationModel(
      conversationID: rawOnlyGroupID,
      currentUserDID: "did:plc:alice",
      groupID: rawOnlyGroupData,
      createdAt: datePhantom
    )
    let convo2 = MLSConversationModel(
      conversationID: healthyID2,
      currentUserDID: "did:plc:alice",
      groupID: healthyGroup2Data,
      createdAt: date2
    )

    let loadedConversations = [convo1, phantomConvo, convo2]

    let rawUnreadCounts = [
      healthyID1: 2,
      rawOnlyGroupID: 5,
      healthyID2: 1
    ]

    let rawLastMessages = [
      healthyID1: MLSLastMessagePreview(senderDID: "did:plc:bob", text: "Hello Alice"),
      rawOnlyGroupID: MLSLastMessagePreview(senderDID: "did:plc:phantom", text: "Ghost message"),
      healthyID2: MLSLastMessagePreview(senderDID: "did:plc:charlie", text: "You joined this conversation", isSystemMessage: true)
    ]

    let rawLatestActivity = [
      healthyID1: date1,
      rawOnlyGroupID: datePhantom,
      healthyID2: date2
    ]

    let member1 = MLSMemberModel(
      memberID: "m1",
      conversationID: healthyID1,
      currentUserDID: "did:plc:alice",
      did: "did:plc:bob",
      leafIndex: 0
    )
    let memberPhantom = MLSMemberModel(
      memberID: "m2",
      conversationID: rawOnlyGroupID,
      currentUserDID: "did:plc:alice",
      did: "did:plc:phantom",
      leafIndex: 0
    )
    let member2 = MLSMemberModel(
      memberID: "m3",
      conversationID: healthyID2,
      currentUserDID: "did:plc:alice",
      did: "did:plc:charlie",
      leafIndex: 0
    )

    let loadedMembers = [
      healthyID1: [member1],
      rawOnlyGroupID: [memberPhantom],
      healthyID2: [member2]
    ]

    guard let result = MLSConversationIdentityBoundary.canonicalizeLiveList(
      conversations: loadedConversations,
      membersByConvoID: loadedMembers,
      rawUnreadCounts: rawUnreadCounts,
      lastMessages: rawLastMessages,
      latestActivityByConvo: rawLatestActivity
    ) else {
      Issue.record("Expected canonicalizeLiveList to succeed")
      return
    }

    // 1. Excluded non-canonical phantom row from conversations list
    #expect(result.conversations.count == 2)
    #expect(result.conversations.map(\.conversationID) == [healthyID2, healthyID1]) // sorted by activity (date2 > date1)
    #expect(!result.conversations.contains { $0.conversationID == rawOnlyGroupID })

    // 2. Side maps have stripped the phantom row
    #expect(result.unreadCounts[rawOnlyGroupID] == nil)
    #expect(result.unreadCounts[healthyID1] == 2)
    #expect(result.unreadCounts[healthyID2] == 1)

    #expect(result.lastMessages[rawOnlyGroupID] == nil)
    #expect(result.lastMessages[healthyID1]?.text == "Hello Alice")
    #expect(result.lastMessages[healthyID2]?.text == "You joined this conversation")
    #expect(result.lastMessages[healthyID2]?.isSystemMessage == true)
    #expect(result.lastMessages[healthyID1]?.isSystemMessage == false)

    #expect(result.latestActivityByConvo[rawOnlyGroupID] == nil)
    #expect(result.latestActivityByConvo[healthyID1] == date1)
    #expect(result.latestActivityByConvo[healthyID2] == date2)

    #expect(result.membersByConvoID[rawOnlyGroupID] == nil)
    #expect(result.membersByConvoID[healthyID1]?.count == 1)
    #expect(result.membersByConvoID[healthyID2]?.count == 1)
  }
}

#if os(iOS)
import SwiftUI
import UIKit

extension MLSConversationIdentityBoundaryTests {
  @MainActor
  @Test("main Inbox exposes both providers without stealing an explicit selection")
  func requestProviderPickerRoutesActualHostedContent() async throws {
    var visible: [MessageRequestProvider] = []
    let controller = UIHostingController(rootView: MessageRequestProviderContainer(
      initialProvider: .initial(pendingCatbirdCount: 1),
      bluesky: { Text("Bluesky requests").onAppear { visible.append(.bluesky) } },
      catbird: { Text("Catbird requests").onAppear { visible.append(.catbird) } }))
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    controller.view.layoutIfNeeded()
    func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    for _ in 0..<100 where visible.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    #expect(visible.last == .catbird)
    let picker = try #require(descendants(controller.view).compactMap { $0 as? UISegmentedControl }.first)
    #expect(picker.numberOfSegments == 2)
    #expect(picker.titleForSegment(at: 0) == "Bluesky")
    #expect(picker.titleForSegment(at: 1) == "Catbird")
    picker.selectedSegmentIndex = 0
    picker.sendActions(for: .valueChanged)
    for _ in 0..<100 where visible.last != .bluesky { try await Task.sleep(for: .milliseconds(20)) }
    #expect(visible.last == .bluesky)
    // Re-rendering for a changed pending count must keep the user's choice.
    controller.rootView = MessageRequestProviderContainer(initialProvider: .catbird,
      bluesky: { Text("Bluesky requests").onAppear { visible.append(.bluesky) } },
      catbird: { Text("Catbird requests").onAppear { visible.append(.catbird) } })
    try await Task.sleep(for: .milliseconds(40))
    #expect(picker.selectedSegmentIndex == 0)
    #expect(visible.last == .bluesky)
  }

  @MainActor
  @Test("the first actual Inbox sheet renders its pending Catbird presentation item")
  func requestSheetFirstPresentationUsesItem() async throws {
    let state = InboxSheetTestPresentation()
    let controller = UIHostingController(rootView: InboxSheetTestHarness(state: state))
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    defer { controller.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil }
    controller.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(80))
    state.provider = .initial(pendingCatbirdCount: 1)
    for _ in 0..<100 where state.visible == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(controller.presentedViewController != nil)
    #expect(state.visible == .catbird)
  }

  @MainActor
  @Test("accept keeps failure retryable and only routes the accepted stable conversation")
  func requestAcceptanceFailureRetryAndSessionFence() async throws {
    enum Failure: Error { case unavailable }
    let id = "29154b98-20dc-4488-b366-d2c3b69485e8"
    var routed: [String] = []
    var calls: [String] = []
    do {
      try await MLSChatRequestAcceptance.perform(conversationID: id, isCurrent: { true },
        accept: { calls.append($0); throw Failure.unavailable },
        didAccept: { routed.append($0) })
      Issue.record("Failed acceptance must not complete the Inbox route")
    } catch Failure.unavailable { }
    #expect(routed.isEmpty)
    try await MLSChatRequestAcceptance.perform(conversationID: id, isCurrent: { true },
      accept: { calls.append($0) }, didAccept: { routed.append($0) })
    #expect(calls == [id, id])
    #expect(routed == [id])
    var current = true
    do {
      try await MLSChatRequestAcceptance.perform(conversationID: id, isCurrent: { current },
        accept: { _ in current = false }, didAccept: { routed.append($0) })
      Issue.record("A retired account must not navigate or dismiss after an awaited acceptance")
    } catch is CancellationError { }
    #expect(routed == [id])
  }
}
@MainActor @Observable private final class InboxSheetTestPresentation {
      var provider: MessageRequestProvider?
      var visible: MessageRequestProvider?
    }
@MainActor private struct InboxSheetTestHarness: View {
      @Bindable var state: InboxSheetTestPresentation
      var body: some View {
        Text("Inbox").modifier(MessageRequestSheet(provider: $state.provider, onDismiss: {}, sheetContent: { provider in
          MessageRequestProviderContainer(initialProvider: provider,
            bluesky: { Text("Bluesky").onAppear { state.visible = .bluesky } },
            catbird: { Text("Catbird").onAppear { state.visible = .catbird } })
        }))
      }
    }

#endif
