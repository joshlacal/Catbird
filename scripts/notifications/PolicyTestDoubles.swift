import Foundation

// These DTOs model only the field shapes touched by the extracted production
// policy/grouping code. Parsing and Petrel wire compatibility are outside scope.
struct ATProtocolURI: Hashable, Sendable {
  let rawValue: String
  init(uriString: String) throws { rawValue = uriString }
  func uriString() -> String { rawValue }
  var collection: String { rawValue.split(separator: "/").dropFirst(2).first.map(String.init) ?? "" }
}

struct Handle: Equatable, Sendable {
  let rawValue: String
  init(handleString: String) throws { rawValue = handleString }
}

struct CID: Hashable, Sendable, CustomStringConvertible {
  let rawValue: String
  static func parse(_ value: String) throws -> CID { CID(rawValue: value) }
  var description: String { rawValue }
}

struct ATProtocolDate: Hashable, Sendable {
  let date: Date
}

enum FakeRecord {
  case object([String: String])
  case knownType(Any)
}

enum AppBskyActorDefs {
  struct ViewerState {
    var following: ATProtocolURI?
    var followedBy: ATProtocolURI?
    init(following: ATProtocolURI? = nil, followedBy: ATProtocolURI? = nil) {
      self.following = following
      self.followedBy = followedBy
    }
  }
  struct ProfileView {
    var did: DID
    var handle: Handle
    var displayName: String?
    var viewer: ViewerState?
    init(did: DID, handle: Handle, displayName: String? = nil, viewer: ViewerState? = nil) {
      self.did = did
      self.handle = handle
      self.displayName = displayName
      self.viewer = viewer
    }
  }
  struct ProfileViewBasic {
    var did: DID
    var handle: Handle
  }
}

enum AppBskyFeedDefs {
  struct PostView {
    var uri: ATProtocolURI
    var cid: CID
    var author: AppBskyActorDefs.ProfileViewBasic
    var record: FakeRecord
    var indexedAt: ATProtocolDate
  }
}

struct FakeStrongRef { var uri: ATProtocolURI }
struct AppBskyFeedLike { var subject: FakeStrongRef }
struct AppBskyFeedRepost { var subject: FakeStrongRef }
struct AppBskyFeedPost {
  struct Reply { var parent: FakeStrongRef }
  var reply: Reply?
}
struct AppBskyGraphFollow { var createdAt: ATProtocolDate }

enum AppBskyNotificationListNotifications {
  struct Notification {
    var uri: ATProtocolURI
    var cid: CID
    var author: AppBskyActorDefs.ProfileView
    var reason: String
    var reasonSubject: ATProtocolURI?
    var record: FakeRecord
    var isRead: Bool
    var indexedAt: ATProtocolDate
  }
  struct Parameters {
    var reasons: [String]?
    var limit: Int?
    var cursor: String?
  }
  struct Output {
    var cursor: String?
    var notifications: [Notification]
  }
}
typealias ListReply = (Int, AppBskyNotificationListNotifications.Output?)

enum Color { case red, green, blue, cyan, purple, orange, indigo, secondary, pink }
enum LogPrivacy { case `public` }
struct HarnessLogMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
  init(stringLiteral value: String) {}
  init(stringInterpolation: StringInterpolation) {}
  struct StringInterpolation: StringInterpolationProtocol {
    init(literalCapacity: Int, interpolationCount: Int) {}
    mutating func appendLiteral(_ literal: String) {}
    mutating func appendInterpolation<T>(_ value: T) {}
    mutating func appendInterpolation<T>(_ value: T, privacy: LogPrivacy) {}
  }
}

extension Error {
  var isCancellation: Bool { self is CancellationError }
}

final class ObservationCounter {
  private let lock = NSLock()
  private var count = 0
  func increment() {
    lock.lock()
    defer { lock.unlock() }
    count += 1
  }
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}
