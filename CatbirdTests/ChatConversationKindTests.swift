import CatbirdMLSCore
import Foundation
import Testing
@testable import Catbird

/// Bluesky DMs and encrypted chats are two kinds of conversation in one inbox. The user picks
/// the kind; nothing converts a conversation or substitutes one kind for the other.
@Suite("Conversation kinds: new conversation choice")
@MainActor
struct NewConversationKindModelTests {
  static let recipient = NewConversationRecipient(
    did: "did:plc:kindpeer000000000000000", handle: "peer.test", displayName: "Peer", avatarURL: nil)

  final class Spy {
    var startedEncrypted: [String] = []
    var startedBluesky: [String] = []
    var introductions = 0
    var settingsPointers = 0
    var notEligible: [String] = []

    @MainActor
    var handlers: NewConversationKindHandlers {
      NewConversationKindHandlers(
        startEncrypted: { self.startedEncrypted.append($0.did) },
        startBluesky: { self.startedBluesky.append($0.did) },
        presentIntroduction: { self.introductions += 1 },
        presentChatSettingsPointer: { self.settingsPointers += 1 },
        presentAccountNotEligible: { self.notEligible.append($0) }
      )
    }
  }

  private func model(
    _ capability: MLSChatCapability,
    readiness: EncryptedChatSelfReadiness = .ready
  ) -> NewConversationKindModel {
    NewConversationKindModel(
      recipient: Self.recipient,
      checkCapability: { _, _ in capability },
      selfReadiness: { readiness }
    )
  }

  @Test("A capable person is offered encrypted chat first and Bluesky DM second")
  func capableOffersBothKinds() async {
    let model = model(.capable)
    await model.load()
    #expect(model.state == .capable)
    #expect(model.options == [.encrypted, .bluesky])
    #expect(model.notice == nil)
    #expect(model.canRetry == false)
  }

  @Test("A person who cannot use encrypted chat is offered only a Bluesky DM, with one line")
  func incapableOffersBlueskyOnly() async {
    let model = model(.incapable(.missingKEMKey))
    await model.load()
    #expect(model.state == .incapable)
    #expect(model.options == [.bluesky])
    #expect(model.notice == "Encrypted chat isn’t available for this person yet.")
    #expect(model.canRetry == false)
  }

  @Test("A failed lookup offers a Bluesky DM and a way to try again")
  func unknownOffersBlueskyAndRetry() async {
    let model = model(.unknown(.network))
    await model.load()
    #expect(model.state == .unknown)
    #expect(model.options == [.bluesky])
    #expect(model.notice == "Couldn’t check encrypted chat")
    #expect(model.canRetry)
  }

  @Test("Try again reads the person afresh and can then offer encrypted chat")
  func retryForcesAFreshRead() async {
    var calls: [Bool] = []
    let model = NewConversationKindModel(
      recipient: Self.recipient,
      checkCapability: { _, force in
        calls.append(force)
        return force ? .capable : .unknown(.network)
      },
      selfReadiness: { .ready }
    )
    await model.load()
    await model.retry()
    #expect(calls == [false, true])
    #expect(model.options == [.encrypted, .bluesky])
  }

  @Test("Nothing is started until the user picks a kind")
  func loadingStartsNothing() async {
    let spy = Spy()
    let model = model(.capable)
    await model.load()
    #expect(spy.startedEncrypted.isEmpty && spy.startedBluesky.isEmpty)
  }

  @Test("Choosing encrypted chat starts only an encrypted chat")
  func encryptedChoiceStartsEncrypted() async {
    let spy = Spy()
    let model = model(.capable)
    await model.load()
    await model.choose(.encrypted, handlers: spy.handlers)
    #expect(spy.startedEncrypted == [Self.recipient.did])
    #expect(spy.startedBluesky.isEmpty)
  }

  @Test("Choosing Bluesky DM starts only a Bluesky DM")
  func blueskyChoiceStartsBluesky() async {
    let spy = Spy()
    let model = model(.capable)
    await model.load()
    await model.choose(.bluesky, handlers: spy.handlers)
    #expect(spy.startedBluesky == [Self.recipient.did])
    #expect(spy.startedEncrypted.isEmpty)
  }

  @Test("Before the introduction is accepted, encrypted chat presents the introduction")
  func notReadyPresentsIntroduction() async {
    let spy = Spy()
    let model = model(.capable, readiness: .needsIntroduction)
    await model.load()
    await model.choose(.encrypted, handlers: spy.handlers)
    #expect(spy.introductions == 1)
    #expect(spy.startedEncrypted.isEmpty && spy.startedBluesky.isEmpty)
  }

  @Test("With encrypted chat turned off, encrypted chat points to Chat Settings")
  func turnedOffPointsToSettings() async {
    let spy = Spy()
    let model = model(.capable, readiness: .turnedOff)
    await model.load()
    await model.choose(.encrypted, handlers: spy.handlers)
    #expect(spy.settingsPointers == 1)
    #expect(spy.startedEncrypted.isEmpty && spy.startedBluesky.isEmpty)
  }

  @Test("An encrypted-chat choice never creates or sends into a Bluesky DM")
  func encryptedChoiceNeverReachesBluesky() async {
    let capabilities: [MLSChatCapability] = [
      .capable, .incapable(.noDevices), .incapable(.missingDeclaration), .unknown(.network)
    ]
    let readinesses: [EncryptedChatSelfReadiness] = [
      .ready, .needsIntroduction, .turnedOff, .accountNotEligible(message: "Not eligible")
    ]
    for capability in capabilities {
      for readiness in readinesses {
        let spy = Spy()
        let model = model(capability, readiness: readiness)
        await model.load()
        await model.choose(.encrypted, handlers: spy.handlers)
        #expect(spy.startedBluesky.isEmpty, "capability \(capability), readiness \(readiness)")
        if !capability.isCapable {
          #expect(spy.startedEncrypted.isEmpty, "encrypted is not offered for \(capability)")
        }
      }
    }
  }
}

@Suite("Conversation kinds: entry routing")
struct ChatEntryRouterTests {
  static let recipient = NewConversationRecipientFixture.recipient
  static let earlier = Date(timeIntervalSince1970: 1_800_000_000)
  static let later = Date(timeIntervalSince1970: 1_800_000_600)

  @Test("With no conversation, Message opens the new conversation screen with the person picked")
  func noneOpensNewConversation() {
    #expect(ChatEntryRouter.destination(for: Self.recipient, bluesky: nil, encrypted: nil)
      == .newConversation(Self.recipient))
  }

  @Test("An existing Bluesky DM is opened")
  func blueskyOnly() {
    let bsky = ExistingDirectConversation(kind: .bluesky, id: "3kbsky", lastActivity: Self.earlier)
    #expect(ChatEntryRouter.destination(for: Self.recipient, bluesky: bsky, encrypted: nil)
      == .bluesky(convoID: "3kbsky"))
  }

  @Test("An existing encrypted chat is opened")
  func encryptedOnly() {
    let mls = ExistingDirectConversation(kind: .encrypted, id: "mls-1", lastActivity: Self.earlier)
    #expect(ChatEntryRouter.destination(for: Self.recipient, bluesky: nil, encrypted: mls)
      == .encrypted(conversationID: "mls-1"))
  }

  @Test("With both kinds, the most recently active conversation is opened")
  func bothOpensMostRecent() {
    let olderBsky = ExistingDirectConversation(kind: .bluesky, id: "3kbsky", lastActivity: Self.earlier)
    let newerMLS = ExistingDirectConversation(kind: .encrypted, id: "mls-1", lastActivity: Self.later)
    #expect(ChatEntryRouter.destination(for: Self.recipient, bluesky: olderBsky, encrypted: newerMLS)
      == .encrypted(conversationID: "mls-1"))

    let newerBsky = ExistingDirectConversation(kind: .bluesky, id: "3kbsky", lastActivity: Self.later)
    let olderMLS = ExistingDirectConversation(kind: .encrypted, id: "mls-1", lastActivity: Self.earlier)
    #expect(ChatEntryRouter.destination(for: Self.recipient, bluesky: newerBsky, encrypted: olderMLS)
      == .bluesky(convoID: "3kbsky"))

    let tiedMLS = ExistingDirectConversation(kind: .encrypted, id: "mls-tie", lastActivity: Self.later)
    #expect(ChatEntryRouter.destination(for: Self.recipient, bluesky: newerBsky, encrypted: tiedMLS)
      == .encrypted(conversationID: "mls-tie"))
  }

  @Test("The existing encrypted chat is found by membership, most recent first")
  func directLookupByMembership() {
    let me = "did:plc:self"
    let peer = Self.recipient.did
    let candidates = [
      MLSDirectConversationLookup.Candidate(
        conversationID: "group", memberDIDs: [me, peer, "did:plc:third"], lastActivity: Self.later),
      MLSDirectConversationLookup.Candidate(
        conversationID: "old-direct", memberDIDs: [me, peer], lastActivity: Self.earlier),
      MLSDirectConversationLookup.Candidate(
        conversationID: "new-direct", memberDIDs: [peer.uppercased(), me], lastActivity: Self.later),
      MLSDirectConversationLookup.Candidate(
        conversationID: "someone-else", memberDIDs: [me, "did:plc:other"], lastActivity: Self.later)
    ]
    let found = MLSDirectConversationLookup.mostRecent(with: peer, selfDID: me, in: candidates)
    #expect(found == ExistingDirectConversation(kind: .encrypted, id: "new-direct", lastActivity: Self.later))
    #expect(MLSDirectConversationLookup.mostRecent(with: "did:plc:nobody", selfDID: me, in: candidates) == nil)

    let newestGroup = MLSDirectConversationLookup.Candidate(
      conversationID: "newest-group", memberDIDs: [me, peer, "did:plc:third"],
      lastActivity: Self.later.addingTimeInterval(60))
    #expect(MLSDirectConversationLookup.mostRecent(
      with: peer, selfDID: me, in: [newestGroup, candidates[1]])?.id == "old-direct")
  }
}

enum NewConversationRecipientFixture {
  static let recipient = NewConversationRecipient(
    did: "did:plc:routepeer00000000000000", handle: "route.test", displayName: nil, avatarURL: nil)
}

@Suite("Conversation kinds: encrypted groups, labels and failure text")
struct ChatConversationKindPresentationTests {
  @Test("An encrypted group with one member who cannot use encrypted chat cannot continue")
  func groupWithOneIncapableMember() {
    let evaluation = EncryptedGroupMembership.evaluate(
      selected: ["did:plc:a", "did:plc:b", "did:plc:c"],
      capabilities: ["did:plc:a": .capable, "did:plc:b": .incapable, "did:plc:c": .capable]
    )
    #expect(evaluation.notCapable == ["did:plc:b"])
    #expect(evaluation.unchecked.isEmpty)
    #expect(evaluation.canContinue == false)
  }

  @Test("An encrypted group continues only when every member is known to be capable")
  func groupNeedsEveryMemberChecked() {
    #expect(!EncryptedGroupMembership.evaluate(selected: [], capabilities: [:]).canContinue)
    let unchecked = EncryptedGroupMembership.evaluate(
      selected: ["did:plc:a", "did:plc:b"], capabilities: ["did:plc:a": .capable, "did:plc:b": .unknown])
    #expect(unchecked.unchecked == ["did:plc:b"])
    #expect(unchecked.canContinue == false)

    let ready = EncryptedGroupMembership.evaluate(
      selected: ["did:plc:a", "did:plc:b"], capabilities: ["did:plc:a": .capable, "did:plc:b": .capable])
    #expect(ready.canContinue)
  }

  @Test("A direct encrypted draft cannot send until capability is known and capable")
  func directDraftRequiresKnownCapability() {
    let text = "Hello"
    #expect(!MLSDirectComposeSendGate.canSend(text: text, capability: nil, isSubmitting: false))
    #expect(!MLSDirectComposeSendGate.canSend(
      text: text, capability: .unknown(.network), isSubmitting: false))
    #expect(!MLSDirectComposeSendGate.canSend(
      text: text, capability: .incapable(.noDevices), isSubmitting: false))
    #expect(MLSDirectComposeSendGate.canSend(text: text, capability: .capable, isSubmitting: false))
    #expect(!MLSDirectComposeSendGate.canSend(text: "  ", capability: .capable, isSubmitting: false))
    #expect(!MLSDirectComposeSendGate.canSend(text: text, capability: .capable, isSubmitting: true))
  }

  @Test("Encrypted chats show a lock; Bluesky DMs do not, and their label is not a warning")
  func kindLabels() {
    #expect(ChatConversationKind.encrypted.showsLock)
    #expect(!ChatConversationKind.bluesky.showsLock)
    let blueskyText = [
      ChatConversationKind.bluesky.optionTitle, ChatConversationKind.bluesky.optionDetail,
      ChatConversationKind.bluesky.infoTitle, ChatConversationKind.bluesky.infoDetail
    ].joined(separator: " ").lowercased()
    for warning in ["not encrypted", "unencrypted", "not end-to-end", "insecure", "not secure"] {
      #expect(!blueskyText.contains(warning), "\(warning)")
    }
  }

  @Test("Encrypted chat engine errors are shown as plain sentences, never their raw text")
  func engineErrorsArePlain() {
    let raw = "I4: zero valid blue.catbird.chat.device records for did:plc:x (live_plane.rs:2074)"
    let errors: [MlsError] = [
      .InsufficientPermissions(message: raw), .Internal(message: raw), .InvalidInput(message: raw),
      .OpenMlsError(message: raw), .GroupCreationPending(message: raw),
      .GroupCreationRejected(message: raw), .ContextNotInitialized(message: raw),
      .StorageError(message: raw), .Panic(message: raw), .SyncIncomplete(message: raw)
    ]
    let contexts: [ChatFailureContext] = [
      .startEncryptedChat, .createEncryptedGroup, .retryEncryptedGroup, .cancelEncryptedGroup
    ]
    for error in errors {
      for context in contexts {
        let text = ChatFailureMessage.text(for: error, context: context)
        #expect(!text.contains(raw))
        #expect(!text.contains("did:"))
        #expect(!text.contains(".rs"))
        #expect(!text.contains("MlsError"))
        #expect(!text.isEmpty)
      }
    }
    #expect(ChatFailureMessage.text(for: URLError(.notConnectedToInternet), context: .startEncryptedChat)
      == "Check your connection and try again.")
  }

  @Test("Capability answers map to the same lines the new conversation screen shows")
  func capabilityText() {
    #expect(ChatFailureMessage.text(for: .capable) == nil)
    #expect(ChatFailureMessage.text(for: .incapable(.noDevices))
      == "Encrypted chat isn’t available for this person yet.")
    #expect(ChatFailureMessage.text(for: .unknown(.incompleteDeviceListing))
      == "Couldn’t check encrypted chat")
  }
}

@Suite("Conversation kinds: contact encrypted chat availability coordinator")
@MainActor
struct ContactMLSAvailabilityCoordinatorTests {
  private final class Gate {
    private var continuation: CheckedContinuation<MLSChatCapability, Never>?
    private(set) var arrived = false
    var onArrive: (() -> Void)?

    func wait() async -> MLSChatCapability {
      arrived = true
      onArrive?()
      return await withCheckedContinuation { continuation in
        self.continuation = continuation
      }
    }

    func resume(with capability: MLSChatCapability) {
      continuation?.resume(returning: capability)
      continuation = nil
    }
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @MainActor () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
      if ContinuousClock.now >= deadline {
        Issue.record("Timed out waiting for condition")
        return
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  @Test("A fast contact resolves immediately without waiting for a slow contact in the same batch")
  func fastPeerResolvesWithoutWaitingForSlowPeer() async throws {
    let slowGate = Gate()
    var reported: [(String, MLSChatCapabilityStatus)] = []
    let coordinator = ContactMLSAvailabilityCoordinator(
      maxConcurrentLookups: 6,
      checkCapability: { did, _ in
        if did == "did:plc:slow" {
          return await slowGate.wait()
        }
        return .incapable(.missingDeclaration)
      },
      onStatusChange: { did, status in
        reported.append((did, status))
      }
    )

    coordinator.requestCheck(
      for: ["did:plc:slow", "did:plc:swan"],
      accountDID: "did:plc:me"
    )
    #expect(coordinator.rowState(for: "did:plc:slow") == .checking)
    #expect(coordinator.rowState(for: "did:plc:swan") == .checking)

    try await waitUntil {
      coordinator.rowState(for: "did:plc:swan") == .resolved(.incapable)
    }
    #expect(coordinator.rowState(for: "did:plc:slow") == .checking)
    #expect(reported.count == 1)
    #expect(reported.first?.0 == "did:plc:swan")
    #expect(reported.first?.1 == .incapable)

    slowGate.resume(with: .capable)
    try await waitUntil {
      coordinator.rowState(for: "did:plc:slow") == .resolved(.capable)
    }
    #expect(reported.count == 2)
  }

  @Test("Overlapping follow and search checks coalesce into one lookup without dropping the answer")
  func overlappingFollowAndSearchChecksCoalesce() async throws {
    let gate = Gate()
    var lookupCount = 0
    let coordinator = ContactMLSAvailabilityCoordinator(
      maxConcurrentLookups: 6,
      checkCapability: { _, _ in
        lookupCount += 1
        return await gate.wait()
      }
    )

    coordinator.requestCheck(for: ["did:plc:swan"], accountDID: "did:plc:me")
    try await waitUntil { gate.arrived }

    // A second check (e.g. search results arriving while follows are still checking)
    // must not overwrite or discard the in-flight lookup.
    coordinator.requestCheck(for: ["did:plc:swan"], accountDID: "did:plc:me", prioritize: true)
    #expect(lookupCount == 1)

    gate.resume(with: .incapable(.missingDeclaration))
    try await waitUntil {
      coordinator.rowState(for: "did:plc:swan") == .resolved(.incapable)
    }
    #expect(lookupCount == 1)
  }

  @Test("Cancelling a caller search task does not strand a contact in Checking, and cancelAll leaves Retry enabled")
  func cancellationNeverStrandsContactInCheckingState() async throws {
    let gate = Gate()
    var calls: [Bool] = []
    let coordinator = ContactMLSAvailabilityCoordinator(
      maxConcurrentLookups: 6,
      checkCapability: { _, force in
        calls.append(force)
        if calls.count == 1 {
          return await gate.wait()
        }
        return .incapable(.missingDeclaration)
      }
    )

    // 1. Scheduling from inside a search task that is immediately cancelled keeps the lookup alive.
    let callerTask = Task { @MainActor in
      coordinator.requestCheck(for: ["did:plc:swan"], accountDID: "did:plc:me", prioritize: true)
    }
    await callerTask.value
    callerTask.cancel()
    try await waitUntil { gate.arrived }
    #expect(coordinator.rowState(for: "did:plc:swan") == .checking)

    // 2. Even if cancelAll() tears down in-flight work (e.g. view disappear), the row is never
    //    left in an unretryable .checking spinner; it surfaces .resolved(.unknown) and can re-check.
    coordinator.cancelAll()
    #expect(coordinator.rowState(for: "did:plc:swan") == .resolved(.unknown))
    gate.resume(with: .capable)

    coordinator.requestCheck(for: ["did:plc:swan"], accountDID: "did:plc:me", prioritize: true)
    try await waitUntil {
      coordinator.rowState(for: "did:plc:swan") == .resolved(.incapable)
    }
    #expect(calls == [false, false])
  }

  @Test("Prioritized search results jump ahead of queued follow lookups")
  func prioritizedSearchJumpsAheadOfQueuedFollows() async throws {
    let f1Gate = Gate()
    let f2Gate = Gate()
    var startOrder: [String] = []
    let coordinator = ContactMLSAvailabilityCoordinator(
      maxConcurrentLookups: 2,
      checkCapability: { did, _ in
        startOrder.append(did)
        switch did {
        case "did:plc:f1": return await f1Gate.wait()
        case "did:plc:f2": return await f2Gate.wait()
        default: return .capable
        }
      }
    )

    coordinator.requestCheck(
      for: ["did:plc:f1", "did:plc:f2", "did:plc:f3", "did:plc:f4"],
      accountDID: "did:plc:me"
    )
    try await waitUntil { f1Gate.arrived && f2Gate.arrived }
    #expect(startOrder == ["did:plc:f1", "did:plc:f2"])

    coordinator.requestCheck(
      for: ["did:plc:swan"],
      accountDID: "did:plc:me",
      prioritize: true
    )

    f1Gate.resume(with: .capable)
    try await waitUntil {
      coordinator.rowState(for: "did:plc:swan") == .resolved(.capable)
    }
    #expect(startOrder.prefix(3) == ["did:plc:f1", "did:plc:f2", "did:plc:swan"])

    f2Gate.resume(with: .capable)
    try await waitUntil {
      coordinator.rowState(for: "did:plc:f4") == .resolved(.capable)
    }
  }

  @Test("Retry forces a fresh lookup and Account reset ignores late completions from the old account")
  func retryAndAccountReset() async throws {
    let oldAccountGate = Gate()
    var forceFlags: [Bool] = []
    var reported: [(String, MLSChatCapabilityStatus)] = []
    let coordinator = ContactMLSAvailabilityCoordinator(
      maxConcurrentLookups: 6,
      checkCapability: { did, force in
        if did == "did:plc:stale" {
          return await oldAccountGate.wait()
        }
        forceFlags.append(force)
        return force ? .capable : .unknown(.network)
      },
      onStatusChange: { did, status in
        reported.append((did, status))
      }
    )

    coordinator.requestCheck(for: ["did:plc:peer"], accountDID: "did:plc:accountA")
    try await waitUntil {
      coordinator.rowState(for: "did:plc:peer") == .resolved(.unknown)
    }
    coordinator.retry(did: "did:plc:peer", accountDID: "did:plc:accountA")
    try await waitUntil {
      coordinator.rowState(for: "did:plc:peer") == .resolved(.capable)
    }
    #expect(forceFlags == [false, true])

    reported.removeAll()
    coordinator.requestCheck(for: ["did:plc:stale"], accountDID: "did:plc:accountA")
    try await waitUntil { oldAccountGate.arrived }
    coordinator.reset(accountDID: "did:plc:accountB")
    oldAccountGate.resume(with: .capable)
    try await Task.sleep(for: .milliseconds(30))
    #expect(reported.isEmpty)
    #expect(coordinator.availability["did:plc:stale"] == nil)
  }
}
