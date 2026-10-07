import Foundation
import Petrel

protocol VideoMultipartTransporting: Sendable {
  func start(input: AppBskyVideoStartUpload.Input) async throws -> AppBskyVideoStartUpload.Output
  func uploadPart(
    jobID: String, partNumber: Int, fileURL: URL, byteCount: Int,
    onProgress: (@Sendable (Int64) -> Void)?
  ) async throws -> AppBskyVideoUploadPart.Output
  func status(jobID: String) async throws -> AppBskyVideoGetUploadStatus.Output
  func finish(jobID: String) async throws -> AppBskyVideoFinishUpload.Output
  func abort(jobID: String) async throws -> AppBskyVideoAbortUpload.Output
  func jobStatus(jobID: String) async throws -> AppBskyVideoDefs.JobStatus
}

/// Proof that startUpload stopped before any video-service HTTP request was issued.
/// Preserve the original permission/cancellation error without inventing an uncertain reservation.
struct VideoMultipartStartNotSent: Error, LocalizedError {
  let underlying: Error
  var errorDescription: String? { underlying.localizedDescription }
}

/// Preserves XRPC codes (including unknown future codes) without triggering account-auth recovery.
struct VideoMultipartTransportError: Error, LocalizedError, Sendable {
  let statusCode: Int?
  let code: String?
  let message: String?
  let retryAfterSeconds: TimeInterval?
  let isRetryable: Bool

  init(
    statusCode: Int? = nil, code: String? = nil, message: String? = nil,
    retryAfterSeconds: TimeInterval? = nil, retryable: Bool = false
  ) {
    self.statusCode = statusCode
    self.code = code
    self.message = message
    self.retryAfterSeconds = retryAfterSeconds
    self.isRetryable = retryable
  }

  var isAuthenticationFailure: Bool {
    statusCode == 401 || ["AuthRequired", "ExpiredToken", "InvalidToken"].contains(code ?? "")
  }

  /// Only a definite unsupported-method response can justify offering the old upload path.
  var isUnsupportedEndpoint: Bool {
    [404, 405, 501].contains(statusCode ?? 0) || ["MethodNotFound", "UnsupportedMethod"].contains(code ?? "")
  }

  var errorDescription: String? { message ?? code ?? "Video service request failed." }

  static func isTransient(_ error: Error) -> Bool {
    if let error = error as? Self { return error.isRetryable }
    guard let error = error as? URLError else { return false }
    return [
      .timedOut, .networkConnectionLost, .notConnectedToInternet,
      .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed
    ].contains(error.code)
  }
}

protocol VideoMultipartHTTPClient: Sendable {
  func perform(
    _ request: URLRequest, fileURL: URL?, onProgress: (@Sendable (Int64) -> Void)?
  ) async throws -> (Data, HTTPURLResponse)
}

/// Direct video origin, service JWTs only. Generic SDK retries must never replay startUpload.
struct VideoMultipartTransport: VideoMultipartTransporting {
  private let tokens: VideoServiceTokenProvider
  private let httpClient: any VideoMultipartHTTPClient

  init(tokens: VideoServiceTokenProvider, httpClient: any VideoMultipartHTTPClient = URLSessionVideoHTTPClient()) {
    self.tokens = tokens
    self.httpClient = httpClient
  }

  func start(input: AppBskyVideoStartUpload.Input) async throws -> AppBskyVideoStartUpload.Output {
    try await send(
      endpoint: "startUpload", body: JSONEncoder().encode(input),
      refreshAfterUnauthorized: false
    )
  }

  func uploadPart(
    jobID: String, partNumber: Int, fileURL: URL, byteCount: Int,
    onProgress: (@Sendable (Int64) -> Void)? = nil
  ) async throws -> AppBskyVideoUploadPart.Output {
    guard partNumber > 0, byteCount > 0, fileURL.isFileURL else {
      throw VideoMultipartTransportError(code: "InvalidPart", message: "The prepared video part is invalid.")
    }
    let parameters = AppBskyVideoUploadPart.Parameters(jobId: jobID, partNumber: partNumber)
    let result: AppBskyVideoUploadPart.Output = try await send(
      endpoint: "uploadPart", query: [
        URLQueryItem(name: "jobId", value: parameters.jobId),
        URLQueryItem(name: "partNumber", value: String(parameters.partNumber))
      ], fileURL: fileURL, byteCount: byteCount, timeout: 120, onProgress: onProgress
    )
    guard result.partNumber == partNumber, result.sizeBytes == byteCount else {
      throw VideoMultipartTransportError(code: "InvalidPartReceipt", message: "The video service returned an inconsistent part receipt.")
    }
    return result
  }

  func status(jobID: String) async throws -> AppBskyVideoGetUploadStatus.Output {
    let parameters = AppBskyVideoGetUploadStatus.Parameters(jobId: jobID)
    return try await send(endpoint: "getUploadStatus", method: "GET", query: [URLQueryItem(name: "jobId", value: parameters.jobId)])
  }

  func finish(jobID: String) async throws -> AppBskyVideoFinishUpload.Output {
    try await send(
      endpoint: "finishUpload", body: JSONEncoder().encode(AppBskyVideoFinishUpload.Input(jobId: jobID)),
      forceFreshToken: true
    )
  }

  func abort(jobID: String) async throws -> AppBskyVideoAbortUpload.Output {
    try await send(
      endpoint: "abortUpload", body: JSONEncoder().encode(AppBskyVideoAbortUpload.Input(jobId: jobID)), timeout: 10
    )
  }

  func jobStatus(jobID: String) async throws -> AppBskyVideoDefs.JobStatus {
    let parameters = AppBskyVideoGetJobStatus.Parameters(jobId: jobID)
    let result: VideoUploadResponse<AppBskyVideoDefs.JobStatus> = try await send(
      endpoint: "getJobStatus", method: "GET", query: [URLQueryItem(name: "jobId", value: parameters.jobId)], authenticated: false
    )
    return result.jobStatus
  }

  private func send<Output: Decodable>(
    endpoint: String, method: String = "POST", query: [URLQueryItem] = [], body: Data? = nil,
    fileURL: URL? = nil, byteCount: Int? = nil, timeout: TimeInterval = 30,
    authenticated: Bool = true, forceFreshToken: Bool = false,
    refreshAfterUnauthorized: Bool = true, onProgress: (@Sendable (Int64) -> Void)? = nil
  ) async throws -> Output {
    var url = URLComponents()
    url.scheme = "https"
    url.host = "video.bsky.app"
    url.path = "/xrpc/app.bsky.video.\(endpoint)"
    url.queryItems = query.isEmpty ? nil : query
    guard let requestURL = url.url else {
      throw VideoMultipartTransportError(code: "InvalidURL", message: "Could not form the video service request.")
    }
    var request = URLRequest(url: requestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    request.httpMethod = method
    request.httpBody = body
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if fileURL != nil {
      request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
      request.setValue(String(byteCount ?? 0), forHTTPHeaderField: "Content-Length")
    } else if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
    }
    var token: String?
    do {
      try Task.checkCancellation()
      token = authenticated ? try await tokens.token(forceRefresh: forceFreshToken) : nil
    } catch {
      if endpoint == "startUpload" { throw VideoMultipartStartNotSent(underlying: error) }
      throw error
    }
    for attempt in 0...1 {
      do { try Task.checkCancellation() }
      catch {
        if endpoint == "startUpload" { throw VideoMultipartStartNotSent(underlying: error) }
        throw error
      }
      request.setValue(token.map { "Bearer \($0)" }, forHTTPHeaderField: "Authorization")
      let (data, response) = try await httpClient.perform(request, fileURL: fileURL, onProgress: onProgress)
      try Task.checkCancellation()
      guard (200..<300).contains(response.statusCode) else {
        let error = Self.serverError(data: data, response: response)
        if attempt == 0, authenticated, refreshAfterUnauthorized, error.isAuthenticationFailure {
          token = try await tokens.token(forceRefresh: true, replacing: token)
          onProgress?(0)
          continue
        }
        throw error
      }
      do { return try JSONDecoder().decode(Output.self, from: data) }
      catch {
        throw VideoMultipartTransportError(
          statusCode: response.statusCode, code: "InvalidResponse",
          message: "The video service returned an unreadable response."
        )
      }
    }
    throw VideoMultipartTransportError(code: "AuthRequired", message: "Video upload authorization was rejected.")
  }

  private static func serverError(data: Data, response: HTTPURLResponse) -> VideoMultipartTransportError {
    let parsed = ATProtoErrorParser.parseGeneric(data: data, statusCode: response.statusCode)
    let code = parsed?.error
    let status = response.statusCode
    let retryable = status == 408 || status == 429 || (500..<600).contains(status) || code == "ServiceOverloaded"
    var retryAfter: TimeInterval?
    if let raw = response.value(forHTTPHeaderField: "Retry-After") {
      if let seconds = Double(raw), seconds.isFinite, seconds >= 0 {
        retryAfter = seconds
      } else {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        if let date = formatter.date(from: raw) { retryAfter = max(0, date.timeIntervalSinceNow) }
      }
    }
    return VideoMultipartTransportError(
      statusCode: status, code: code,
      message: parsed?.message ?? "Video service request failed (\(status)).",
      retryAfterSeconds: retryAfter, retryable: retryable
    )
  }
}

/// One bounded, cancellable URLSession task. Refuses redirects so credentials never leave the origin.
struct URLSessionVideoHTTPClient: VideoMultipartHTTPClient {
  private let configuration: @Sendable () -> URLSessionConfiguration

  init(configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
    self.configuration = configuration
  }

  func perform(
    _ request: URLRequest, fileURL: URL?, onProgress: (@Sendable (Int64) -> Void)?
  ) async throws -> (Data, HTTPURLResponse) {
    let operation = VideoHTTPRequest(onProgress: onProgress)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        operation.start(request: request, fileURL: fileURL, configuration: configuration(), continuation: continuation)
      }
    } onCancel: {
      operation.cancel()
    }
  }
}

private final class VideoHTTPRequest: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private let onProgress: (@Sendable (Int64) -> Void)?
  private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
  private var session: URLSession?
  private var task: URLSessionTask?
  private var response: HTTPURLResponse?
  private var data = Data()
  private var finished = false
  private var canceled = false
  private let maximumResponseBytes = 4 * 1_024 * 1_024

  init(onProgress: (@Sendable (Int64) -> Void)?) { self.onProgress = onProgress }

  func start(
    request: URLRequest, fileURL: URL?, configuration: URLSessionConfiguration,
    continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
  ) {
    lock.lock()
    guard !canceled else {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
      return
    }
    self.continuation = continuation
    let config = configuration
    config.httpShouldSetCookies = false
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    config.urlCache = nil
    config.waitsForConnectivity = false
    config.timeoutIntervalForRequest = request.timeoutInterval
    config.timeoutIntervalForResource = request.timeoutInterval
    let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    self.session = session
    let task: URLSessionTask
    if let fileURL { task = session.uploadTask(with: request, fromFile: fileURL) }
    else { task = session.dataTask(with: request) }
    self.task = task
    lock.unlock()
    task.resume()
  }

  func cancel() {
    lock.lock()
    canceled = true
    lock.unlock()
    complete(.failure(CancellationError()))
  }

  private func complete(_ result: Result<(Data, HTTPURLResponse), Error>) {
    lock.lock()
    guard !finished else { lock.unlock(); return }
    finished = true
    let continuation = continuation
    self.continuation = nil
    let session = session
    self.session = nil
    task = nil
    lock.unlock()
    session?.invalidateAndCancel()
    continuation?.resume(with: result)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    lock.lock()
    self.response = response as? HTTPURLResponse
    let allow = !finished && self.response != nil && response.expectedContentLength <= Int64(maximumResponseBytes)
    lock.unlock()
    completionHandler(allow ? .allow : .cancel)
    if !allow {
      complete(.failure(VideoMultipartTransportError(code: "InvalidResponse", message: "The video service response was invalid or too large.")))
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
    lock.lock()
    guard !finished else { lock.unlock(); return }
    if chunk.count <= maximumResponseBytes - data.count {
      data.append(chunk)
      lock.unlock()
    } else {
      lock.unlock()
      complete(.failure(VideoMultipartTransportError(code: "ResponseTooLarge", message: "The video service response was too large.")))
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64, totalBytesExpectedToSend: Int64
  ) {
    lock.lock()
    let active = !finished
    lock.unlock()
    if active, totalBytesExpectedToSend > 0 {
      onProgress?(min(totalBytesExpectedToSend, max(0, totalBytesSent)))
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let response = response
    let data = data
    lock.unlock()
    if let error { complete(.failure(error)) }
    else if let response { complete(.success((data, response))) }
    else { complete(.failure(VideoMultipartTransportError(code: "InvalidResponse", message: "No response from the video service."))) }
  }
}
