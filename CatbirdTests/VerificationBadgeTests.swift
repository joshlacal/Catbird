@testable import Catbird
import Petrel
import Testing

@Suite("VerificationBadge.kind")
struct VerificationBadgeTests {
  private static let regularDID = try! DID(didString: "did:plc:abcdefghijklmnopqrstuvwx")
  private static let selfDID = try! DID(didString: VerificationBadge.selfVerifiedDID)

  private func state(verified: String, trustedVerifier: String) -> AppBskyActorDefs.VerificationState {
    AppBskyActorDefs.VerificationState(
      verifications: [],
      verifiedStatus: verified,
      trustedVerifierStatus: trustedVerifier
    )
  }

  @Test func nilStateNoBadge() {
    #expect(VerificationBadge.kind(for: nil, did: Self.regularDID) == nil)
  }

  @Test func neitherValidNoBadge() {
    let s = state(verified: "none", trustedVerifier: "none")
    #expect(VerificationBadge.kind(for: s, did: Self.regularDID) == nil)
  }

  @Test func verifiedOnlyIsRegular() {
    let s = state(verified: "valid", trustedVerifier: "none")
    #expect(VerificationBadge.kind(for: s, did: Self.regularDID) == .regular)
  }

  @Test func trustedVerifierWinsOverRegular() {
    let s = state(verified: "valid", trustedVerifier: "valid")
    #expect(VerificationBadge.kind(for: s, did: Self.regularDID) == .trustedVerifier)
  }

  @Test func trustedVerifierWithoutRegularStillShows() {
    let s = state(verified: "none", trustedVerifier: "valid")
    #expect(VerificationBadge.kind(for: s, did: Self.regularDID) == .trustedVerifier)
  }

  @Test func selfDidFallsBackToRegular() {
    #expect(VerificationBadge.kind(for: nil, did: Self.selfDID) == .regular)
  }

  @Test func invalidStatusesIgnored() {
    let s = state(verified: "invalid", trustedVerifier: "invalid")
    #expect(VerificationBadge.kind(for: s, did: Self.regularDID) == nil)
  }
}
