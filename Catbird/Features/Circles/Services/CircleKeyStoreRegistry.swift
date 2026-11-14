import Foundation

/// I5: one `CircleKeyStore` per account DID for the whole process.
///
/// `CircleKeyStore` does a load-modify-write of one Keychain item per Space.
/// Two store actors for the same account (a key manager from a closed
/// coordinator still finishing a `removeMember` while the next coordinator's
/// manager starts) could run those cycles in parallel and lose an update,
/// such as a `__acl__:<did>` pending-removal entry. Every manager created for
/// an account gets its store here, so all of that account's Keychain writes
/// serialize on one actor, however many managers or coordinators come and go.
///
/// Stores are held strongly (one small actor per account signed in during
/// the process); a store holds no key material in memory.
final class CircleKeyStoreRegistry: @unchecked Sendable {
  static let shared = CircleKeyStoreRegistry()

  private let lock = NSLock()
  private var stores: [String: CircleKeyStore] = [:]

  init() {}

  /// The account's store, created with `makeKeychain` on first use only.
  func store(accountDID: String, makeKeychain: () -> any CircleKeychain) -> CircleKeyStore {
    lock.withLock {
      if let existing = stores[accountDID] { return existing }
      let store = CircleKeyStore(accountDID: accountDID, keychain: makeKeychain())
      stores[accountDID] = store
      return store
    }
  }
}
