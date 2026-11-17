import CatbirdMLSCore
import CryptoKit
import Foundation
@testable import Petrel
import Testing
import UserNotifications
@testable import Catbird

/// Encrypted chat is on for every account, waits for the one-time introduction before any
/// MLS work, and stores only the user's own opt-out.
@Suite("Encrypted chat default-on preferences", .serialized)
@MainActor
struct MLSDefaultOnConsentTests {
  private struct IsolatedDefaults {
    let appGroupName = "MLSDefaultOn-group-\(UUID().uuidString)"
    let standardName = "MLSDefaultOn-standard-\(UUID().uuidString)"
    let appGroup: UserDefaults
    let standard: UserDefaults

    init() {
      appGroup = UserDefaults(suiteName: appGroupName)!
      standard = UserDefaults(suiteName: standardName)!
    }

    func settings() -> ExperimentalSettings {
      ExperimentalSettings(appGroupDefaults: appGroup, standardDefaults: standard)
    }

    func cleanup() {
      appGroup.removePersistentDomain(forName: appGroupName)
      standard.removePersistentDomain(forName: standardName)
    }
  }

  private static func freshDID(_ label: String) -> String {
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
    return "did:plc:\(label)\(suffix)"
  }

  @Test("A fresh account has encrypted chat on but runs no MLS work until the introduction is acknowledged")
  func freshAccountWaitsForIntroduction() throws {
    let store = IsolatedDefaults()
    defer { store.cleanup() }
    let settings = store.settings()
    let did = Self.freshDID("fresh")

    #expect(settings.isMLSChatEnabled(for: did))
    #expect(!settings.isMLSUserDisabled(for: did))
    #expect(!settings.hasSeenMLSIntro(for: did))
    #expect(settings.shouldPresentMLSIntro(for: did))
    #expect(!settings.isMLSRuntimeAllowed(for: did))
  }

  @Test("Continuing past the introduction allows enrollment and does not show it again")
  func continueAllowsEnrollment() throws {
    let store = IsolatedDefaults()
    defer { store.cleanup() }
    let settings = store.settings()
    let did = Self.freshDID("continue")

    settings.enableMLSChat(for: did)

    #expect(settings.isMLSRuntimeAllowed(for: did))
    #expect(!settings.shouldPresentMLSIntro(for: did))
  }

  @Test("Not now stores the user's opt-out in the App Group and the introduction does not return")
  func notNowStoresOptOutInAppGroup() throws {
    let store = IsolatedDefaults()
    defer { store.cleanup() }
    let settings = store.settings()
    let did = Self.freshDID("notnow")
    let hash = try MLSAppGroupStorage.accountDidHash(for: did)

    settings.disableMLSChat(for: did)

    #expect(!settings.isMLSChatEnabled(for: did))
    #expect(!settings.isMLSRuntimeAllowed(for: did))
    #expect(!settings.shouldPresentMLSIntro(for: did))
    #expect(store.appGroup.bool(forKey: "mlsUserDisabled_\(hash)"))

    settings.enableMLSChat(for: did)
    #expect(settings.isMLSRuntimeAllowed(for: did))
    #expect(store.appGroup.object(forKey: "mlsUserDisabled_\(hash)") == nil)
  }

  @Test("Legacy opt-in values are migrated once: false is cleared and asks again, true keeps its acknowledgement")
  func legacyOptInMigration() throws {
    let store = IsolatedDefaults()
    defer { store.cleanup() }
    let wasOff = Self.freshDID("legacyoff")
    let wasOn = Self.freshDID("legacyon")
    store.standard.set(false, forKey: "blue.catbird.mls.optedIn.\(wasOff)")
    store.standard.set(true, forKey: "blue.catbird.mls.warningAcknowledged.\(wasOff)")
    store.standard.set(true, forKey: "blue.catbird.mls.optedIn.\(wasOn)")
    store.standard.set(true, forKey: "blue.catbird.mls.warningAcknowledged.\(wasOn)")
    store.standard.set(false, forKey: "mls_public_beta_enabled")
    store.appGroup.set(false, forKey: "circles_public_beta_enabled")

    let settings = store.settings()
    settings.migrateLegacyMLSOptInIfNeeded()

    #expect(store.standard.object(forKey: "blue.catbird.mls.optedIn.\(wasOff)") == nil)
    #expect(settings.isMLSChatEnabled(for: wasOff))
    #expect(!settings.hasSeenMLSIntro(for: wasOff))
    #expect(settings.shouldPresentMLSIntro(for: wasOff))
    #expect(settings.isMLSRuntimeAllowed(for: wasOn))
    #expect(store.standard.object(forKey: "mls_public_beta_enabled") == nil)
    #expect(store.appGroup.object(forKey: "circles_public_beta_enabled") == nil)

    // A later user opt-out survives another launch.
    settings.disableMLSChat(for: wasOn)
    settings.migrateLegacyMLSOptInIfNeeded()
    store.settings().migrateLegacyMLSOptInIfNeeded()
    #expect(!store.settings().isMLSChatEnabled(for: wasOn))
  }

  @Test("Opt-out disables the push gateway while the account is still active, then stores the choice, then resets MLS state")
  func optOutOrder() async throws {
    let store = IsolatedDefaults()
    defer { store.cleanup() }
    let settings = store.settings()
    let did = Self.freshDID("optout")
    settings.enableMLSChat(for: did)

    var events: [String] = []
    try await MLSUserOptOutSequence(
      unregisterPushGateway: { events.append("unregister active=\(settings.isMLSRuntimeAllowed(for: did))") },
      persistUserDisabled: {
        settings.disableMLSChat(for: did)
        events.append("persist")
      },
      resetLocalMLSState: { events.append("reset active=\(settings.isMLSRuntimeAllowed(for: did))") }
    ).run()

    #expect(events == ["unregister active=true", "persist", "reset active=false"])
  }

  @Test("A failed push unregister leaves encrypted chat enabled and local MLS state available for retry")
  func optOutFailureDoesNotClaimSuccess() async throws {
    let store = IsolatedDefaults()
    defer { store.cleanup() }
    let settings = store.settings()
    let did = Self.freshDID("optoutfailure")
    settings.enableMLSChat(for: did)

    var events: [String] = []
    await #expect(throws: NSError.self) {
      try await MLSUserOptOutSequence(
        unregisterPushGateway: {
          events.append("unregister")
          throw NSError(
            domain: "MLSDefaultOnConsentTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "offline"]
          )
        },
        persistUserDisabled: {
          settings.disableMLSChat(for: did)
          events.append("persist")
        },
        resetLocalMLSState: { events.append("reset") }
      ).run()
    }

    #expect(settings.isMLSRuntimeAllowed(for: did))
    #expect(events == ["unregister"])
  }

  @Test("A fresh signed-in account opens no MLS storage, enrollment or network before the introduction")
  func freshAccountStaysDormantBeforeIntroduction() async throws {
    let did = Self.freshDID("dormant")
    defer { ExperimentalSettings.shared.resetMLSSettings(for: did) }

    let loopbackURL = try #require(URL(string: "https://127.0.0.1"))
    let previousProtocols = NetworkService.getNetworkTestProtocolClasses()
    try #require(previousProtocols == nil, "The dormant-account fixture requires exclusive use of Petrel's network hook")
    NetworkService.setNetworkTestProtocolClasses([MLSDefaultOnConsentRefusalURLProtocol.self])
    let client = await ATProtoClient(baseURL: loopbackURL)
    NetworkService.setNetworkTestProtocolClasses(previousProtocols)
    let appState = AppState(userDID: did, client: client)
    defer { appState.cleanup() }

    #expect(ExperimentalSettings.shared.isMLSChatEnabled(for: did))
    #expect(!appState.isMLSRuntimeAllowed)

    #expect(await appState.getOrOpenMLSCoordinator() == nil)
    try await appState.initializeMLS()
    #expect(appState.mlsCoordinator == nil)
    #expect(appState.spacesEligibility == nil)
    if let storageRoot = try? MLSAppGroupStorage.defaultStorageRoot(),
       let dbURL = try? MLSAppGroupStorage.databaseURL(storageRoot: storageRoot, accountDid: did) {
      #expect(!FileManager.default.fileExists(atPath: dbURL.path))
    }

    ExperimentalSettings.shared.enableMLSChat(for: did)
    #expect(appState.isMLSRuntimeAllowed)
  }

  @Test("Account deletion contacts the chat server only for an account this device enrolled")
  func deletionPredicateUsesEnrollmentFact() throws {
    let store = IsolatedDefaults()
    defer { store.cleanup() }
    let settings = store.settings()
    let did = Self.freshDID("deletion")
    let emptyRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("catbird-default-on-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: emptyRoot) }
    let keychain = InMemoryCircleKeychain()

    #expect(settings.isMLSChatEnabled(for: did))
    #expect(!AccountDeletionCoordinator.requiresRemoteMLSErasure(
      forDID: did, hasActiveCoordinator: false, storageRoot: emptyRoot,
      circleKeychain: keychain, settings: settings))
    #expect(AccountDeletionCoordinator.requiresRemoteMLSErasure(
      forDID: did, hasActiveCoordinator: true, storageRoot: emptyRoot,
      circleKeychain: keychain, settings: settings))

    settings.recordMLSEnrollment(for: did)
    #expect(AccountDeletionCoordinator.requiresRemoteMLSErasure(
      forDID: did, hasActiveCoordinator: false, storageRoot: emptyRoot,
      circleKeychain: keychain, settings: settings))
  }

  @Test("The app bundle carries no build switch for encrypted chat or Circles")
  func noBuildSwitchesInInfoPlist() {
    let features = Bundle.main.object(forInfoDictionaryKey: "CatbirdFeatures") as? [String: Any] ?? [:]
    #expect(features["MLSChat"] == nil)
    #expect(features["CirclesSpaces"] == nil)
  }
}

private final class MLSDefaultOnConsentRefusalURLProtocol: URLProtocol, @unchecked Sendable {
  override static func canInit(with request: URLRequest) -> Bool { true }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
  }

  override func stopLoading() {}
}

@Suite("Encrypted chat preferences reach the notification extension")
struct MLSNotificationExtensionPreferenceTests {
  private static let accountDID = "did:plc:nsepreferenceaccount"

  @Test("The app stores the encrypted chat notification preference under the key the extension reads")
  func notificationPreferenceUsesExtensionKey() throws {
    let suiteName = "MLSNotificationPreference-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let hash = try MLSAppGroupStorage.accountDidHash(for: Self.accountDID)

    NotificationManager.storeMLSChatNotificationPreference(false, accountDID: Self.accountDID, defaults: defaults)

    #expect(defaults.object(forKey: "mlsChatNotificationsEnabled_\(hash)") as? Bool == false)
    #expect(defaults.object(forKey: "mlsChatNotificationsEnabled_\(Self.accountDID)") as? Bool == false)
  }

  @Test("The extension neutralizes encrypted chat wakes for an account whose user turned encrypted chat off")
  func extensionHonoursUserOptOut() async throws {
    let suiteName = "MLSNotificationOptOut-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let hash = try MLSAppGroupStorage.accountDidHash(for: Self.accountDID)
    defaults.set([Self.accountDID], forKey: "knownAccountDIDs")
    defaults.set(true, forKey: "mlsUserDisabled_\(hash)")

    let content = UNMutableNotificationContent()
    content.title = "Alice"
    content.body = "sealed"
    content.sound = .default
    content.userInfo = [
      "conversationId": "opted-out-conversation",
      "recipientAccountHash": hash,
      "wakeKind": "message",
    ]
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    let service = NotificationService(appGroupDefaults: defaults)
    let output: UNNotificationContent = await withCheckedContinuation { continuation in
      service.didReceive(request) { continuation.resume(returning: $0) }
    }
    withExtendedLifetime(service) {}

    #expect(output.title == "Catbird")
    #expect(output.body == "New activity")
    #expect(output.sound == nil)
    #expect(output.threadIdentifier == "catbird-unsupported")
  }
}
