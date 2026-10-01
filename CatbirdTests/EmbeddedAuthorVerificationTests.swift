@testable import Catbird
import Petrel
import Testing

@Suite("Embedded author verification metadata")
struct EmbeddedAuthorVerificationTests {
  private func state(_ verified: String, _ trusted: String) -> AppBskyActorDefs.VerificationState {
    .init(verifications: [], verifiedStatus: verified, trustedVerifierStatus: trusted)
  }
  @Test func missingMetadataIsUnbadged() {
    #expect(VerificationBadge.metadataKind(for: nil) == nil)
  }
  @Test func verifiedMetadataUsesRegularBadge() {
    #expect(VerificationBadge.metadataKind(for: state("valid", "none")) == .regular)
  }
  @Test func trustedVerifierMetadataUsesTrustedBadge() {
    #expect(VerificationBadge.metadataKind(for: state("none", "valid")) == .trustedVerifier)
  }
  @Test func trustedVerifierTakesPrecedence() {
    #expect(VerificationBadge.metadataKind(for: state("valid", "valid")) == .trustedVerifier)
  }
  @Test func unverifiedMetadataIsUnbadged() {
    #expect(VerificationBadge.metadataKind(for: state("none", "none")) == nil)
  }
  @Test func invalidMetadataIsUnbadged() {
    #expect(VerificationBadge.metadataKind(for: state("invalid", "invalid")) == nil)
  }
  @Test func unknownMetadataIsUnbadged() {
    #expect(VerificationBadge.metadataKind(for: state("unknown", "unknown")) == nil)
  }
  @Test func hiddenRegularBadgeIsAbsent() {
    #expect(VerificationBadge.metadataKind(for: state("valid", "none"), hideBadges: true) == nil)
  }
  @Test func hiddenTrustedBadgeIsAbsent() {
    #expect(VerificationBadge.metadataKind(for: state("valid", "valid"), hideBadges: true) == nil)
  }
  @Test func embedMetadataDoesNotUseLegacyIdentityFallback() throws {
    let did = try DID(didString: VerificationBadge.selfVerifiedDID)
    #expect(VerificationBadge.kind(for: nil, did: did) == .regular)
    #expect(VerificationBadge.metadataKind(for: nil) == nil)
  }
}
