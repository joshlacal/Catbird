import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("Account switch re-authentication")
struct AccountSwitchReauthenticationTests {
  private let expiredDID = "did:plc:expiredaccount000000000"

  // MARK: - Session check classification

  @Test("Rejected sessions require signing in again")
  func authenticationErrorsRequireReauthentication() {
    let errors: [Error] = [
      Petrel.NetworkError.authenticationRequired,
      Petrel.NetworkError.expiredToken,
      Petrel.NetworkError.unauthorized,
      Petrel.NetworkError.authenticationFailed,
      Petrel.NetworkError.responseError(statusCode: 401),
      ATProtoXRPCError(error: "ExpiredToken", message: "Token has expired", statusCode: 400),
      ATProtoXRPCError(error: "InvalidToken", statusCode: 400),
      Catbird.AuthError.invalidSession,
      AccountSwitchError.reauthenticationRequired(did: expiredDID),
    ]
    for error in errors {
      #expect(
        AppStateManager.accountStatus(forSessionCheckError: error) == .reauthRequired,
        "\(error) should require signing in again"
      )
    }
  }

  @Test("Offline and server errors keep switching available")
  func transientErrorsKeepAccountActive() {
    let errors: [Error] = [
      URLError(.notConnectedToInternet),
      URLError(.timedOut),
      Petrel.NetworkError.requestFailed,
      Petrel.NetworkError.responseError(statusCode: 503),
      Petrel.NetworkError.serverError(code: 401, message: "DeviceNotRegistered"),
      Petrel.NetworkError.decodingError,
      ATProtoXRPCError(error: "InternalServerError", statusCode: 500),
      Catbird.AuthError.networkError(URLError(.networkConnectionLost)),
      Catbird.AuthError.timeout,
    ]
    for error in errors {
      #expect(
        AppStateManager.accountStatus(forSessionCheckError: error) == .active,
        "\(error) should not block the switch"
      )
    }
  }

  @Test("getSession responses map to account status")
  func sessionResponseClassification() {
    #expect(AppStateManager.accountStatus(responseCode: 401, isActive: nil, status: nil) == .reauthRequired)
    #expect(AppStateManager.accountStatus(responseCode: 200, isActive: true, status: nil) == .active)
    #expect(AppStateManager.accountStatus(responseCode: 200, isActive: nil, status: nil) == .active)
    #expect(AppStateManager.accountStatus(responseCode: 200, isActive: false, status: nil) == .deactivated)
    #expect(AppStateManager.accountStatus(responseCode: 200, isActive: false, status: "deactivated") == .deactivated)
    #expect(AppStateManager.accountStatus(responseCode: 200, isActive: false, status: "takendown") == .deactivated)
    #expect(AppStateManager.accountStatus(responseCode: 200, isActive: nil, status: "suspended") == .takendown)
    #expect(AppStateManager.accountStatus(responseCode: 500, isActive: false, status: "deactivated") == .active)
  }

  // MARK: - Outcome mapping

  @Test("Switch outcomes map to the right feedback")
  func outcomeFeedback() {
    #expect(
      AppStateManager.feedback(for: .needsReauthentication(accountDID: expiredDID))
        == .promptReauthentication(did: expiredDID)
    )
    #expect(AppStateManager.feedback(for: .failed("Couldn’t switch.")) == .toast("Couldn’t switch."))
    #expect(AppStateManager.feedback(for: .blockedBySettings("Saving failed.")) == .toast("Saving failed."))
    #expect(
      AppStateManager.feedback(for: .busy)
        == .toast("Another account is still switching. Try again in a moment.")
    )
    #expect(AppStateManager.feedback(for: .switched(accountDID: expiredDID, reopenID: nil)) == nil)
    #expect(AppStateManager.feedback(for: .unchanged) == nil)
    #expect(AppStateManager.feedback(for: .cancelled) == nil)
  }

  @Test("The session-expired prompt names the account by handle")
  func promptMessage() {
    let prompt = AppStateManager.ReauthenticationPrompt(did: expiredDID, accountLabel: "@alice.test")
    #expect(prompt.message == "Your session for @alice.test has expired. Sign in again to switch to this account.")
    let unnamed = AppStateManager.ReauthenticationPrompt(did: expiredDID, accountLabel: nil)
    #expect(!unnamed.message.contains("did:"))
  }

  // MARK: - Toolbar account labels

  @Test("Account menu labels fall back from name to handle to Loading…")
  func menuLabelFallback() {
    let named = AccountMenuLabels(displayName: "Alice", handle: "alice.test")
    #expect(named.title == "Alice")
    #expect(named.subtitle == "@alice.test")

    let handleOnly = AccountMenuLabels(displayName: "  ", handle: "alice.test")
    #expect(handleOnly.title == "@alice.test")
    #expect(handleOnly.subtitle == nil)

    let unknown = AccountMenuLabels(displayName: nil, handle: nil)
    #expect(unknown.title == "Loading…")
    #expect(unknown.subtitle == nil)
  }

  @Test("Account menu labels never show a DID")
  func menuLabelsNeverShowDID() {
    let didLike = AccountMenuLabels(displayName: expiredDID, handle: expiredDID)
    #expect(didLike.title == "Loading…")
    #expect(didLike.subtitle == nil)

    let account = AuthenticationManager.AccountInfo(
      did: expiredDID,
      handle: expiredDID,
      isActive: false,
      cachedHandle: nil,
      cachedDisplayName: nil,
      cachedAvatarURL: nil
    )
    let labels = AccountMenuLabels(account: account)
    #expect(!labels.title.contains("did:"))
    #expect(labels.subtitle?.contains("did:") != true)

    let cached = AuthenticationManager.AccountInfo(
      did: expiredDID,
      handle: nil,
      isActive: false,
      cachedHandle: "bob.test",
      cachedDisplayName: nil,
      cachedAvatarURL: nil
    )
    #expect(AccountMenuLabels(account: cached).title == "@bob.test")
  }

  // MARK: - Expired-account bookkeeping

  @Test("Auto sign-out during a switch is held and handed over once")
  @MainActor
  func autoLogoutDeferredDuringSwitch() async {
    let manager = AuthenticationManager(userDefaults: UserDefaults(suiteName: "AccountSwitchReauth-\(UUID())")!)
    manager.setAuthenticatedForTesting(did: "did:plc:previousaccount0000000")
    manager.beginDeferringAutoLogout()
    await manager.handleAutoLogoutFromPetrel(did: expiredDID, reason: "gateway_session_expired")
    // Nothing is torn down while the switch owns authentication.
    #expect(manager.state == .authenticated(userDID: "did:plc:previousaccount0000000"))
    #expect(manager.expiredAccountInfo == nil)
    #expect(manager.takeDeferredAutoLogout() == nil)
    manager.endDeferringAutoLogout()
    #expect(manager.takeDeferredAutoLogout() == .init(did: expiredDID, reason: "gateway_session_expired"))
    #expect(manager.takeDeferredAutoLogout() == nil)
  }

  @Test("A rejected session for an inactive account doesn’t sign out the active one")
  @MainActor
  func autoLogoutForInactiveAccountIgnored() async {
    let manager = AuthenticationManager(userDefaults: UserDefaults(suiteName: "AccountSwitchReauth-\(UUID())")!)
    manager.setAuthenticatedForTesting(did: "did:plc:previousaccount0000000")
    await manager.handleAutoLogoutFromPetrel(did: expiredDID, reason: "gateway_session_expired")
    #expect(manager.state == .authenticated(userDID: "did:plc:previousaccount0000000"))
    #expect(manager.expiredAccountInfo == nil)
  }

  @Test("Expired-account info is only discarded for its own account")
  @MainActor
  func discardExpiredAccountInfoTargetsOneAccount() {
    let manager = AuthenticationManager(userDefaults: UserDefaults(suiteName: "AccountSwitchReauth-\(UUID())")!)
    manager.markAccountNeedsReauthentication(did: expiredDID)
    manager.discardExpiredAccountInfo(for: "did:plc:someoneelse00000000000")
    #expect(manager.expiredAccountInfo?.did == expiredDID)
    manager.discardExpiredAccountInfo(for: expiredDID)
    #expect(manager.expiredAccountInfo == nil)
  }
}
