import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("AppStateManager push presence lifecycle publishing", .serialized)
struct AppStateManagerPushPresenceTests {
  static let accountA = "did:plc:lifecycleaccounta"
  static let accountB = "did:plc:lifecycleaccountb"

  @Test("Lifecycle transitions publish push presence to App Group defaults")
  @MainActor
  func lifecycleTransitionsPublishPushPresence() async {
    let suiteName = "LifecyclePushPresenceTest-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let manager = AppStateManager.shared
    manager.setPushPresenceDefaultsForTesting(defaults)
    manager.setRegisteredAccountDIDsForTesting([Self.accountA])
    defer {
      manager.setPushPresenceDefaultsForTesting(nil)
      manager.setRegisteredAccountDIDsForTesting(nil)
      manager.setLifecycleForTesting(.unauthenticated)
    }

    let client = await ATProtoClient(baseURL: URL(string: "https://fixture.invalid")!)
    let stateA = AppState(userDID: Self.accountA, client: client)
    let stateB = AppState(userDID: Self.accountB, client: client)

    // Authenticate with account A
    manager.setLifecycleForTesting(.authenticated(stateA))
    #expect(!defaults.bool(forKey: SignedOutPushSuppression.signedOutKey))
    #expect(defaults.string(forKey: SignedOutPushSuppression.pushActiveAccountDIDKey) == Self.accountA)
    #expect(SignedOutPushSuppression.sessionEndedAccountDIDs(in: defaults) == [])

    // A, the only stored account, signs out: logout records its session end, then the
    // lifecycle moves to sign-in with no account left signed in
    SignedOutPushSuppression.recordSessionEndedAccount(Self.accountA, in: defaults)
    manager.setLifecycleForTesting(.unauthenticated)
    #expect(manager.pushPresence == .signedOut)
    #expect(defaults.bool(forKey: SignedOutPushSuppression.signedOutKey))
    #expect(defaults.string(forKey: SignedOutPushSuppression.pushActiveAccountDIDKey) == nil)
    #expect(SignedOutPushSuppression.sessionEndedAccountDIDs(in: defaults) == [Self.accountA])

    // Authenticate with account B
    manager.setLifecycleForTesting(.authenticated(stateB))
    #expect(!defaults.bool(forKey: SignedOutPushSuppression.signedOutKey))
    #expect(defaults.string(forKey: SignedOutPushSuppression.pushActiveAccountDIDKey) == Self.accountB)
    #expect(SignedOutPushSuppression.sessionEndedAccountDIDs(in: defaults) == [Self.accountA])
    // Push presence never writes the widgets' and App Intents' signed-in key
    #expect(defaults.object(forKey: "activeAccountDID") == nil)
  }

  @Test("Signing out of one account keeps a still-signed-in stored account's pushes")
  @MainActor
  func signOutKeepsOtherSignedInAccountPushes() async {
    let suiteName = "LifecyclePushPresenceMulti-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let manager = AppStateManager.shared
    manager.setPushPresenceDefaultsForTesting(defaults)
    manager.setRegisteredAccountDIDsForTesting([Self.accountA, Self.accountB])
    defer {
      manager.setPushPresenceDefaultsForTesting(nil)
      manager.setRegisteredAccountDIDsForTesting(nil)
      manager.setLifecycleForTesting(.unauthenticated)
    }

    let client = await ATProtoClient(baseURL: URL(string: "https://fixture.invalid")!)
    manager.setLifecycleForTesting(.authenticated(AppState(userDID: Self.accountA, client: client)))

    // A signs out (or its session expires); B stays stored, signed in and registered for push
    SignedOutPushSuppression.recordSessionEndedAccount(Self.accountA, in: defaults)
    manager.setLifecycleForTesting(.unauthenticated)
    #expect(manager.pushPresence == .noActiveAccount)
    #expect(!defaults.bool(forKey: SignedOutPushSuppression.signedOutKey))
    #expect(defaults.string(forKey: SignedOutPushSuppression.pushActiveAccountDIDKey) == nil)
    #expect(manager.sessionEndedPushAccountDIDs == [Self.accountA])

    // The extension delivers B's pushes and neutralizes A's; an unnamed recipient is not guessed
    #expect(!NotificationService.isAddressedToSignedOutAccount(recipientDID: Self.accountB, defaults: defaults))
    #expect(NotificationService.isAddressedToSignedOutAccount(recipientDID: Self.accountA, defaults: defaults))
    #expect(!NotificationService.isAddressedToSignedOutAccount(recipientDID: nil, defaults: defaults))

    // The foreground applies the same rule
    #expect(!SignedOutPushSuppression.suppresses(
      recipientDID: Self.accountB, presence: manager.pushPresence,
      sessionEndedAccountDIDs: manager.sessionEndedPushAccountDIDs))
    #expect(SignedOutPushSuppression.suppresses(
      recipientDID: Self.accountA, presence: manager.pushPresence,
      sessionEndedAccountDIDs: manager.sessionEndedPushAccountDIDs))
  }

  @Test("The App Group account list drops activeAccountDID when no account is active")
  @MainActor
  func accountListRemovesActiveAccountOnSignOut() async {
    let suiteName = "LifecycleAccountList-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let presenceSuiteName = "LifecycleAccountListPresence-\(UUID().uuidString)"
    let presenceDefaults = UserDefaults(suiteName: presenceSuiteName)!
    defer { presenceDefaults.removePersistentDomain(forName: presenceSuiteName) }

    let manager = AppStateManager.shared
    manager.setPushPresenceDefaultsForTesting(presenceDefaults)
    defer {
      manager.setPushPresenceDefaultsForTesting(nil)
      manager.setLifecycleForTesting(.unauthenticated)
    }

    let client = await ATProtoClient(baseURL: URL(string: "https://fixture.invalid")!)
    manager.setLifecycleForTesting(.authenticated(AppState(userDID: Self.accountA, client: client)))
    manager.writeAccountsToAppGroupForTesting(in: defaults)
    #expect(defaults.string(forKey: "activeAccountDID") == Self.accountA)

    // The notification widget shows "Not signed in" and intents throw notSignedIn without it
    manager.setLifecycleForTesting(.unauthenticated)
    manager.writeAccountsToAppGroupForTesting(in: defaults)
    #expect(defaults.object(forKey: "activeAccountDID") == nil)
  }

  @Test("A failed switch that ends at sign-in records neither account as ended")
  @MainActor
  func failedSwitchRecordsNoEndedAccount() async {
    let suiteName = "LifecyclePushPresenceSwitch-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let manager = AppStateManager.shared
    manager.setPushPresenceDefaultsForTesting(defaults)
    manager.setRegisteredAccountDIDsForTesting([Self.accountA, Self.accountB])
    defer {
      manager.setPushPresenceDefaultsForTesting(nil)
      manager.setRegisteredAccountDIDsForTesting(nil)
      manager.setLifecycleForTesting(.unauthenticated)
    }

    let client = await ATProtoClient(baseURL: URL(string: "https://fixture.invalid")!)
    let stateA = AppState(userDID: Self.accountA, client: client)

    // A switch from A starts at .launching and, when retiring A fails after B was verified,
    // ends at .unauthenticated (markAccountSwitchRestartRequired). Both sessions are intact.
    manager.setLifecycleForTesting(.authenticated(stateA))
    manager.setLifecycleForTesting(.launching)
    manager.setLifecycleForTesting(.unauthenticated)
    #expect(SignedOutPushSuppression.sessionEndedAccountDIDs(in: defaults) == [])
    #expect(!defaults.bool(forKey: SignedOutPushSuppression.signedOutKey))
    #expect(!NotificationService.isAddressedToSignedOutAccount(recipientDID: Self.accountA, defaults: defaults))
    #expect(!NotificationService.isAddressedToSignedOutAccount(recipientDID: Self.accountB, defaults: defaults))
  }

  @Test("A launch without a current account records nothing and keeps a signed-in account's pushes")
  @MainActor
  func launchWithoutCurrentAccountRecordsNoEndedAccount() {
    let suiteName = "LifecyclePushPresenceLaunch-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    // A signed out in an earlier run while B stayed stored and signed in. A leftover
    // activeAccountDID naming B must not make B count as ended.
    defaults.set(Self.accountB, forKey: "activeAccountDID")
    defaults.set([Self.accountA], forKey: SignedOutPushSuppression.sessionEndedAccountDIDsKey)

    let manager = AppStateManager.shared
    manager.setPushPresenceDefaultsForTesting(defaults)
    manager.setRegisteredAccountDIDsForTesting([Self.accountA, Self.accountB])
    defer {
      manager.setPushPresenceDefaultsForTesting(nil)
      manager.setRegisteredAccountDIDsForTesting(nil)
      manager.setLifecycleForTesting(.unauthenticated)
    }

    manager.setLifecycleForTesting(.launching)
    manager.setLifecycleForTesting(.unauthenticated)
    #expect(SignedOutPushSuppression.sessionEndedAccountDIDs(in: defaults) == [Self.accountA])
    #expect(!defaults.bool(forKey: SignedOutPushSuppression.signedOutKey))
    #expect(!NotificationService.isAddressedToSignedOutAccount(recipientDID: Self.accountB, defaults: defaults))
    #expect(NotificationService.isAddressedToSignedOutAccount(recipientDID: Self.accountA, defaults: defaults))
  }
}
