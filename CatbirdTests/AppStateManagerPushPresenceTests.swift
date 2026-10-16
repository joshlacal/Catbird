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
    defer {
      manager.setPushPresenceDefaultsForTesting(nil)
      manager.setLifecycleForTesting(.unauthenticated)
    }

    let client = await ATProtoClient(baseURL: URL(string: "https://fixture.invalid")!)
    let stateA = AppState(userDID: Self.accountA, client: client)
    let stateB = AppState(userDID: Self.accountB, client: client)

    // Authenticate with account A
    manager.setLifecycleForTesting(.authenticated(stateA))
    #expect(!defaults.bool(forKey: SignedOutPushSuppression.signedOutKey))
    #expect(defaults.string(forKey: SignedOutPushSuppression.activeAccountDIDKey) == Self.accountA)
    #expect(SignedOutPushSuppression.sessionEndedAccountDIDs(in: defaults) == [])

    // Transition to unauthenticated (sign-out)
    manager.setLifecycleForTesting(.unauthenticated)
    #expect(defaults.bool(forKey: SignedOutPushSuppression.signedOutKey))
    #expect(defaults.string(forKey: SignedOutPushSuppression.activeAccountDIDKey) == Self.accountA)
    #expect(SignedOutPushSuppression.sessionEndedAccountDIDs(in: defaults) == [Self.accountA])

    // Authenticate with account B
    manager.setLifecycleForTesting(.authenticated(stateB))
    #expect(!defaults.bool(forKey: SignedOutPushSuppression.signedOutKey))
    #expect(defaults.string(forKey: SignedOutPushSuppression.activeAccountDIDKey) == Self.accountB)
    #expect(SignedOutPushSuppression.sessionEndedAccountDIDs(in: defaults) == [Self.accountA])
  }
}
