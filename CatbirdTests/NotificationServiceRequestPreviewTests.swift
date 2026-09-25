import CatbirdMLSCore
import CryptoKit
import Foundation
import GRDB
import Testing
import UserNotifications
@testable import Catbird

/// Test-module alias so the extension's `NotificationService.swift` (compiled into this bundle
/// unchanged) resolves the profile cache it references. The request branch never reads it.
typealias ProfileCacheDatabase = Catbird.ProfileCacheDatabase

/// C32 clause 8, Apple: the shipped `NotificationService` class receives the exact Nest request
/// payload and decides the visible text from the App Group database that the app itself wrote
/// through `MLSGRDBManager` + `MLSRequestNotificationPreviewCache.project`. OS launch of the
/// extension via APNs is not exercised here.
@Suite("NSE encrypted request preview", .serialized)
@MainActor
struct NotificationServiceRequestPreviewTests {
  static let nestTitle = "New message request"
  static let nestBody = "Open Catbird to read your message request"
  static let genericTitle = "Message Request"
  static let genericBody = "New encrypted message request"

  struct Fixture {
    let did: String
    let conversation: String
    let message: String
    let request: String
    let introduction: String
  }

  /// Seeds through the app's real persistence path, then releases the app-side pool so the
  /// extension opens the database the way a separate process would.
  func seed(_ consents: [(RequestConsent, UInt64)], preview: Bool = true) async throws -> Fixture {
    let fixture = Fixture(
      did: "did:plc:nse-\(UUID().uuidString.lowercased())",
      conversation: UUID().uuidString.lowercased(),
      message: UUID().uuidString.lowercased(),
      request: UUID().uuidString.lowercased(),
      introduction: "Private introduction \(UUID().uuidString)")
    let pool = try await MLSGRDBManager.shared.getDatabasePool(for: fixture.did)
    for (consent, version) in consents {
      let view = DirectRequestView(
        introduction: nil, conversationId: fixture.conversation, firstMessageId: fixture.message,
        consent: consent, crypto: .ready,
        preview: .ready(text: fixture.introduction, invitation: nil),
        capabilities: RequestCapabilities(
          canPreview: preview, canAccept: consent == .incomingPending, canClose: consent != .closed,
          canSend: consent == .accepted, canEmitReceipts: false, canAdminister: false),
        stateVersion: version, generation: 1)
      try await MLSRequestNotificationPreviewCache.project(view, accountDID: fixture.did, database: pool)
    }
    _ = await MLSGRDBManager.shared.closeDatabaseAndDrain(for: fixture.did, timeout: 5)
    return fixture
  }

  func cleanup(_ fixture: Fixture) async {
    UserDefaults(suiteName: "group.blue.catbird.shared")?.removeObject(forKey: "mlsChatNotificationsEnabled_\(fixture.did)")
    try? await MLSGRDBManager.shared.deleteDatabase(for: fixture.did)
  }

  static func accountHash(_ did: String) -> String {
    SHA256.hash(data: Data(did.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// Exactly the 7 custom fields Nest emits (request_metadata.rs) plus its alert (dispatch.rs).
  func nestRequest(_ fixture: Fixture, conversation: String? = nil, message: String? = nil, account: String? = nil) -> UNNotificationRequest {
    let content = UNMutableNotificationContent()
    content.title = Self.nestTitle
    content.body = Self.nestBody
    content.userInfo = [
      "aps": ["alert": ["title": Self.nestTitle, "body": Self.nestBody], "sound": "default", "mutable-content": 1],
      "type": "mls_message_request",
      "protocol_version": "2",
      "request_id": fixture.request,
      "convo_id": conversation ?? fixture.conversation,
      "message_id": message ?? fixture.message,
      "event_id": UUID().uuidString.lowercased(),
      "recipient_account": account ?? Self.accountHash(fixture.did),
    ]
    return UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
  }

  func deliver(_ request: UNNotificationRequest) async -> UNNotificationContent {
    let extensionInstance = NotificationService()
    return await withCheckedContinuation { continuation in
      extensionInstance.didReceive(request) { continuation.resume(returning: $0) }
    }
  }

  func assertGeneric(_ content: UNNotificationContent, _ fixture: Fixture) {
    #expect(content.title == Self.genericTitle)
    #expect(content.body == Self.genericBody)
    for field in [content.title, content.subtitle, content.body] {
      #expect(!field.contains(fixture.introduction))
    }
  }

  @Test("hit: a pending request's projected preview becomes the notification body")
  func hitShowsCachedPreview() async throws {
    let fixture = try await seed([(.incomingPending, 1)])
    defer { Task { await cleanup(fixture) } }
    let content = await deliver(nestRequest(fixture))
    #expect(content.title == Self.genericTitle)
    #expect(content.body == fixture.introduction)
    // Counterfactual: identical push for an account with no preview row stays generic, so the
    // body above came from the app-written cache rather than the payload.
    let empty = try await seed([])
    defer { Task { await cleanup(empty) } }
    assertGeneric(await deliver(nestRequest(empty)), empty)
  }

  @Test("miss: unknown request IDs show generic text with zero plaintext")
  func missIsGeneric() async throws {
    let fixture = try await seed([(.incomingPending, 1)])
    defer { Task { await cleanup(fixture) } }
    assertGeneric(await deliver(nestRequest(fixture, conversation: UUID().uuidString.lowercased(),
                                            message: UUID().uuidString.lowercased())), fixture)
    // Counterfactual: the same seeded account with its real IDs does surface the plaintext,
    // so the zero-plaintext check above is sensitive.
    #expect(await deliver(nestRequest(fixture)).body == fixture.introduction)
  }

  @Test("closed: a closed request is generic, not suppressed, and never restores the older preview")
  func closedIsGeneric() async throws {
    let fixture = try await seed([(.incomingPending, 1), (.closed, 2), (.incomingPending, 1)])
    defer { Task { await cleanup(fixture) } }
    let content = await deliver(nestRequest(fixture))
    assertGeneric(content, fixture)
    #expect(content.sound != nil)
    // Counterfactual: without the closed projection the same request shows the preview.
    let pending = try await seed([(.incomingPending, 1)])
    defer { Task { await cleanup(pending) } }
    #expect(await deliver(nestRequest(pending)).body == pending.introduction)
  }

  @Test("message_id mismatch: the right conversation with another message is generic")
  func messageMismatchIsGeneric() async throws {
    let fixture = try await seed([(.incomingPending, 1)])
    defer { Task { await cleanup(fixture) } }
    assertGeneric(await deliver(nestRequest(fixture, message: UUID().uuidString.lowercased())), fixture)
    // Counterfactual: the matching message_id surfaces the preview.
    #expect(await deliver(nestRequest(fixture)).body == fixture.introduction)
  }

  @Test("unmapped recipient_account is generic even when another account holds a preview")
  func unknownAccountIsGeneric() async throws {
    let fixture = try await seed([(.incomingPending, 1)])
    defer { Task { await cleanup(fixture) } }
    assertGeneric(await deliver(nestRequest(fixture, account: Self.accountHash("did:plc:not-on-this-device"))), fixture)
    #expect(await deliver(nestRequest(fixture)).body == fixture.introduction)
  }

  @Test("account notifications disabled: the extension suppresses title, body and sound")
  func disabledAccountSuppresses() async throws {
    let fixture = try await seed([(.incomingPending, 1)])
    defer { Task { await cleanup(fixture) } }
    UserDefaults(suiteName: "group.blue.catbird.shared")?.set(false, forKey: "mlsChatNotificationsEnabled_\(fixture.did)")
    let content = await deliver(nestRequest(fixture))
    #expect(content.title.isEmpty && content.body.isEmpty && content.sound == nil)
    // Counterfactual: re-enabled, the same push shows the preview.
    UserDefaults(suiteName: "group.blue.catbird.shared")?.set(true, forKey: "mlsChatNotificationsEnabled_\(fixture.did)")
    #expect(await deliver(nestRequest(fixture)).body == fixture.introduction)
  }
}
