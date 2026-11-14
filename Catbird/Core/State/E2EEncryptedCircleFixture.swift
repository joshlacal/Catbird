#if DEBUG
import CatbirdMLSCore
import Foundation
import Petrel
import PetrelCatbird

/// DEBUG-only encrypted-Circle machinery for `--e2e-fixture-account` runs
/// launched with `--e2e-encrypted-circles` (E2EE Circles Task 18 A).
///
/// It drives the real `CircleService`, `CircleKeyManager` and
/// `CirclePostOpener` over fakes so the encrypted-Circle UI states can be
/// reached without the FFI, a network or a Labyrinth enrollment:
/// - Close Friends (Alice owns it): Alice holds key v1; Bob has a pending
///   history re-wrap ("Key refresh pending" badge). One envelope opens, one
///   fails to open ("Couldn't verify this post's author").
/// - Book Club (Bob owns it): Alice holds no key, so its envelope waits for
///   Bob ("Waiting for @bob.test …") and the composer shows "Encryption keys
///   not available yet".
enum E2EEncryptedCircleFixture {
  static var isEnabled: Bool {
    ProcessInfo.processInfo.arguments.contains("--e2e-encrypted-circles")
  }

  struct Machinery {
    let service: CircleService
    let opener: CirclePostOpener
    let seeded: Task<Void, Never>
  }

  static func make(accountDID: DID, transport: E2ECircleTransport) -> Machinery {
    let crypto = E2EFakeCircleCrypto()
    let store = CircleKeyStore(accountDID: accountDID.didString(), keychain: E2EInMemoryCircleKeychain())
    let keys = CircleKeyManager(crypto: crypto, store: store, transport: transport, ownerDID: accountDID)
    let service = CircleService(
      transport: transport, keyManager: keys, crypto: crypto, accountDID: accountDID, mailboxEnrolled: { true }
    )
    let opener = CirclePostOpener(
      crypto: crypto, keys: keys, epochs: E2EFakeAuthorEpochResolver(), accountDID: accountDID.didString()
    )
    let seeded = Task {
      guard accountDID.didString() == E2EConstants.aliceDIDString else { return }
      let space = E2EConstants.closeFriendsURI.uriString()
      try? await store.store(
        spaceURI: space, keyVersion: 1, circleKey: Data(repeating: 0x41, count: 32),
        createdAt: Date(), reason: "created"
      )
      try? await store.setPendingRewrap(spaceURI: space, did: E2EConstants.bobDIDString, reason: "history rewrap")
    }
    return Machinery(service: service, opener: opener, seeded: seeded)
  }
}

/// In-memory `CircleKeychain`: nothing reaches the simulator's Keychain.
final class E2EInMemoryCircleKeychain: CircleKeychain, @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String: [String: Data]] = [:]

  func read(service: String, account: String) throws -> Data? {
    lock.withLock { items[service]?[account] }
  }

  func write(service: String, account: String, data: Data, accessibility: String) throws {
    lock.withLock { items[service, default: [:]][account] = data }
  }

  func delete(service: String, account: String) throws {
    lock.withLock { _ = items[service]?.removeValue(forKey: account) }
  }

  func accounts(service: String) throws -> [String] {
    lock.withLock { items[service].map { Array($0.keys) } ?? [] }
  }
}

/// Opens every envelope to a fixed payload except the "unverifiable" one,
/// which fails as an author-signature mismatch would. Wrapping, sealing and
/// key opening are refused: the fixture never writes key records or posts.
actor E2EFakeCircleCrypto: CircleCrypto {
  struct Refused: Error {}

  func generateCircleKey() async throws -> Data { Data(repeating: 0x41, count: 32) }

  func wrapCircleKey(
    circleID: String, keyVersion: UInt64, spaceURI: String, reason: String,
    memberDIDs: [String], circleKey: Data, createdAt: Date
  ) async throws -> CircleKeyWrapOutcome { throw Refused() }

  func openCircleKey(recordJSON: String, spaceURI: String, ownerDID: String) async throws -> OpenedCircleKey? { nil }

  func sealPost(
    circleID: String, keyVersion: UInt64, circleKey: Data, postURI: String, authorDID: String,
    createdAt: Date, payloadJSON: String, replyJSON: String?, attachmentsJSON: [String]
  ) async throws -> String { throw Refused() }

  func openPost(
    recordJSON: String, postURI: String, authorDID: String, circleKey: Data, authorEpochJSON: String
  ) async throws -> String {
    guard postURI != E2EConstants.encryptedUnverifiablePostURI.uriString() else {
      throw CircleCryptoError.notOpenable("fixture signature mismatch")
    }
    let createdAt = ATProtocolDate(date: Date().addingTimeInterval(-180)).iso8601String
    return "{\"created_at\":\"\(createdAt)\",\"media\":[],\"post\":{\"$type\":\"app.bsky.feed.post\","
      + "\"createdAt\":\"\(createdAt)\",\"langs\":[\"en\"],\"text\":\"\(E2EConstants.encryptedReadableText)\"}}"
  }

  nonisolated func postKey(circleKey: Data, circleID: String, postURI: String) throws -> Data {
    Data(repeating: 0, count: 32)
  }
}

/// Answers any author-epoch lookup with an epoch-0 mailboxKeys record.
struct E2EFakeAuthorEpochResolver: AuthorEpochResolver {
  func epochJSON(did: DID, epochHead: Data) async throws -> String {
    "{\"current\":{\"epochNumber\":0,\"epochHead\":{\"$bytes\":\"\(epochHead.base64EncodedString())\"}}}"
  }
}
#endif
