import AppIntents
@testable import CatbirdMLSCore
import Foundation
import GRDB
@testable import Petrel
import Testing
@testable import Catbird
#if os(iOS) && canImport(GeoToolbox) && compiler(>=7.0)
import GeoToolbox
#endif

/// C29 Apple validation: draft-only entrypoints produce zero remote calls.
///
/// Installs a counting URLProtocol on the real transport boundaries
/// (URLSession.shared AND Petrel NetworkService) and exercises every draft
/// path through the production entry points:
///   1. Positive control: proves the CountingURLProtocol actively intercepts real traffic.
///   2. Contact select via MLSNewConversationViewModel.createRecipientDraft.
///   3. Direct message request guard via MLSNewConversationViewModel.createConversation.
///   4. App Intent draft handoff & presentation staging (ChatDraftHandoff + MLSDirectComposeDraftStore).
///   5. Attachment-first rejection via CatbirdSendMessageSchemaIntent (when GeoToolbox available)
///      and MLSDirectComposeView text-only composer bounds.
///   6. Submitted draft immutability: rejects rewrites without remote network effects.
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

  private static func withEncryptedDatabase<T>(
    _ block: (MLSGRDBManager, DatabasePool, String) async throws -> T
  ) async throws -> T {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("C29-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    MLSStoragePaths.setBaseDirectoryOverride(dir)
    let fakeStorage = MLSKeychainFakeStorage()
    MLSKeychainManager.setFakeStorageOverrideForTesting(fakeStorage)
    let manager = MLSGRDBManager()
    let did = "did:plc:c29-\(UUID().uuidString.lowercased())"
    let pool = try await manager.getDatabasePool(for: did)
    defer {
      MLSStoragePaths.setBaseDirectoryOverride(nil)
      MLSKeychainManager.setFakeStorageOverrideForTesting(nil)
    }
    let result = try await block(manager, pool, did)
    await manager.shutdownAllDatabases()
    return result
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
      // The durable handoff only delivers to the account the app is currently signed in as.
      let appState = AppState(userDID: did, client: atProtoClient)
      AppStateManager.shared.setLifecycleForTesting(.authenticated(appState))
      defer { AppStateManager.shared.setLifecycleForTesting(.unauthenticated) }
      let apiClient = await MLSAPIClient(client: atProtoClient)
      let convManager = MLSConversationManager(
        apiClient: apiClient,
        database: pool,
        userDid: did,
        atProtoClient: atProtoClient
      )

      #if os(iOS) && canImport(GeoToolbox) && compiler(>=7.0)
      // Test MessagesSchemaRuntime.resolveDestination entrypoint
      let directory = MessagesSchemaRuntime.ChatDirectory(
        conversations: [],
        membersByConvoID: [:],
        currentUserDID: did
      )
      let destination = try await MessagesSchemaRuntime.resolveDestination(
        recipients: [(did: "did:plc:carol", displayName: "Carol")],
        manager: convManager,
        directory: directory
      )
      guard case .recipientDraft(var draft) = destination else {
        Issue.record("Expected .recipientDraft from resolveDestination")
        return
      }
      #else
      var draft = try await MLSDirectComposeDraftStore.open(
        accountDID: did, recipientDID: "did:plc:carol", database: pool)
      #endif

      #expect(draft.recipientDID == "did:plc:carol")
      #expect(draft.conversationID == nil, "Resolved recipient draft must have no remote convo ID")

      // Exercise: requestPresentation (presentation handoff in store, MessagesSchemaIntents.swift:91)
      draft.text = "Drafted via App Intent runtime"
      try await MLSDirectComposeDraftStore.requestPresentation(draft, database: pool)

      // Exercise: durable handoff storage (ChatDraftHandoff.shared.storeDurably)
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
      #expect(consumed == "Drafted via App Intent runtime")

      // Exercise: cancel / archive
      try await MLSDirectComposeDraftStore.archive(draft, database: pool)
      let fresh = try await MLSDirectComposeDraftStore.open(
        accountDID: did, recipientDID: "did:plc:carol", database: pool)
      #expect(fresh.id != draft.id, "Archived draft must yield fresh identity on reopen")

      try await MLSDirectComposeDraftStore.clearPresentation(accountDID: did, database: pool)

      #expect(CountingURLProtocol.remoteEffectURLs.isEmpty,
        "App Intent draft resolution and cancellation must produce zero network calls; all traffic: \(CountingURLProtocol.urls)")
    }
  }

  // MARK: - C29-4: Attachment-first rejection

  @Test("Attachment rejection produces zero remote network calls")
  func attachmentRejectionProducesZeroRemoteCalls() async throws {
    CountingURLProtocol.reset()
    URLProtocol.registerClass(CountingURLProtocol.self)
    NetworkService.setNetworkTestProtocolClasses([CountingURLProtocol.self])
    defer {
      URLProtocol.unregisterClass(CountingURLProtocol.self)
      NetworkService.setNetworkTestProtocolClasses(nil)
    }

    #if os(iOS) && canImport(GeoToolbox) && compiler(>=7.0)
    if #available(iOS 27.0, *) {
      var intent = CatbirdSendMessageSchemaIntent()
      intent.destination = .persons([])
      intent.attachments = [IntentFile(data: Data([0xDE, 0xAD, 0xBE, 0xEF]), filename: "photo.jpg")]

      // Actually execute perform() and assert it throws IntentError.invalidParameter
      await #expect(throws: IntentError.self) {
        _ = try await intent.perform()
      }
    }
    #endif

    // Verify MLSDirectComposeDraftStore validates text bounds and rejects non-text payloads
    await #expect(throws: Error.self) {
      try MLSDirectComposeDraftStore.validateText("")
    }
    await #expect(throws: Error.self) {
      // Over limit (16KB max text bound)
      let oversized = String(repeating: "A", count: 16_385)
      try MLSDirectComposeDraftStore.validateText(oversized)
    }

    #expect(CountingURLProtocol.remoteEffectURLs.isEmpty,
      "Attachment rejection must execute before any network upload; all traffic: \(CountingURLProtocol.urls)")
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
