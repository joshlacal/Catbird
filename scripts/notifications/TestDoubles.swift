import Foundation

// In-memory shadows deliberately prevent use of a real app-group defaults store,
// Keychain, account, APNS, widget, MLS, or network service.
final class UserDefaults {
  private let lock = NSLock()
  private var storage: [String: Any] = [:]

  func object(forKey key: String) -> Any? {
    lock.lock()
    defer { lock.unlock() }
    return storage[key]
  }

  func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }

  func set(_ value: Any?, forKey key: String) {
    lock.lock()
    defer { lock.unlock() }
    storage[key] = value
  }
}

final class AppState {
  var userDID: String
  init(userDID: String) { self.userDID = userDID }
}

final class ModelContext {}
protocol UNUserNotificationCenterDelegate {}

struct Logger {
  init(subsystem: String, category: String) {}
  func info(_ message: String) {}
  func debug(_ message: String) {}
  func warning(_ message: String) {}
  func error(_ message: String) {}
}

public struct DID: Codable, Equatable, Sendable {
  public let didString: String
  public init(didString: String) throws { self.didString = didString }
}

public enum AppBskyNotificationDefs {
  public struct ChatPreference: Codable, Equatable, Sendable {
    public var include: String
    public var push: Bool
    public init(include: String, push: Bool) {
      self.include = include
      self.push = push
    }
  }

  public struct FilterablePreference: Codable, Equatable, Sendable {
    public var include: String
    public var list: Bool
    public var push: Bool
    public init(include: String, list: Bool, push: Bool) {
      self.include = include
      self.list = list
      self.push = push
    }
  }

  public struct Preference: Codable, Equatable, Sendable {
    public var list: Bool
    public var push: Bool
    public init(list: Bool, push: Bool) {
      self.list = list
      self.push = push
    }
  }

  public struct Preferences: Codable, Equatable, Sendable {
    public var chat: ChatPreference
    public var follow: FilterablePreference
    public var like: FilterablePreference
    public var likeViaRepost: FilterablePreference
    public var mention: FilterablePreference
    public var quote: FilterablePreference
    public var reply: FilterablePreference
    public var repost: FilterablePreference
    public var repostViaRepost: FilterablePreference
    public var starterpackJoined: Preference
    public var subscribedPost: Preference
    public var unverified: Preference
    public var verified: Preference
  }
}

public enum AppBskyNotificationPutPreferencesV2 {
  public typealias Input = AppBskyNotificationDefs.Preferences
  public struct Output: Sendable {
    public var preferences: AppBskyNotificationDefs.Preferences
  }
}

enum AppBskyNotificationGetPreferences {
  struct Input: Sendable {}
  struct Output: Sendable {
    var preferences: AppBskyNotificationDefs.Preferences
  }
}

enum AppBskyNotificationRegisterPush {
  struct Input: Equatable, Sendable {
    var serviceDid: DID
    var token: String
    var platform: String
    var appId: String
  }
}

enum AppBskyNotificationUnregisterPush {
  typealias Input = AppBskyNotificationRegisterPush.Input
}

enum HarnessError: Error { case injectedFailure, gateNotReached, gateAlreadyResolved }

/// Gates do not automatically honor cancellation: tests must prove the production
/// method rejects a late successful response even when its transport returns one.
@MainActor
final class ResponseGate<Value> {
  private var continuation: CheckedContinuation<Value, Error>?
  private(set) var entered = false

  func response() async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      precondition(self.continuation == nil)
      self.continuation = continuation
      entered = true
    }
  }

  func succeed(_ value: Value) {
    precondition(continuation != nil, "Gate must be entered before completing it")
    let pending = continuation
    continuation = nil
    pending?.resume(returning: value)
  }

  func fail(_ error: Error = HarnessError.injectedFailure) {
    precondition(continuation != nil, "Gate must be entered before failing it")
    let pending = continuation
    continuation = nil
    pending?.resume(throwing: error)
  }

  func waitForEntry() async throws {
    try await eventually { self.entered }
  }
}

/// Deadlines only bound broken tests. Assertions synchronize on observable fake
/// dispatch or explicit gate entry, never on an assumed scheduler delay.
@MainActor
func eventually(_ predicate: () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(5)
  while !predicate() {
    if ContinuousClock.now >= deadline { throw HarnessError.gateNotReached }
    try await Task.sleep(for: .milliseconds(1))
  }
}

typealias GetReply = (Int, AppBskyNotificationGetPreferences.Output?)
typealias PutReply = (Int, AppBskyNotificationPutPreferencesV2.Output?)

@MainActor
final class FakeNotificationAPI {
  var getHandler: (() async throws -> GetReply)?
  var putHandler: ((AppBskyNotificationPutPreferencesV2.Input) async throws -> PutReply)?
  var registerHandler: (() async throws -> Int)?
  var defaultPreferences = NotificationPreferences().toServerPreferences()
  private(set) var getCount = 0
  private(set) var putInputs: [AppBskyNotificationPutPreferencesV2.Input] = []
  private(set) var registerInputs: [AppBskyNotificationRegisterPush.Input] = []
  private(set) var unregisterInputs: [AppBskyNotificationUnregisterPush.Input] = []

  func getPreferences(input: AppBskyNotificationGetPreferences.Input) async throws -> GetReply {
    getCount += 1
    if let getHandler { return try await getHandler() }
    return (200, .init(preferences: defaultPreferences))
  }

  func putPreferencesV2(input: AppBskyNotificationPutPreferencesV2.Input) async throws -> PutReply {
    putInputs.append(input)
    if let putHandler { return try await putHandler(input) }
    defaultPreferences = input
    return (200, .init(preferences: input))
  }

  func registerPush(input: AppBskyNotificationRegisterPush.Input) async throws -> Int {
    registerInputs.append(input)
    if let registerHandler { return try await registerHandler() }
    return 200
  }

  func unregisterPush(input: AppBskyNotificationUnregisterPush.Input) async throws -> Int {
    unregisterInputs.append(input)
    return 200
  }
}

final class ATProtoClient {
  struct App { let bsky: Bsky }
  struct Bsky { let notification: FakeNotificationAPI }
  let app: App
  let did: String
  @MainActor var getDidHandler: (() async throws -> String)?
  @MainActor var routingHandler: (() async -> Void)?

  @MainActor
  init(did: String, api: FakeNotificationAPI) {
    self.did = did
    app = App(bsky: Bsky(notification: api))
  }

  @MainActor
  func getDid() async throws -> String {
    if let getDidHandler { return try await getDidHandler() }
    return did
  }

  @MainActor
  func setServiceDID(_ did: String, for endpoint: String) async {
    if let routingHandler { await routingHandler() }
  }
}
