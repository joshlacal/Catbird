import AppIntents
@testable import CatbirdMLSCore
import Foundation
import GRDB
@testable import Petrel
import Testing
@testable import Catbird
#if os(iOS) && canImport(GeoToolbox) && compiler(>=6.4)
import GeoToolbox
#endif

/// C29 Apple validation: draft-only entrypoints produce zero remote calls.
///
/// Installs a counting URLProtocol on URLSession.shared and Petrel NetworkService.
/// Swift 6.4 with GeoToolbox exercises the MLS App Intent perform() paths,
/// contact-selection and direct-message view-model guards, local handoff/cancellation,
/// text-only bounds, and submitted draft immutability.
@Suite("C29: Draft-only entrypoints produce zero remote calls", .serialized)
@MainActor
struct EncryptedRequestDraftEntrypointTests {

  // MARK: - Counting URLProtocol Spy

  /// URLProtocol spy that counts every intercepted request without remote dispatch.
  /// Installed on URLSession.shared via `URLProtocol.registerClass` and on
  /// Petrel sessions via `NetworkService.setNetworkTestProtocolClasses`.
  private final class CountingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestURLs: [URL] = []
    private static let lock = NSLock()

    static func reset() {
      lock.lock()
      requestURLs = []
      lock.unlock()
    }
    static var urls: [URL] {
      lock.lock()
      defer { lock.unlock() }
      return requestURLs
    }
    /// Requests that would be a C29 remote effect: any chat/MLS service call (conversation,
    /// request, message, blob preparation) or a blob upload. Unrelated app startup reads
    /// (e.g. preferences, live-event config) are recorded in `urls` but are not draft effects.
    static var remoteEffectURLs: [URL] {
      urls.filter { url in
        let path = url.path
        return path.contains("/xrpc/blue.catbird.") || path.contains("uploadBlob") || path.contains("prepareBlobUpload")
      }
    }

    override class func canInit(with request: URLRequest) -> Bool {
      lock.lock()
      if let url = request.url { requestURLs.append(url) }
      lock.unlock()
      return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    override func stopLoading() {}
  }

  // MARK: - Test infrastructure

  private static var encryptedDatabaseDirectory: URL?

  private static func withEncryptedDatabase<T>(
    _ block: (MLSGRDBManager, DatabasePool, String) async throws -> T
  ) async throws -> T {
    let dir: URL
    if let encryptedDatabaseDirectory {
      dir = encryptedDatabaseDirectory
    } else {
      dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("C29-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      encryptedDatabaseDirectory = dir
    }
    MLSStoragePaths.setBaseDirectoryOverride(dir)
    MLSKeychainManager.setFakeStorageOverrideForTesting(MLSKeychainFakeStorage())
    let manager = MLSGRDBManager.shared
    guard await manager.currentActiveDID == nil else {
      MLSStoragePaths.setBaseDirectoryOverride(nil)
      MLSKeychainManager.setFakeStorageOverrideForTesting(nil)
      throw MLSStorageInitializationError.admissionDenied(
        details: "C29 fixture requires an inactive shared database manager")
    }
    let did = "did:plc:c29-\(UUID().uuidString.lowercased())"
    let outcome: Result<T, Error>
    do {
      // The singleton may have been initialized before this suite selected its test root.
      try FileManager.default.createDirectory(
        at: MLSStoragePaths.grdbDatabaseDirectory(), withIntermediateDirectories: true)
      await manager.setActiveUser(did)
      let pool = try await manager.getDatabasePool(for: did)
      outcome = .success(try await block(manager, pool, did))
    } catch {
      outcome = .failure(error)
    }
    await manager.closeDatabase(for: did)
    await manager.setActiveUser(nil)
    MLSStoragePaths.setBaseDirectoryOverride(nil)
    MLSKeychainManager.setFakeStorageOverrideForTesting(nil)
    return try outcome.get()
  }

  // MARK: - C29-0: Positive Control (proves counter sees real traffic)

  @Test("Positive control: the counter captures real requests on URLSession.shared and Petrel NetworkService")
  func positiveControlObservesTraffic() async throws {
    CountingURLProtocol.reset()
    URLProtocol.registerClass(CountingURLProtocol.self)
    NetworkService.setNetworkTestProtocolClasses([CountingURLProtocol.self])
    NetworkService.dnsResolverOverride = { _ in ["93.184.216.34"] }
    defer {
      URLProtocol.unregisterClass(CountingURLProtocol.self)
      NetworkService.setNetworkTestProtocolClasses(nil)
      NetworkService.dnsResolverOverride = nil
      CountingURLProtocol.reset()
    }

    // A chat-service request on URLSession.shared (the canonical signed-request transport).
    let chatProbe = URL(string: "https://example.com/xrpc/blue.catbird.chat.getConversations")!
    _ = try? await URLSession.shared.data(from: chatProbe)
    #expect(CountingURLProtocol.remoteEffectURLs == [chatProbe],
      "The remote-effect classifier must flag a chat-service request")

    // A request through Petrel's own NetworkService session (ATProtoClient XRPC path).
    let client = await ATProtoClient(baseURL: URL(string: "https://example.com")!)
    _ = try? await client.app.bsky.actor.getProfile(input: .init(actor: try ATIdentifier(string: "alice.test")))
    #expect(CountingURLProtocol.urls.contains { $0.path.contains("app.bsky.actor.getProfile") },
      "The counter must see requests sent through Petrel NetworkService; saw \(CountingURLProtocol.urls)")
  }

  // MARK: - C29-1: Contact select via MLSNewConversationViewModel

  @Test("Contact selection via MLSNewConversationViewModel creates local draft with zero remote calls")
  func contactSelectViaViewModelZeroRemoteCalls() async throws {
    try await Self.withEncryptedDatabase { manager, pool, did in
      CountingURLProtocol.reset()
      URLProtocol.registerClass(CountingURLProtocol.self)
      NetworkService.setNetworkTestProtocolClasses([CountingURLProtocol.self])
      defer {
        URLProtocol.unregisterClass(CountingURLProtocol.self)
        NetworkService.setNetworkTestProtocolClasses(nil)
      }

      // Configure AppStateManager with authenticated state for `did`
      let atProtoClient = await ATProtoClient(baseURL: URL(string: "https://example.com")!)
      let appState = AppState(userDID: did, client: atProtoClient)
      await appState.updateMLSDatabase(pool)
      AppStateManager.shared.setLifecycleForTesting(.authenticated(appState))
      defer { AppStateManager.shared.setLifecycleForTesting(.unauthenticated) }

      // Construct real MLSConversationManager and MLSNewConversationViewModel
      let apiClient = await MLSAPIClient(client: atProtoClient)
      let convManager = MLSConversationManager(
        apiClient: apiClient,
        database: pool,
        userDid: did,
        atProtoClient: atProtoClient
      )
      let viewModel = MLSNewConversationViewModel(database: pool, conversationManager: convManager)
      viewModel.selectedMembers = ["did:plc:bob"]

      // Exercise: createRecipientDraft() executes the real view model entrypoint (MLSNewConversationViewModel.swift:125-132)
      let draft = try await viewModel.createRecipientDraft()
      #expect(draft.accountDID == did)
      #expect(draft.recipientDID == "did:plc:bob")
      #expect(draft.conversationID == nil, "Draft must have no remote conversation ID")
      #expect(!draft.submitted, "Draft must not be submitted")

      // Exercise: typing in composer and saving locally (MLSDirectComposeView.swift:63-64)
      var mutable = draft
      mutable.text = "Hello from real entry point"
      try await MLSDirectComposeDraftStore.save(mutable, database: pool)

      #expect(CountingURLProtocol.remoteEffectURLs.isEmpty,
        "Contact select and composer draft save must produce zero remote network calls; all traffic: \(CountingURLProtocol.urls)")
    }
  }

  // MARK: - C29-2: Direct message creation requires local draft first (guard check)

  @Test("Direct message creation without draft is blocked with zero remote calls")
  func directMessageCreationBlockedWithoutDraft() async throws {
    try await Self.withEncryptedDatabase { manager, pool, did in
      CountingURLProtocol.reset()
      URLProtocol.registerClass(CountingURLProtocol.self)
      NetworkService.setNetworkTestProtocolClasses([CountingURLProtocol.self])
      defer {
        URLProtocol.unregisterClass(CountingURLProtocol.self)
        NetworkService.setNetworkTestProtocolClasses(nil)
      }

      let atProtoClient = await ATProtoClient(baseURL: URL(string: "https://example.com")!)
      let appState = AppState(userDID: did, client: atProtoClient)
      await appState.updateMLSDatabase(pool)
      AppStateManager.shared.setLifecycleForTesting(.authenticated(appState))
      defer { AppStateManager.shared.setLifecycleForTesting(.unauthenticated) }

      let apiClient = await MLSAPIClient(client: atProtoClient)
      let convManager = MLSConversationManager(
        apiClient: apiClient,
        database: pool,
        userDid: did,
        atProtoClient: atProtoClient
      )
      let viewModel = MLSNewConversationViewModel(database: pool, conversationManager: convManager)
      viewModel.selectedMembers = ["did:plc:bob"]

      // Attempting createConversation on a 1:1 direct message is blocked locally
      // with error "Write an introduction before sending a direct message request."
      let result = await viewModel.createConversation()
      #expect(result == nil, "Direct message creation must return nil without intro draft")
      #expect(viewModel.error != nil, "Validation error must be recorded")

      #expect(CountingURLProtocol.remoteEffectURLs.isEmpty,
        "Direct message guard check must produce zero remote network calls; all traffic: \(CountingURLProtocol.urls)")
    }
  }

  // MARK: - C29-3: App Intent draft handoff & presentation staging

  @Test("App Intent draft handoff and cancellation produce zero remote calls")
  func appIntentDraftHandoffAndCancelZeroRemoteCalls() async throws {
    try await Self.withEncryptedDatabase { manager, pool, did in
      CountingURLProtocol.reset()
      URLProtocol.registerClass(CountingURLProtocol.self)
      NetworkService.setNetworkTestProtocolClasses([CountingURLProtocol.self])
      defer {
        URLProtocol.unregisterClass(CountingURLProtocol.self)
        NetworkService.setNetworkTestProtocolClasses(nil)
      }

      let atProtoClient = await ATProtoClient(baseURL: URL(string: "https://example.com")!)
      let appState = AppState(userDID: did, client: atProtoClient)
      await appState.updateMLSDatabase(pool)
      AppStateManager.shared.setLifecycleForTesting(.authenticated(appState))
      defer { AppStateManager.shared.setLifecycleForTesting(.unauthenticated) }

      let convManager = await appState.getMLSConversationManager()
      #expect(convManager != nil, "Conversation manager must be ready for App Intent execution")

      #if os(iOS) && canImport(GeoToolbox) && compiler(>=6.4)
      if #available(iOS 27.0, *) {
        // Exercise actual CatbirdDraftMessageSchemaIntent.perform() entrypoint with valid destination and content
        var intent = CatbirdDraftMessageSchemaIntent()
        intent.destination = .recipient(
          CatbirdMessagesPersonEntity(id: "did:plc:carol", displayName: "Carol")
        )
        intent.content = AttributedString("Drafted via App Intent runtime")

        // Execute actual entrypoint
        _ = try await intent.perform()

        // Verify the draft was created locally in the unsubmitted state with no remote convo ID
        let draft = try await MLSDirectComposeDraftStore.open(
          accountDID: did, recipientDID: "did:plc:carol", database: pool)
        #expect(draft.recipientDID == "did:plc:carol")
        #expect(draft.conversationID == nil, "Resolved recipient draft must have no remote convo ID")
        #expect(!draft.submitted, "Draft must remain in unsubmitted draft state")
        #expect(draft.text == "Drafted via App Intent runtime")

        // Verify presentation handoff staged by perform() (MessagesSchemaIntents.swift:91)
        let presentation = try await MLSDirectComposeDraftStore.pendingPresentation(
          accountDID: did, database: pool)
        #expect(presentation?.recipientDID == "did:plc:carol")
        #expect(presentation?.text == "Drafted via App Intent runtime")

        // Discriminating counterfactual: a submitted (already published / resolving) draft
        // must be rejected by perform() rather than overwriting or re-publishing.
        var submittedDraft = draft
        submittedDraft.submitted = true
        try await MLSDirectComposeDraftStore.save(submittedDraft, database: pool)

        var conflictingIntent = CatbirdDraftMessageSchemaIntent()
        conflictingIntent.destination = .recipient(
          CatbirdMessagesPersonEntity(id: "did:plc:carol", displayName: "Carol")
        )
        conflictingIntent.content = AttributedString("Conflicting edit")
        do {
          _ = try await conflictingIntent.perform()
          Issue.record("Expected submitted draft to be rejected by CatbirdDraftMessageSchemaIntent.perform()")
        } catch let error as IntentError {
          guard case .invalidParameter(let message) = error,
                message.contains("still resolving") else {
            Issue.record("Expected invalidParameter with 'still resolving', got: \(error)")
            return
          }
        }

        // Submitted drafts are immutable; archive before reopening an editable candidate.
        try await MLSDirectComposeDraftStore.archive(submittedDraft, database: pool)
        let replacement = try await MLSDirectComposeDraftStore.open(
          accountDID: did, recipientDID: "did:plc:carol", database: pool)
        #expect(replacement.id != draft.id)

        // Exercise destination == nil path through actual entrypoint
        var nilDestIntent = CatbirdDraftMessageSchemaIntent()
        nilDestIntent.content = AttributedString("Fallback draft text")
        _ = try await nilDestIntent.perform()

        let consumedFallback = try await ChatDraftHandoff.shared.consumeDurably(
          for: "550e8400-e29b-41d4-a716-446655440000",
          accountDID: did,
          database: pool
        )
        #expect(consumedFallback == "Fallback draft text")

        // Exercise: cancel / archive
        try await MLSDirectComposeDraftStore.archive(replacement, database: pool)
        let fresh = try await MLSDirectComposeDraftStore.open(
          accountDID: did, recipientDID: "did:plc:carol", database: pool)
        #expect(fresh.id != replacement.id, "Archived draft must yield fresh identity on reopen")
        #expect(!fresh.submitted)

        try await MLSDirectComposeDraftStore.clearPresentation(accountDID: did, database: pool)
      }
      #else
      // Fallback for toolchains lacking GeoToolbox or Messages Schema support.
      // Exercise underlying view-model / draft-store handoff and cancellation mechanics.
      var draft = try await MLSDirectComposeDraftStore.open(
        accountDID: did, recipientDID: "did:plc:carol", database: pool)
      #expect(draft.recipientDID == "did:plc:carol")
      #expect(draft.conversationID == nil, "Resolved recipient draft must have no remote convo ID")

      draft.text = "Drafted via local handoff store"
      try await MLSDirectComposeDraftStore.requestPresentation(draft, database: pool)

      try await ChatDraftHandoff.shared.storeDurably(
        PendingChatDraft(conversationID: nil, text: draft.text),
        accountDID: did,
        database: pool
      )
      let consumed = try await ChatDraftHandoff.shared.consumeDurably(
        for: "550e8400-e29b-41d4-a716-446655440000",
        accountDID: did,
        database: pool
      )
      #expect(consumed == "Drafted via local handoff store")

      try await MLSDirectComposeDraftStore.archive(draft, database: pool)
      let fresh = try await MLSDirectComposeDraftStore.open(
        accountDID: did, recipientDID: "did:plc:carol", database: pool)
      #expect(fresh.id != draft.id, "Archived draft must yield fresh identity on reopen")
      #expect(!fresh.submitted)

      try await MLSDirectComposeDraftStore.clearPresentation(accountDID: did, database: pool)
      #endif

      #expect(CountingURLProtocol.remoteEffectURLs.isEmpty,
        "App Intent draft resolution and cancellation must produce zero network calls; all traffic: \(CountingURLProtocol.urls)")
    }
  }

  @Test("A terminally unpublished request keeps its text in a fresh editable draft")
  func terminalNotPublishedReopensEditableDraft() async throws {
    try await Self.withEncryptedDatabase { _, pool, did in
      var submitted = try await MLSDirectComposeDraftStore.open(
        accountDID: did, recipientDID: "did:plc:dave", database: pool)
      submitted.text = "Hello before Dave enabled requests"
      submitted.submitted = true
      try await MLSDirectComposeDraftStore.save(submitted, database: pool)

      // The dead draft id stays immutable, as before.
      var rewrite = submitted
      rewrite.text = "Edited"
      await #expect(throws: MLSDirectComposeDraftStore.Failure.self) {
        try await MLSDirectComposeDraftStore.save(rewrite, database: pool)
      }

      _ = try await MLSDirectComposeDraftStore.reopenAfterTerminal(submitted, database: pool)
      var reopened = try await MLSDirectComposeDraftStore.open(
        accountDID: did, recipientDID: "did:plc:dave", database: pool)
      #expect(reopened.id != submitted.id, "A terminal draft id can never publish; a new one is required")
      #expect(!reopened.submitted)
      #expect(reopened.text == "Hello before Dave enabled requests")
      reopened.text = "Hello again, Dave"
      try await MLSDirectComposeDraftStore.save(reopened, database: pool)
    }
  }

  // MARK: - C29-4: Attachment-first rejection

  @Test("Attachment rejection produces zero remote network calls")
  func attachmentRejectionProducesZeroRemoteCalls() async throws {
    try await Self.withEncryptedDatabase { manager, pool, did in
      CountingURLProtocol.reset()
      URLProtocol.registerClass(CountingURLProtocol.self)
      NetworkService.setNetworkTestProtocolClasses([CountingURLProtocol.self])
      defer {
        URLProtocol.unregisterClass(CountingURLProtocol.self)
        NetworkService.setNetworkTestProtocolClasses(nil)
      }

      let atProtoClient = await ATProtoClient(baseURL: URL(string: "https://example.com")!)
      let appState = AppState(userDID: did, client: atProtoClient)
      await appState.updateMLSDatabase(pool)
      AppStateManager.shared.setLifecycleForTesting(.authenticated(appState))
      defer { AppStateManager.shared.setLifecycleForTesting(.unauthenticated) }

      let convManager = await appState.getMLSConversationManager()
      #expect(convManager != nil, "Conversation manager must be ready for App Intent execution")

      #if os(iOS) && canImport(GeoToolbox) && compiler(>=6.4)
      if #available(iOS 27.0, *) {
        // Seed an otherwise-valid pending request conversation and member in the local database
        let pendingConvoID = "550e8400-e29b-41d4-a716-446655440000"
        let bobDID = "did:plc:bob"
        let convo = MLSConversationModel(
          conversationID: pendingConvoID,
          currentUserDID: did,
          groupID: Data([0x01, 0x02, 0x03]),
          title: "Bob",
          isActive: true,
          requestState: .pendingInbound
        )
        let member = MLSMemberModel(
          memberID: "member-bob",
          conversationID: pendingConvoID,
          currentUserDID: did,
          did: bobDID,
          displayName: "Bob",
          leafIndex: 1,
          isActive: true
        )
        try await pool.write { db in
          try convo.insert(db)
          try member.insert(db)
        }

        // Configure otherwise-valid intent: non-empty content and valid recipient
        var intent = CatbirdSendMessageSchemaIntent()
        intent.destination = .recipient(
          CatbirdMessagesPersonEntity(id: bobDID, displayName: "Bob")
        )
        intent.content = AttributedString("Otherwise-valid message content for pending request")
        intent.attachments = [IntentFile(data: Data([0xDE, 0xAD, 0xBE, 0xEF]), filename: "photo.jpg")]

        // Assert specific pending attachment refusal rather than any generic IntentError
        do {
          _ = try await intent.perform()
          Issue.record("Expected CatbirdSendMessageSchemaIntent.perform() to reject attachment")
        } catch let error as IntentError {
          switch error {
          case .invalidParameter(let detail):
            #expect(detail == "Catbird Messages App Schema currently supports text only.",
              "Must throw specific text-only attachment refusal, got: \(detail)")
          default:
            Issue.record("Expected IntentError.invalidParameter('Catbird Messages App Schema currently supports text only.'), got: \(error)")
          }
        }

      }
      #else
      // Older toolchains without Messages Schema still exercise the local text boundary.
      // The iOS 27 branch above exercises the actual intent.
      #endif

      // Verify MLSDirectComposeDraftStore validates text bounds and rejects non-text payloads
      #expect(throws: Error.self) {
        try MLSDirectComposeDraftStore.validateText("")
      }
      #expect(throws: Error.self) {
        // Over limit (16KB max text bound)
        let oversized = String(repeating: "A", count: 16_385)
        try MLSDirectComposeDraftStore.validateText(oversized)
      }

      #expect(CountingURLProtocol.remoteEffectURLs.isEmpty,
        "Attachment rejection must execute before any network upload; all traffic: \(CountingURLProtocol.urls)")
    }
  }

  // MARK: - C29-5: Submitted draft is immutable

  @Test("Submitted draft cannot be rewritten, preventing duplicate remote effects")
  func submittedDraftImmutable() async throws {
    try await Self.withEncryptedDatabase { manager, pool, did in
      CountingURLProtocol.reset()
      URLProtocol.registerClass(CountingURLProtocol.self)
      NetworkService.setNetworkTestProtocolClasses([CountingURLProtocol.self])
      defer {
        URLProtocol.unregisterClass(CountingURLProtocol.self)
        NetworkService.setNetworkTestProtocolClasses(nil)
      }

      var draft = try await MLSDirectComposeDraftStore.open(
        accountDID: did, recipientDID: "did:plc:dave", database: pool)
      draft.text = "Exact submitted introduction"
      draft.submitted = true
      try await MLSDirectComposeDraftStore.save(draft, database: pool)

      // Attempt to rewrite text on the submitted draft — must fail.
      draft.text = "Different introduction"
      await #expect(throws: MLSDirectComposeDraftStore.Failure.self) {
        try await MLSDirectComposeDraftStore.save(draft, database: pool)
      }

      #expect(CountingURLProtocol.remoteEffectURLs.isEmpty,
        "Immutability enforcement must not produce network calls; all traffic: \(CountingURLProtocol.urls)")
    }
  }
}
