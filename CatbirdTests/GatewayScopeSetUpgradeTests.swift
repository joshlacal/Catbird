import CatbirdMLSCore
import Foundation
import Petrel
import Testing
@testable import Catbird

/// Encrypted chat needs several OAuth scopes granted in one consent. These pin the
/// scope-set upgrade and the cache that records what the gateway really granted.
@Suite("Gateway Scope-Set Upgrade Tests")
struct GatewayScopeSetUpgradeTests {
  private static let did = "did:plc:test1234"
  private static let callback = URL(string: "https://catbird.blue/oauth/permission-callback?code=one-time")!
  private static var chatScopes: Set<String> {
    Set(MLSAppGroupStorage.requiredSpacesScopes).subtracting(["atproto"])
  }

  @MainActor
  private func makeTestAuthManager() async throws -> AuthenticationManager {
    let suiteName = "test-auth-\(UUID().uuidString)"
    let isolatedDefaults = UserDefaults(suiteName: suiteName)!
    isolatedDefaults.removePersistentDomain(forName: suiteName)
    let authManager = AuthenticationManager(userDefaults: isolatedDefaults)
    let client = try await ATProtoClient(
      baseURL: URL(string: "https://bsky.social")!,
      oauthConfig: OAuthConfiguration(
        clientId: "https://catbird.blue/oauth-client-metadata.json",
        redirectUri: "https://catbird.blue/oauth/callback",
        scope: "atproto transition:generic transition:chat.bsky"
      ),
      namespace: "blue.catbird.test",
      authMode: .legacy,
      userAgent: "CatbirdTest/1.0"
    )
    authManager.setAuthenticatedForTesting(did: Self.did, client: client)
    return authManager
  }

  @Test("Encrypted chat asks for six scopes besides the sign-in itself")
  func chatScopeSetIsSixScopes() {
    #expect(Self.chatScopes.count == 6)
    #expect(Self.chatScopes.contains { $0.hasPrefix("space:blue.catbird.labyrinth.mailbox?") })
    #expect(Self.chatScopes.contains { $0.hasPrefix("space:blue.catbird.labyrinth.conversation?") })
  }

  @Test("All scopes go to the gateway in one upgrade and the full grant comes back")
  @MainActor
  func requestsEveryScopeInOneConsent() async throws {
    let authManager = try await makeTestAuthManager()
    let requested = Self.chatScopes
    let grant = requested.union(["atproto", "transition:generic"])

    var startCalls: [Set<String>] = []
    authManager.startGatewayScopeUpgradeHook = { requesting, did, callbackURL in
      #expect(did == Self.did)
      #expect(callbackURL == GatewayPermission.permissionCallbackURL)
      startCalls.append(requesting)
      return URL(string: "https://nest.catbird.blue/auth/upgrade?session=123")!
    }
    authManager.completeGatewayScopeUpgradeHook = { callbackURL, did in
      #expect(callbackURL == Self.callback)
      #expect(did == Self.did)
      return grant
    }

    var presentCount = 0
    let granted = try await authManager.requestGatewayScopes(requested, label: "encrypted chat") { _ in
      presentCount += 1
      return Self.callback
    }

    #expect(startCalls == [requested])
    #expect(presentCount == 1)
    #expect(granted == grant)
    #expect(authManager.state == .authenticated(userDID: Self.did))
  }

  @Test("A partial grant is returned to the caller rather than treated as success or failure")
  @MainActor
  func partialGrantIsReturnedAsIs() async throws {
    let authManager = try await makeTestAuthManager()
    authManager.startGatewayScopeUpgradeHook = { _, _, _ in
      URL(string: "https://nest.catbird.blue/auth/upgrade")!
    }
    authManager.completeGatewayScopeUpgradeHook = { _, _ in
      Set(["atproto", "blob:*/*"])
    }

    let granted = try await authManager.requestGatewayScopes(Self.chatScopes, label: "encrypted chat") { _ in
      Self.callback
    }

    #expect(granted == Set(["atproto", "blob:*/*"]))
    #expect(!granted.isSuperset(of: Self.chatScopes))
  }

  @Test("Closing the consent page throws cancelled, redeems nothing and frees the next request")
  @MainActor
  func cancellingConsentLeavesTheSessionAlone() async throws {
    let authManager = try await makeTestAuthManager()
    authManager.startGatewayScopeUpgradeHook = { _, _, _ in
      URL(string: "https://nest.catbird.blue/auth/upgrade")!
    }
    var completeCalled = false
    authManager.completeGatewayScopeUpgradeHook = { _, _ in
      completeCalled = true
      return Self.chatScopes
    }

    await #expect(throws: GatewayPermissionError.cancelled) {
      _ = try await authManager.requestGatewayScopes(Self.chatScopes, label: "encrypted chat") { _ in
        throw CancellationError()
      }
    }
    #expect(!completeCalled)
    #expect(authManager.state == .authenticated(userDID: Self.did))

    // The in-flight record is cleared, so a single-permission request is not refused.
    authManager.fetchGrantedScopesHook = { _ in Set(["identity:handle"]) }
    try await authManager.ensureGatewayPermission(.identityHandle) { _ in
      Issue.record("Should not present when the permission is already granted")
      return Self.callback
    }
  }

  @Test("An empty request is refused before the gateway is contacted")
  @MainActor
  func emptyRequestIsRefused() async throws {
    let authManager = try await makeTestAuthManager()
    authManager.startGatewayScopeUpgradeHook = { _, _, _ in
      Issue.record("The gateway must not be contacted for an empty request")
      return URL(string: "https://nest.catbird.blue/auth/upgrade")!
    }

    await #expect(throws: GatewayPermissionError.self) {
      _ = try await authManager.requestGatewayScopes([], label: "encrypted chat") { _ in Self.callback }
    }
  }

  @Test("The scope cache holds only gateway answers and ignores the retired key")
  func cacheIgnoresTheRetiredAssumedGrant() throws {
    let suiteName = "test-scope-cache-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let did = "did:plc:MixedCase1234"

    // The retired key held the scopes chat needs, written without asking the server.
    defaults.set(MLSAppGroupStorage.requiredSpacesScopes, forKey: "blue.catbird.oauth.scopes.\(did.lowercased())")
    #expect(MLSGrantedScopeCache.load(for: did, defaults: defaults) == nil)

    MLSGrantedScopeCache.store(["transition:generic", "atproto"], for: did, defaults: defaults)
    #expect(MLSGrantedScopeCache.load(for: did, defaults: defaults) == ["atproto", "transition:generic"])
    #expect(MLSGrantedScopeCache.load(for: did.uppercased(), defaults: defaults) == ["atproto", "transition:generic"])
  }
}
