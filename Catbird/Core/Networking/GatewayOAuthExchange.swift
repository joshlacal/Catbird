import Foundation
import Security

enum GatewayOAuthExchangeError: Error, Equatable {
  case configuration
  case flowInProgress
  case unauthorized
}

/// Owns the in-memory proof that binds a native browser login to its callback.
/// A pending nonce is removed before callback validation or network I/O so every
/// callback attempt is single-use locally, including malformed attempts.
actor GatewayOAuthExchange {
  typealias Sender = @Sendable (URLRequest) async throws -> (Data, URLResponse)
  typealias DeadlineWaiter = @Sendable () async throws -> Void

  static let maximumResponseBytes = 8 * 1024

  private let gatewayURL: URL
  private let callbackURL: URL
  private let callbackOrigin: String
  private let uptime: @Sendable () -> TimeInterval
  private let send: Sender
  private let waitForDeadline: DeadlineWaiter
  private var pending: PendingLogin?
  private var flowGeneration: UInt64 = 0

  init(gatewayURL: URL, callbackURL: URL) {
    let transport = GatewayOAuthExchangeTransport(maximumBytes: Self.maximumResponseBytes)
    self.gatewayURL = gatewayURL
    self.callbackURL = callbackURL
    self.callbackOrigin = Self.origin(of: callbackURL) ?? ""
    self.uptime = { ProcessInfo.processInfo.systemUptime }
    self.send = { request in try await transport.send(request) }
    self.waitForDeadline = {
      try await Task.sleep(for: .seconds(15))
    }
  }

  init(
    gatewayURL: URL,
    callbackURL: URL,
    uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    send: @escaping Sender,
    waitForDeadline: @escaping DeadlineWaiter = {
      try await Task.sleep(for: .seconds(15))
    }
  ) {
    self.gatewayURL = gatewayURL
    self.callbackURL = callbackURL
    self.callbackOrigin = Self.origin(of: callbackURL) ?? ""
    self.uptime = uptime
    self.send = send
    self.waitForDeadline = waitForDeadline
  }

  func prepareLogin(_ loginURL: URL) throws -> URL {
    if let pending, uptime() - pending.createdAt <= 60 {
      throw GatewayOAuthExchangeError.flowInProgress
    }
    pending = nil

    guard Self.isHTTPSOrigin(gatewayURL),
      Self.isHTTPSOrigin(callbackURL),
      callbackURL.user == nil,
      callbackURL.password == nil,
      callbackURL.query == nil,
      callbackURL.fragment == nil,
      !callbackOrigin.isEmpty,
      Self.origin(of: loginURL) == Self.origin(of: gatewayURL),
      var components = URLComponents(url: loginURL, resolvingAgainstBaseURL: false)
    else {
      pending = nil
      throw GatewayOAuthExchangeError.configuration
    }

    let nonce = try Self.randomNonce()
    var queryItems = (components.queryItems ?? []).filter {
      $0.name != "browser_nonce" && $0.name != "redirect_to"
    }
    queryItems.append(URLQueryItem(name: "browser_nonce", value: nonce))
    queryItems.append(URLQueryItem(name: "redirect_to", value: callbackURL.absoluteString))
    components.queryItems = queryItems

    guard let boundURL = components.url else {
      pending = nil
      throw GatewayOAuthExchangeError.configuration
    }
    flowGeneration &+= 1
    pending = PendingLogin(
      nonce: nonce,
      createdAt: uptime(),
      generation: flowGeneration
    )
    return boundURL
  }

  func redeem(_ callback: URL) async throws -> String {
    guard let pending else {
      throw GatewayOAuthExchangeError.unauthorized
    }
    self.pending = nil

    guard uptime() - pending.createdAt <= 60 else {
      throw GatewayOAuthExchangeError.unauthorized
    }

    guard let code = Self.validatedCode(from: callback, expected: callbackURL) else {
      throw GatewayOAuthExchangeError.unauthorized
    }

    var request = URLRequest(url: gatewayURL.appendingPathComponent("auth/exchange"))
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(callbackOrigin, forHTTPHeaderField: "Origin")
    request.httpBody = try? JSONEncoder().encode(
      ExchangeRequest(code: code, browserNonce: pending.nonce))

    guard request.httpBody != nil else {
      throw GatewayOAuthExchangeError.unauthorized
    }

    do {
      let (data, response) = try await sendWithAbsoluteDeadline(request)
      guard pending.generation == flowGeneration else {
        throw GatewayOAuthExchangeError.unauthorized
      }
      guard let http = response as? HTTPURLResponse,
        (200..<300).contains(http.statusCode),
        data.count <= Self.maximumResponseBytes,
        http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
          .hasPrefix("application/json") == true,
        let payload = try? JSONDecoder().decode(ExchangeResponse.self, from: data),
        Self.isValidSessionID(payload.sessionID)
      else {
        throw GatewayOAuthExchangeError.unauthorized
      }
      return payload.sessionID
    } catch is GatewayOAuthExchangeError {
      throw GatewayOAuthExchangeError.unauthorized
    } catch {
      throw GatewayOAuthExchangeError.unauthorized
    }
  }

  func cancelPendingLogin() {
    flowGeneration &+= 1
    pending = nil
  }

  private func sendWithAbsoluteDeadline(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let race = GatewayOAuthExchangeRace()
    let sender = send
    let deadline = waitForDeadline

    let sendTask = Task.detached {
      do {
        let (data, response) = try await sender(request)
        race.resolve(.response(GatewayOAuthExchangeResponse(data: data, response: response)))
      } catch {
        race.resolve(.failed)
      }
    }
    let deadlineTask = Task.detached {
      do {
        try await deadline()
        race.resolve(.deadline)
      } catch {
        if !Task.isCancelled {
          race.resolve(.failed)
        }
      }
    }

    let outcome = await withTaskCancellationHandler {
      await race.wait()
    } onCancel: {
      sendTask.cancel()
      deadlineTask.cancel()
      race.resolve(.cancelled)
    }

    sendTask.cancel()
    deadlineTask.cancel()

    guard case .response(let response) = outcome else {
      throw GatewayOAuthExchangeError.unauthorized
    }
    return (response.data, response.response)
  }

  private static func randomNonce() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw GatewayOAuthExchangeError.configuration
    }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func validatedCode(from callback: URL, expected: URL) -> String? {
    guard callback.scheme?.lowercased() == expected.scheme?.lowercased(),
      callback.host?.lowercased() == expected.host?.lowercased(),
      effectivePort(of: callback) == effectivePort(of: expected),
      callback.path == expected.path,
      callback.user == nil,
      callback.password == nil,
      callback.fragment == nil,
      let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
      let queryItems = components.queryItems,
      queryItems.count == 1,
      queryItems[0].name == "code",
      let code = queryItems[0].value,
      code.count == 43,
      code.utf8.allSatisfy({ byte in
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
          || byte == 45 || byte == 95
      })
    else {
      return nil
    }
    return code
  }

  private static func effectivePort(of url: URL) -> Int? {
    if let port = url.port { return port }
    return url.scheme?.lowercased() == "https" ? 443 : nil
  }

  private static func isValidSessionID(_ sessionID: String) -> Bool {
    guard let uuid = UUID(uuidString: sessionID) else { return false }
    return uuid.uuidString.lowercased() == sessionID
  }

  private static func isHTTPSOrigin(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
  }

  private static func origin(of url: URL) -> String? {
    guard isHTTPSOrigin(url), let host = url.host?.lowercased() else { return nil }
    if let port = url.port, port != 443 {
      return "https://\(host):\(port)"
    }
    return "https://\(host)"
  }

  private struct PendingLogin {
    let nonce: String
    let createdAt: TimeInterval
    let generation: UInt64
  }
}

private struct GatewayOAuthExchangeResponse: @unchecked Sendable {
  let data: Data
  let response: URLResponse
}

private final class GatewayOAuthExchangeRace: @unchecked Sendable {
  enum Outcome: @unchecked Sendable {
    case response(GatewayOAuthExchangeResponse)
    case deadline
    case failed
    case cancelled
  }

  private let lock = NSLock()
  private var outcome: Outcome?
  private var continuation: CheckedContinuation<Outcome, Never>?

  func resolve(_ outcome: Outcome) {
    var continuationToResume: CheckedContinuation<Outcome, Never>?
    lock.withLock {
      guard self.outcome == nil else { return }
      self.outcome = outcome
      continuationToResume = continuation
      continuation = nil
    }
    continuationToResume?.resume(returning: outcome)
  }

  func wait() async -> Outcome {
    await withCheckedContinuation { continuation in
      var immediate: Outcome?
      lock.withLock {
        if let outcome {
          immediate = outcome
        } else {
          precondition(self.continuation == nil)
          self.continuation = continuation
        }
      }
      if let immediate {
        continuation.resume(returning: immediate)
      }
    }
  }
}

final class GatewayOAuthExchangeTransport: @unchecked Sendable {
  static let redirectTarget: URLRequest? = nil

  private let delegate: GatewayOAuthExchangeSessionDelegate
  private let session: URLSession
  var hasInitializedSession: Bool { true }

  init(maximumBytes: Int, protocolClasses: [AnyClass]? = nil) {
    let delegate = GatewayOAuthExchangeSessionDelegate(maximumBytes: maximumBytes)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    if let protocolClasses {
      configuration.protocolClasses = protocolClasses
    }
    self.delegate = delegate
    self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
  }

  func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let cancellation = GatewayOAuthExchangeTaskCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let task = session.dataTask(with: request)
        delegate.register(task: task, continuation: continuation)
        guard cancellation.installAndResume(task) else {
          delegate.cancel(task: task)
          return
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  static func responseDisposition(hasPendingRequest: Bool) -> URLSession.ResponseDisposition {
    hasPendingRequest ? .allow : .cancel
  }

  static func append(_ chunk: Data, to data: inout Data, maximumBytes: Int) throws {
    guard data.count <= maximumBytes, chunk.count <= maximumBytes - data.count else {
      throw GatewayOAuthExchangeError.unauthorized
    }
    data.append(chunk)
  }
}

private final class GatewayOAuthExchangeSessionDelegate: NSObject, URLSessionDataDelegate,
  @unchecked Sendable
{
  private struct PendingRequest {
    let continuation: CheckedContinuation<(Data, URLResponse), Error>
    var data = Data()
    var response: URLResponse?
  }

  private let maximumBytes: Int
  private let lock = NSLock()
  private var requests: [Int: PendingRequest] = [:]

  init(maximumBytes: Int) {
    self.maximumBytes = maximumBytes
  }

  func register(
    task: URLSessionTask,
    continuation: CheckedContinuation<(Data, URLResponse), Error>
  ) {
    lock.withLock {
      requests[task.taskIdentifier] = PendingRequest(continuation: continuation)
    }
  }

  func cancel(task: URLSessionTask) {
    let pending = lock.withLock { requests.removeValue(forKey: task.taskIdentifier) }
    task.cancel()
    pending?.continuation.resume(throwing: CancellationError())
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(GatewayOAuthExchangeTransport.redirectTarget)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    var rejected: PendingRequest?
    let hasPendingRequest = lock.withLock {
      guard var pending = requests[dataTask.taskIdentifier] else { return false }
      if response.expectedContentLength > maximumBytes {
        rejected = requests.removeValue(forKey: dataTask.taskIdentifier)
      } else {
        pending.response = response
        requests[dataTask.taskIdentifier] = pending
      }
      return true
    }
    if let rejected {
      rejected.continuation.resume(throwing: GatewayOAuthExchangeError.unauthorized)
      completionHandler(.cancel)
    } else {
      completionHandler(
        GatewayOAuthExchangeTransport.responseDisposition(
          hasPendingRequest: hasPendingRequest))
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    var rejected: PendingRequest?
    lock.withLock {
      guard var pending = requests[dataTask.taskIdentifier] else { return }
      do {
        try GatewayOAuthExchangeTransport.append(
          data, to: &pending.data, maximumBytes: maximumBytes)
        requests[dataTask.taskIdentifier] = pending
      } catch {
        rejected = requests.removeValue(forKey: dataTask.taskIdentifier)
      }
    }
    if let rejected {
      dataTask.cancel()
      rejected.continuation.resume(throwing: GatewayOAuthExchangeError.unauthorized)
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    let pending = lock.withLock { requests.removeValue(forKey: task.taskIdentifier) }
    guard let pending else { return }
    if let error {
      pending.continuation.resume(throwing: error)
    } else if let response = pending.response {
      pending.continuation.resume(returning: (pending.data, response))
    } else {
      pending.continuation.resume(throwing: GatewayOAuthExchangeError.unauthorized)
    }
  }
}

private final class GatewayOAuthExchangeTaskCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var isCancelled = false
  private var task: URLSessionTask?

  func installAndResume(_ task: URLSessionTask) -> Bool {
    lock.withLock {
      guard !isCancelled else { return false }
      self.task = task
      task.resume()
      return true
    }
  }

  func cancel() {
    let taskToCancel = lock.withLock {
      isCancelled = true
      let task = task
      self.task = nil
      return task
    }
    taskToCancel?.cancel()
  }
}

private struct ExchangeRequest: Encodable {
  let code: String
  let browserNonce: String

  enum CodingKeys: String, CodingKey {
    case code
    case browserNonce = "browser_nonce"
  }
}

private struct ExchangeResponse: Decodable {
  let sessionID: String

  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
  }
}
