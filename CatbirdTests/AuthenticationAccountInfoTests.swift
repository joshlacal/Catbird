import Testing
@testable import Catbird

@Suite("Authentication account info tests")
struct AuthenticationAccountInfoTests {

  @Test("Login handle ignores DID values and falls back to cached handle")
  func loginHandleIgnoresDIDValues() {
    let account = AuthenticationManager.AccountInfo(
      did: "did:plc:test",
      handle: "did:plc:test",
      isActive: false,
      cachedHandle: "test.bsky.social"
    )

    #expect(account.loginHandle == "test.bsky.social")
  }

  @Test("Login handle is nil when only DID is available")
  func loginHandleUnavailableForDIDOnlyAccount() {
    let account = AuthenticationManager.AccountInfo(
      did: "did:plc:test",
      handle: "did:plc:test",
      isActive: false
    )

    #expect(account.loginHandle == nil)
  }
}
