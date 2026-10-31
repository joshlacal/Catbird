import Foundation
import Petrel
#if !MULTIPART_HARNESS
import Testing
@testable import Catbird
#endif

// The direct swiftc harness invokes these same checks without Swift Testing macros.
enum VideoMultipartTransportChecks {
  static let statusJSON = #"{"jobId":"processing","did":"did:plc:alice","state":"JOB_STATE_PROCESSING","progress":20}"#

  static func bothResponseFormats() throws {
    let decoder = JSONDecoder()
    for json in [statusJSON, "{\"jobStatus\":\(statusJSON)}"] {
      let result = try decoder.decode(VideoUploadResponse<AppBskyVideoDefs.JobStatus>.self, from: Data(json.utf8))
      try verify(result.jobStatus.jobId == "processing", "bare/wrapped status decodes the processing identity")
      try verify(result.jobStatus.progress == 20, "generated progress decoder retained")
    }
    do {
      _ = try decoder.decode(VideoUploadResponse<AppBskyVideoDefs.JobStatus>.self,
                             from: Data("{\"jobStatus\":null,\"jobId\":\"misleading\"}".utf8))
      throw CheckFailure("Malformed explicit wrapper must fail")
    } catch is DecodingError {}
    let blob = Blob(type: "blob", mimeType: "video/mp4", size: 10, cid: "retained")
    switch VideoProcessingOutcome.resolve(state: "JOB_STATE_FAILED", progress: nil, blob: blob,
                                         error: "already_exists", message: nil) {
    case .complete(let value): try verify(value == blob, "legacy already_exists reuses returned blob")
    default: throw CheckFailure("Returned blob must win over reused failed state")
    }
  }

  @MainActor
  static func startRequestContract() async throws {
    let http = ScriptedVideoHTTP([.json(200, #"{"jobId":"upload","partSizeBytes":4,"partCount":3,"expiresAt":"2099-01-01T00:00:00.000Z"}"#)])
    let mint = TokenMintRecorder()
    let tokens = VideoServiceTokenProvider(now: { Date(timeIntervalSince1970: 1000) },
                                          isOwner: { true }, mint: { expiry in mint.mint(expiry) })
    let transport = VideoMultipartTransport(tokens: tokens, httpClient: http)
    let output = try await transport.start(input: .init(sizeBytes: 10, mimeType: "video/mp4", name: "clip.mp4", durationMs: 100))
    try verify(output.jobId == "upload", "start response decodes pinned model")
    let requests = await http.requests
    try verify(requests.count == 1, "start performed once")
    let request = requests[0].request
    try verify(request.url?.host == "video.bsky.app", "direct video origin")
    try verify(request.url?.path == "/xrpc/app.bsky.video.startUpload", "start endpoint")
    try verify(request.httpMethod == "POST", "start POST")
    try verify(request.url?.query == nil, "multipart start does not send DID query")
    try verify(request.value(forHTTPHeaderField: "Authorization") == "Bearer service-1", "only service JWT sent")
    try verify(request.value(forHTTPHeaderField: "atproto-proxy") == nil, "PDS proxy header absent")
    let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
    try verify(body?["sizeBytes"] as? Int == 10 && body?["mimeType"] as? String == "video/mp4", "exact JSON size and MIME")
    try verify(body?["did"] == nil, "DID absent from start body")
    try verify(mint.expiries == [2800], "service token requests 30 minute integer expiry")
  }

  @MainActor
  static func rawPartContractAndAuthenticationRetry() async throws {
    let http = ScriptedVideoHTTP([
      .json(401, #"{"error":"AuthRequired","message":"expired"}"#),
      .json(200, #"{"partNumber":3,"sizeBytes":2}"#),
    ])
    let mint = TokenMintRecorder()
    let transport = VideoMultipartTransport(tokens: VideoServiceTokenProvider(isOwner: { true }, mint: { expiry in mint.mint(expiry) }), httpClient: http)
    let file = try fixtureFile(Data([8, 9]))
    let receipt = try await transport.uploadPart(jobID: "upload +/", partNumber: 3, fileURL: file,
                                                 byteCount: 2, onProgress: nil)
    try verify(receipt.partNumber == 3 && receipt.sizeBytes == 2, "part receipt retained")
    let requests = await http.requests
    try verify(requests.count == 2, "part gets one auth refresh retry")
    for recorded in requests {
      let request = recorded.request
      try verify(request.httpMethod == "POST", "part POST")
      try verify(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream", "raw part media type")
      try verify(request.value(forHTTPHeaderField: "Content-Length") == "2", "short final part exact byte count")
      try verify(recorded.fileBytes == Data([8, 9]), "part retry uses same raw file bytes")
      try verify(request.httpBody == nil, "part does not JSON/base64 encode file")
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      try verify(query.first { $0.name == "jobId" }?.value == "upload +/", "job ID escaped without corruption")
      try verify(query.first { $0.name == "partNumber" }?.value == "3", "one-based part number")
    }
    try verify(requests[0].request.value(forHTTPHeaderField: "Authorization") == "Bearer service-1", "first token")
    try verify(requests[1].request.value(forHTTPHeaderField: "Authorization") == "Bearer service-2", "refreshed service token")
    try verify(FileManager.default.fileExists(atPath: file.path), "transport preserves source")
  }

  @MainActor
  static func publicJobStatusAndOneShotStart() async throws {
    for response in [statusJSON, "{\"jobStatus\":\(statusJSON)}"] {
      let http = ScriptedVideoHTTP([.json(200, response)])
      let mint = TokenMintRecorder()
      let transport = VideoMultipartTransport(tokens: VideoServiceTokenProvider(isOwner: { true }, mint: { expiry in mint.mint(expiry) }), httpClient: http)
      let status = try await transport.jobStatus(jobID: "canonical")
      try verify(status.jobId == "processing", "public poll normalizes both formats")
      let request = await http.requests[0].request
      try verify(request.httpMethod == "GET", "public poll GET")
      try verify(request.value(forHTTPHeaderField: "Authorization") == nil, "public polling carries no credential")
      try verify(mint.expiries.isEmpty, "public polling never mints auth")
    }
    let http = ScriptedVideoHTTP([.failure(URLError(.timedOut))])
    let transport = VideoMultipartTransport(tokens: VideoServiceTokenProvider(isOwner: { true }, mint: { _ in "service" }), httpClient: http)
    do {
      _ = try await transport.start(input: .init(sizeBytes: 10, mimeType: "video/mp4"))
      throw CheckFailure("Lost start must throw")
    } catch is URLError {}
    try verify(await http.requests.count == 1, "lost non-idempotent start is never replayed")
  }

  @MainActor
  static func tokenCoalescingAndOwnership() async throws {
    let mint = TokenMintRecorder()
    let tokens = VideoServiceTokenProvider(isOwner: { true }, mint: { expiry in
      await Task.yield()
      return mint.mint(expiry)
    })
    async let first = tokens.token()
    async let second = tokens.token()
    let values = try await [first, second]
    try verify(values == ["service-1", "service-1"], "concurrent token requests coalesce")
    try verify(mint.expiries.count == 1, "one mint for concurrent users")
    async let refreshedFirst = tokens.token(forceRefresh: true, replacing: "service-1")
    async let refreshedSecond = tokens.token(forceRefresh: true, replacing: "service-1")
    let refreshed = try await [refreshedFirst, refreshedSecond]
    try verify(refreshed == ["service-2", "service-2"], "simultaneous 401 refreshes coalesce")
    let deniedMint = TokenMintRecorder()
    let denied = VideoServiceTokenProvider(isOwner: { false }, mint: { expiry in deniedMint.mint(expiry) })
    do {
      _ = try await denied.token()
      throw CheckFailure("Changed owner must reject token")
    } catch is CancellationError {}
    try verify(deniedMint.expiries.isEmpty, "account ownership checked before mint")
  }

  @MainActor
  static func boundedUncooperativeMintAndCancellation() async throws {
    let timeoutGate = VideoTestGate()
    let tokens = VideoServiceTokenProvider(refreshTimeout: 0.01, isOwner: { true }, mint: { _ in
      await timeoutGate.wait()
      return "late-service-token"
    })
    do {
      _ = try await tokens.token()
      throw CheckFailure("Uncooperative mint should time out")
    } catch let error as VideoMultipartTransportError {
      try verify(error.code == "ServiceAuthTimedOut", "mint has recoverable timeout")
    }
    await timeoutGate.open()
    let cancelGate = VideoTestGate()
    let cancelTokens = VideoServiceTokenProvider(refreshTimeout: 1, isOwner: { true }, mint: { _ in
      await cancelGate.wait()
      return "late-canceled-token"
    })
    let operation = Task { try await cancelTokens.token() }
    await cancelGate.waitUntilEntered()
    operation.cancel()
    do {
      _ = try await operation.value
      throw CheckFailure("Canceled token waiter should stop promptly")
    } catch is CancellationError {}
    await cancelGate.open()
  }

  @MainActor
  static func terminalAuthenticationAndReceiptFailures() async throws {
    let file = try fixtureFile(Data([1, 2]))
    let mint = TokenMintRecorder()
    let rejected = ScriptedVideoHTTP([
      .json(401, #"{"error":"AuthRequired"}"#), .json(401, #"{"error":"AuthRequired"}"#),
    ])
    let transport = VideoMultipartTransport(tokens: VideoServiceTokenProvider(isOwner: { true }, mint: { expiry in mint.mint(expiry) }), httpClient: rejected)
    do {
      _ = try await transport.uploadPart(jobID: "u", partNumber: 1, fileURL: file, byteCount: 2)
      throw CheckFailure("Repeated rejection should fail")
    } catch let error as VideoMultipartTransportError {
      try verify(error.isAuthenticationFailure, "second auth failure remains typed")
      try verify(!error.isRetryable, "auth denial cannot become ordinary transient retry")
    }
    try verify(await rejected.requests.count == 2 && mint.expiries.count == 2, "auth retry stops after one refresh")
    let mismatched = ScriptedVideoHTTP([.json(200, #"{"partNumber":2,"sizeBytes":2}"#)])
    let badReceipt = VideoMultipartTransport(tokens: VideoServiceTokenProvider(isOwner: { true }, mint: { _ in "service" }), httpClient: mismatched)
    do {
      _ = try await badReceipt.uploadPart(jobID: "u", partNumber: 1, fileURL: file, byteCount: 2)
      throw CheckFailure("Mismatched part receipt should fail")
    } catch let error as VideoMultipartTransportError {
      try verify(error.code == "InvalidPartReceipt", "receipt identity mismatch retained")
    }
    let unsupported = ScriptedVideoHTTP([.json(404, #"{"error":"MethodNotFound"}"#)])
    let oldServer = VideoMultipartTransport(tokens: VideoServiceTokenProvider(isOwner: { true }, mint: { _ in "service" }), httpClient: unsupported)
    do {
      _ = try await oldServer.start(input: .init(sizeBytes: 2, mimeType: "video/mp4"))
      throw CheckFailure("Unsupported start should be exposed")
    } catch let error as VideoMultipartTransportError {
      try verify(error.isUnsupportedEndpoint, "definite unsupported endpoint identifiable for legacy choice")
    }
    try verify(FileManager.default.fileExists(atPath: file.path), "all terminal errors retain user source")
  }

  @MainActor
  static func deniedServiceAuthNeverDispatchesStart() async throws {
    let http = ScriptedVideoHTTP([])
    let tokens = VideoServiceTokenProvider(isOwner: { true }, mint: { _ in
      throw VideoMultipartTransportError(statusCode: 403, code: "InsufficientScope", message: "Existing grant denied")
    })
    let transport = VideoMultipartTransport(tokens: tokens, httpClient: http)
    do {
      _ = try await transport.start(input: .init(sizeBytes: 10, mimeType: "video/mp4"))
      throw CheckFailure("denied service mint dispatched start")
    } catch let failure as VideoMultipartStartNotSent {
      let original = failure.underlying as? VideoMultipartTransportError
      try verify(original?.code == "InsufficientScope", "grant denial is preserved as original error")
    }
    try verify(await http.requests.isEmpty, "service-auth denial sends no request or replacement permission")
  }

  static func fixtureFile(_ bytes: Data) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("multipart-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("source.mp4")
    try bytes.write(to: file)
    return file
  }

  static func verify(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(message) }
  }
}

struct CheckFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

@MainActor
private final class TokenMintRecorder {
  var expiries: [Int] = []
  func mint(_ expiry: Int) -> String {
    expiries.append(expiry)
    return "service-\(expiries.count)"
  }
}

actor ScriptedVideoHTTP: VideoMultipartHTTPClient {
  enum Reply: @unchecked Sendable {
    case json(Int, String)
    case failure(any Error)
  }
  struct Recorded: Sendable {
    let request: URLRequest
    let fileBytes: Data?
  }
  private var replies: [Reply]
  private(set) var requests: [Recorded] = []
  init(_ replies: [Reply]) { self.replies = replies }
  func perform(_ request: URLRequest, fileURL: URL?, onProgress: (@Sendable (Int64) -> Void)?) async throws -> (Data, HTTPURLResponse) {
    let bytes = try fileURL.map { try Data(contentsOf: $0) }
    requests.append(Recorded(request: request, fileBytes: bytes))
    guard !replies.isEmpty else { throw CheckFailure("Unexpected extra HTTP request") }
    switch replies.removeFirst() {
    case .json(let code, let body):
      return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                                            headerFields: ["Content-Type": "application/json"])!)
    case .failure(let error): throw error
    }
  }
}

actor VideoTestGate {
  private var opened = false
  private var entered = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var observers: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    entered = true
    observers.forEach { $0.resume() }
    observers.removeAll()
    if opened { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { observers.append($0) }
  }
  func open() {
    opened = true
    waiters.forEach { $0.resume() }
    waiters.removeAll()
  }
}

#if !MULTIPART_HARNESS
@Suite("Multipart video transport")
struct VideoMultipartTransportTests {
  @Test func responseFormats() throws { try VideoMultipartTransportChecks.bothResponseFormats() }
  @Test @MainActor func startContract() async throws { try await VideoMultipartTransportChecks.startRequestContract() }
  @Test @MainActor func rawPartAndAuthRetry() async throws { try await VideoMultipartTransportChecks.rawPartContractAndAuthenticationRetry() }
  @Test @MainActor func publicPollAndLostStart() async throws { try await VideoMultipartTransportChecks.publicJobStatusAndOneShotStart() }
  @Test @MainActor func tokenOwnership() async throws { try await VideoMultipartTransportChecks.tokenCoalescingAndOwnership() }
  @Test @MainActor func tokenTimeoutAndCancel() async throws { try await VideoMultipartTransportChecks.boundedUncooperativeMintAndCancellation() }
  @Test @MainActor func terminalFailures() async throws { try await VideoMultipartTransportChecks.terminalAuthenticationAndReceiptFailures() }
  @Test @MainActor func deniedGrantSendsNothing() async throws { try await VideoMultipartTransportChecks.deniedServiceAuthNeverDispatchesStart() }
}
#endif
