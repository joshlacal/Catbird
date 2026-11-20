import CryptoKit
import Foundation
import Testing

@testable import Catbird

/// A tapped notification names its account by hash. It must resolve for any signed-in account,
/// including one that has not been opened since the app launched.
@Suite("Push Account Matching")
struct PushAccountMatchingTests {
  private func hash(_ did: String) -> String {
    SHA256.hash(data: Data(did.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  @Test("The hash resolves to the signed-in account it names, not just the first candidate")
  func resolvesTheNamedAccount() {
    let active = "did:plc:activeaccount000000000000"
    let other = "did:plc:otheraccount0000000000000"

    #expect(PushAccountMatching.accountDID(matchingHash: hash(other), among: [active, other]) == other)
    #expect(PushAccountMatching.accountDID(matchingHash: hash(active), among: [active, other]) == active)
    // The push may carry the hash in upper case or with stray whitespace.
    #expect(PushAccountMatching.accountDID(
      matchingHash: " \(hash(other).uppercased())\n", among: [active, other]) == other)
  }

  @Test("An unknown, malformed or empty hash resolves to no account")
  func unknownHashResolvesToNothing() {
    let active = "did:plc:activeaccount000000000000"
    #expect(PushAccountMatching.accountDID(
      matchingHash: hash("did:plc:signedoutaccount0000000000"), among: [active]) == nil)
    #expect(PushAccountMatching.accountDID(matchingHash: "abc123", among: [active]) == nil)
    #expect(PushAccountMatching.accountDID(matchingHash: "", among: [active]) == nil)
    #expect(PushAccountMatching.accountDID(matchingHash: hash(active), among: []) == nil)
  }

  @Test("Accounts published to the App Group are candidates before the account list has loaded")
  func publishedAccountsAreReadable() {
    let suite = "PushAccountMatchingTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(PushAccountMatching.publishedAccountDIDs(defaults: defaults).isEmpty)

    let unopened = "did:plc:unopenedaccount00000000000"
    defaults.set(["did:plc:activeaccount000000000000", unopened], forKey: PushAccountMatching.knownAccountDIDsKey)
    let published = PushAccountMatching.publishedAccountDIDs(defaults: defaults)
    #expect(PushAccountMatching.accountDID(matchingHash: hash(unopened), among: published) == unopened)
  }
}
