import CryptoKit
import Foundation
import Petrel
import PetrelCatbird

/// The exact bytes of every encrypted Circle post record the AppView served,
/// for the opener (raw-bytes contract, spec §7).
///
/// `getFeed` and `getPostThread` are decoded twice: typed for Swift, and
/// sliced here with `RawJSON` so `CirclePostOpener` hands the FFI the record
/// exactly as served, never Petrel's re-encoding (which adds a nested
/// `reply.$type` and reformats bytes fields).
///
/// Entries are keyed by what the typed envelope already carries: the post URI
/// and CID plus `keyVersion` and a digest of `ciphertext`/`sig`. A slice is
/// registered under the key of its own typed decode, so a lookup from the
/// typed envelope finds only bytes that decode to that same envelope.
///
/// Memory only, bounded (`capacity`, oldest out first). The records are
/// ciphertext envelopes: nothing here is plaintext or key material.
final class CircleRawRecordCache: @unchecked Sendable {
  static let shared = CircleRawRecordCache()

  private let lock = NSLock()
  private let capacity: Int
  private var records: [String: Data] = [:]
  private var order: [String] = []

  init(capacity: Int = 4096) {
    self.capacity = capacity
  }

  /// The raw record for `envelope` at `uri`/`cid`, or nil when no response
  /// carrying it was sliced.
  func record(uri: ATProtocolURI, cid: CID, envelope: BlueCatbirdCirclePost) -> Data? {
    record(uri: uri, cid: CIDString(cid), envelope: envelope)
  }

  func record(uri: ATProtocolURI, cid: CIDString, envelope: BlueCatbirdCirclePost) -> Data? {
    let key = Self.key(uri: uri, cidString: cid.string, record: envelope)
    return lock.withLock { records[key] }
  }

  /// Registers `raw` (one `blue.catbird.circle.post` record value) served at
  /// `uri`/`cid`. Ignored unless it decodes as an envelope.
  func register(raw: Data, uri: ATProtocolURI, cid: CID) {
    register(raw: raw, uri: uri, cid: CIDString(cid))
  }

  func register(raw: Data, uri: ATProtocolURI, cid: CIDString) {
    guard let typed = try? JSONDecoder().decode(BlueCatbirdCirclePost.self, from: raw) else { return }
    let key = Self.key(uri: uri, cidString: cid.string, record: typed)
    lock.withLock {
      if records.updateValue(raw, forKey: key) == nil {
        order.append(key)
        if order.count > capacity {
          let evicted = order.removeFirst()
          records[evicted] = nil
        }
      }
    }
  }

  func removeAll() {
    lock.withLock {
      records.removeAll()
      order.removeAll()
    }
  }

  // MARK: Response slicing

  /// Registers the record of every `encryptedPostView` in a `getFeed` body.
  func register(feedResponse body: Data) {
    guard let feed = RawJSON.member("feed", in: body), let items = RawJSON.elements(in: feed) else { return }
    for item in items {
      if let post = RawJSON.member("post", in: item) { registerPostView(post) }
    }
  }

  /// Registers every encrypted node of a `getPostThread` body (the anchor,
  /// its parents and all replies).
  func register(threadResponse body: Data) {
    guard let thread = RawJSON.member("thread", in: body) else { return }
    registerThreadNode(thread, depth: 0)
  }

  /// Thread nodes nest (`parent`, `replies[]`); the AppView bounds depth, and
  /// so does this walk.
  private func registerThreadNode(_ node: Data, depth: Int) {
    guard depth < 256 else { return }
    if let post = RawJSON.member("post", in: node) { registerPostView(post) }
    if let parent = RawJSON.member("parent", in: node), parent.first == UInt8(ascii: "{") {
      registerThreadNode(parent, depth: depth + 1)
    }
    if let replies = RawJSON.member("replies", in: node), let children = RawJSON.elements(in: replies) {
      for child in children where child.first == UInt8(ascii: "{") {
        registerThreadNode(child, depth: depth + 1)
      }
    }
  }

  /// A post view (`encryptedPostView` or a thread `postView`): registers its
  /// `record` when that record is a `blue.catbird.circle.post`.
  private func registerPostView(_ view: Data) {
    guard let record = RawJSON.member("record", in: view),
          let type = RawJSON.member("$type", in: record).flatMap({ try? JSONDecoder().decode(String.self, from: $0) }),
          type == CirclePostSealer.postCollection,
          let uriText = RawJSON.member("uri", in: view).flatMap({ try? JSONDecoder().decode(String.self, from: $0) }),
          let cidText = RawJSON.member("cid", in: view).flatMap({ try? JSONDecoder().decode(String.self, from: $0) }),
          let uri = try? ATProtocolURI(uriString: uriText),
          let cid = try? CIDString(cidString: cidText)
    else { return }
    register(raw: record, uri: uri, cid: cid)
  }

  private static func key(uri: ATProtocolURI, cidString: String, record: BlueCatbirdCirclePost) -> String {
    var hasher = SHA256()
    hasher.update(data: record.ciphertext.data)
    hasher.update(data: Data([0]))
    hasher.update(data: record.sig.data)
    hasher.update(data: record.authorEpochHead.data)
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return "\(uri.uriString())|\(cidString)|\(record.keyVersion)|\(record.circleId.description)|\(digest)"
  }
}
