import Foundation
import Petrel

struct VideoMultipartProgress: Sendable {
  enum Phase: String, Sendable { case preparing, uploading, finalizing, processing, complete }
  let phase: Phase
  /// Within the named stage. Confirmed part bytes are used so retries never overcount progress.
  let fraction: Double
}

struct VideoMultipartConfiguration: Sendable {
  var workerCount = 4
  var partAttempts = 5
  var finishAttempts = 3
  var finalizationPollLimit = 60
  var processingPollLimit = 60
  var maxConsecutiveStatusFailures = 3
  var operationTimeout: TimeInterval = 1800
  var processingTimeout: TimeInterval = 300
  var pollInterval: TimeInterval = 2
  var now: @Sendable () -> Date = { Date() }
  var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
    try await Task.sleep(nanoseconds: UInt64(max(0, min(seconds, 120)) * 1_000_000_000))
  }
}

enum VideoMultipartError: LocalizedError {
  case alreadyRunning, ownerChanged, invalidPlan, invalidReceipt, invalidStatus
  case startUncertain, sessionTerminal(String), transferTimedOut, processingTimedOut
  case processingFailed(code: String?, message: String)

  var errorDescription: String? {
    switch self {
    case .alreadyRunning: return "This video already has an active upload."
    case .ownerChanged: return "The account or attachment changed while the video was uploading."
    case .invalidPlan: return "The video service returned an invalid upload plan."
    case .invalidReceipt: return "The video service did not acknowledge the expected video part."
    case .invalidStatus: return "The video service returned an inconsistent upload status."
    case .startUncertain: return "The video service may have started an upload, but its response was lost. Your video is preserved. A new explicit retry may temporarily use another upload allowance."
    case .sessionTerminal(let reason): return "This video upload cannot continue: \(reason). Your attachment is preserved for a new attempt."
    case .transferTimedOut: return "Video upload is taking too long. Your attachment and upload progress are preserved for retry."
    case .processingTimedOut: return "The video is still processing. Retry to check the saved job without uploading the file again."
    case .processingFailed(let code, let message):
      return code.map { "\(message) (\($0))" } ?? message
    }
  }
}

/// No server split-size assumptions and no allocation proportional to an untrusted part count.
struct VideoUploadPartPlan: Sendable {
  let sizeBytes: Int
  let partSizeBytes: Int
  let partCount: Int

  init(sizeBytes: Int, partSizeBytes: Int, partCount: Int) throws {
    guard sizeBytes > 0, partSizeBytes > 0, partCount > 0,
      partCount == 1 + (sizeBytes - 1) / partSizeBytes
    else { throw VideoMultipartError.invalidPlan }
    self.sizeBytes = sizeBytes
    self.partSizeBytes = partSizeBytes
    self.partCount = partCount
  }

  func byteRange(partNumber: Int) throws -> (offset: Int64, count: Int) {
    guard partNumber >= 1, partNumber <= partCount else { throw VideoMultipartError.invalidPlan }
    let (offset, overflow) = Int64(partNumber - 1).multipliedReportingOverflow(by: Int64(partSizeBytes))
    guard !overflow, offset >= 0, offset < Int64(sizeBytes) else { throw VideoMultipartError.invalidPlan }
    return (offset, min(partSizeBytes, sizeBytes - Int(offset)))
  }

  func receivedParts(_ parts: [Int]) throws -> Set<Int> {
    guard parts.allSatisfy({ $0 >= 1 && $0 <= partCount }) else { throw VideoMultipartError.invalidReceipt }
    return Set(parts)
  }
}

/// A single owned operation. Transport owns direct service requests/auth; this actor owns retry,
/// reconciliation and persistence. A restored checkpoint never creates a post on its own.
actor VideoMultipartUpload {
  private let transport: any VideoMultipartTransporting
  private let store: VideoUploadCheckpointStore
  private let configuration: VideoMultipartConfiguration
  private var running = false
  private var checkpoint: VideoUploadCheckpoint?

  private struct Context: Sendable {
    let owner: VideoUploadOwner
    let deadline: Date
    let progress: @Sendable (VideoMultipartProgress) async -> Void
    let isOwnerCurrent: @Sendable () async -> Bool
    let canAuthorizeCleanup: @Sendable () async -> Bool
  }

  init(
    transport: any VideoMultipartTransporting,
    store: VideoUploadCheckpointStore,
    configuration: VideoMultipartConfiguration = .init()
  ) {
    self.transport = transport
    self.store = store
    self.configuration = configuration
  }

  /// `allowNewSessionAfterTerminal` is for a new user submit/retry, including a previously
  /// uncertain start or changed source bytes. It never permits replaying start within this
  /// invocation. Old session metadata and immutable source snapshots stay in local history.
  func run(
    sourceURL: URL,
    owner: VideoUploadOwner,
    mimeType: String,
    durationMilliseconds: Int? = nil,
    allowNewSessionAfterTerminal: Bool = false,
    progress: @escaping @Sendable (VideoMultipartProgress) async -> Void,
    isOwnerCurrent: @escaping @Sendable () async -> Bool,
    canAuthorizeCleanup: (@Sendable () async -> Bool)? = nil,
    authorizeNewSession: @Sendable () async throws -> Void = {}
  ) async throws -> Blob {
    guard !running else { throw VideoMultipartError.alreadyRunning }
    running = true
    defer { running = false; checkpoint = nil }
    let context = Context(
      owner: owner, deadline: configuration.now().addingTimeInterval(configuration.operationTimeout),
      progress: progress, isOwnerCurrent: isOwnerCurrent,
      canAuthorizeCleanup: canAuthorizeCleanup ?? isOwnerCurrent
    )

    do {
      try await ensureCurrent(context)
      await progress(.init(phase: .preparing, fraction: 0))
      var saved = try await store.prepare(
        sourceURL: sourceURL, owner: owner, mimeType: mimeType,
        allowReplacementSource: allowNewSessionAfterTerminal
      )
      checkpoint = saved
      try await ensureCurrent(context)
      if saved.phase == .abandoned, saved.uploadJobID != nil {
        // A new explicit retry reconciles an interrupted known session before allocating anything.
        // prepare only grants this lease after any previous abort request has settled.
        saved.phase = saved.completedJobID == nil ? .uploading : .processing
        try await save(saved)
      }
      switch saved.phase {
      case .starting, .startUncertain, .abandoned, .terminal:
        guard allowNewSessionAfterTerminal else {
          if saved.phase == .starting || saved.phase == .startUncertain { throw VideoMultipartError.startUncertain }
          throw VideoMultipartError.sessionTerminal(saved.failureReason ?? saved.phase.rawValue)
        }
        saved = try await store.beginNewAttempt(from: saved)
        checkpoint = saved
        try await ensureCurrent(context)
      default: break
      }

      if saved.phase == .prepared {
        // Existing reservations and processing-only resumes do not consume a fresh quota check.
        try await authorizeNewSession()
        try await ensureCurrent(context)
        saved.phase = .starting
        do {
          try await save(saved)
          try await ensureCurrent(context)
        } catch {
          // Neither a failed checkpoint write nor ownership loss here sent a start request.
          saved.phase = .prepared
          try? await save(saved)
          throw error
        }
        do {
          let response = try await transport.start(input: .init(
            sizeBytes: saved.sizeBytes, mimeType: saved.mimeType,
            name: saved.operationID.uuidString, durationMs: durationMilliseconds
          ))
          // Record a returned ID even when cancellation raced the response, so cleanup can abort it.
          saved.uploadJobID = response.jobId
          saved.partSizeBytes = response.partSizeBytes
          saved.partCount = response.partCount
          saved.expiresAt = response.expiresAt.date
          saved.phase = .uploading
          try await save(saved)
          try await ensureCurrent(context)
          guard !response.jobId.isEmpty else { throw VideoMultipartError.invalidPlan }
          _ = try plan(for: saved)
        } catch {
          if saved.uploadJobID == nil {
            // A definite HTTP rejection did not allocate a session; transport/malformed-success
            // failures may have done so. Never automatically replay either case in this run.
            if let notSent = error as? VideoMultipartStartNotSent {
              saved.phase = .prepared
              try await save(saved)
              throw notSent.underlying
            }
            if let response = error as? VideoMultipartTransportError,
              response.isUnsupportedEndpoint || (response.statusCode.map { (400..<500).contains($0) && $0 != 408 } ?? false) {
              saved.phase = .prepared
              try await save(saved)
              throw error
            }
            saved.phase = .startUncertain
            try await save(saved)
            if error is CancellationError { throw error }
            throw VideoMultipartError.startUncertain
          }
          throw error
        }
      }

      let blob: Blob
      if let processingID = saved.completedJobID {
        blob = try await process(jobID: processingID, initial: nil, context: context)
      } else {
        blob = try await reconcile(context: context)
      }
      await store.release(owner: owner, runID: saved.runID)
      try await ensureCurrent(context)
      return blob
    } catch {
      if error is CancellationError || isOwnershipError(error) {
        await abandon(context: context)
      } else if case VideoMultipartError.invalidPlan = error {
        await abandon(context: context, terminalReason: error.localizedDescription)
      }
      if let held = checkpoint { await store.release(owner: held.owner, runID: held.runID) }
      throw error
    }
  }

  private func reconcile(context: Context) async throws -> Blob {
    var finishAttempts = 0
    for _ in 0..<max(1, configuration.finalizationPollLimit) {
      try await ensureCurrent(context)
      var saved = try currentCheckpoint()
      guard let jobID = saved.uploadJobID, !jobID.isEmpty else { throw VideoMultipartError.invalidStatus }
      let status = try await uploadStatus(jobID: jobID, context: context)
      let partPlan = try validate(status: status, checkpoint: saved)

      switch status.state {
      case "created":
        guard status.expiresAt.date > configuration.now() else {
          try await terminate("expired")
          throw VideoMultipartError.sessionTerminal("expired")
        }
        guard finishAttempts < max(1, configuration.finishAttempts) else {
          throw VideoMultipartError.transferTimedOut
        }
        do {
          try await transfer(
            checkpoint: saved, plan: partPlan, received: partPlan.receivedParts(status.receivedParts), context: context
          )
        } catch let error as VideoMultipartTransportError
          where error.code == "UploadNotReady" || error.code == "UploadAlreadyCompleted" {
          // Another response may have been lost; only server status chooses the next action.
          continue
        }
        try await ensureCurrent(context)
        saved.phase = .finishing
        try await save(saved)
        await context.progress(.init(phase: .finalizing, fraction: 0))
        try await ensureCurrent(context)
        finishAttempts += 1
        let finishResponse: AppBskyVideoFinishUpload.Output
        do {
          finishResponse = try await transport.finish(jobID: jobID)
          try await ensureCurrent(context)
        } catch {
          if error is CancellationError || isOwnershipError(error) { throw error }
          // Even timeout/5xx can mean finish committed. Query this upload before any next action.
          try await ensureCurrent(context)
          continue
        }
        return try await acceptCompletion(
          jobID: finishResponse.completedJobId, status: finishResponse.jobStatus, context: context
        )

      case "finishing":
        saved.phase = .finishing
        try await save(saved)
        await context.progress(.init(phase: .finalizing, fraction: 0))
        try await pause(configuration.pollInterval, context: context)

      case "completed":
        guard let completedID = status.completedJobId, !completedID.isEmpty else {
          throw VideoMultipartError.invalidStatus
        }
        return try await acceptCompletion(jobID: completedID, status: status.jobStatus, context: context)

      case "failed", "aborted", "expired":
        let reason = status.failureReason ?? status.state
        try await terminate(reason)
        throw VideoMultipartError.sessionTerminal(reason)

      default:
        // An unknown state cannot safely be treated as created or completed.
        throw VideoMultipartError.invalidStatus
      }
    }
    throw VideoMultipartError.transferTimedOut
  }

  private func transfer(
    checkpoint saved: VideoUploadCheckpoint, plan: VideoUploadPartPlan,
    received: Set<Int>, context: Context
  ) async throws {
    var acknowledged = try received.reduce(0) { try $0 + plan.byteRange(partNumber: $1).count }
    await context.progress(.init(phase: .uploading, fraction: Double(acknowledged) / Double(plan.sizeBytes)))
    try await ensureCurrent(context)
    var nextPart: Int? = 1
    func nextMissing() -> Int? {
      while let value = nextPart {
        nextPart = value == plan.partCount ? nil : value + 1
        if !received.contains(value) { return value }
      }
      return nil
    }

    try await withThrowingTaskGroup(of: Int.self) { group in
      for _ in 0..<max(1, min(4, configuration.workerCount)) {
        if let part = nextMissing() {
          group.addTask { try await self.sendPart(part, checkpoint: saved, plan: plan, context: context) }
        }
      }
      do {
        while let count = try await group.next() {
          try await ensureCurrent(context)
          acknowledged += count
          await context.progress(.init(phase: .uploading, fraction: min(1, Double(acknowledged) / Double(plan.sizeBytes))))
          if let part = nextMissing() {
            group.addTask { try await self.sendPart(part, checkpoint: saved, plan: plan, context: context) }
          }
        }
      } catch {
        group.cancelAll()
        throw error
      }
    }
  }

  private func sendPart(
    _ number: Int, checkpoint saved: VideoUploadCheckpoint,
    plan: VideoUploadPartPlan, context: Context
  ) async throws -> Int {
    try await ensureCurrent(context)
    guard let jobID = saved.uploadJobID else { throw VideoMultipartError.invalidStatus }
    let range = try plan.byteRange(partNumber: number)
    let partURL = try await store.makePart(checkpoint: saved, partNumber: number, offset: range.offset, count: range.count)
    do {
      for attempt in 0..<max(1, min(5, configuration.partAttempts)) {
        try await ensureCurrent(context)
        do {
          let response = try await transport.uploadPart(
            jobID: jobID, partNumber: number, fileURL: partURL, byteCount: range.count, onProgress: nil
          )
          try await ensureCurrent(context)
          guard response.partNumber == number, response.sizeBytes == range.count else {
            throw VideoMultipartError.invalidReceipt
          }
          try? await store.removePart(partURL, owner: saved.owner)
          return range.count
        } catch {
          guard !(error is CancellationError), !isOwnershipError(error),
            attempt + 1 < max(1, min(5, configuration.partAttempts)),
            VideoMultipartTransportError.isTransient(error)
          else { throw error }
          try await pause(retryDelay(error: error, attempt: attempt), context: context)
        }
      }
      throw VideoMultipartError.transferTimedOut
    } catch {
      try? await store.removePart(partURL, owner: saved.owner)
      throw error
    }
  }

  private func uploadStatus(jobID: String, context: Context) async throws -> AppBskyVideoGetUploadStatus.Output {
    for attempt in 0..<max(1, configuration.maxConsecutiveStatusFailures) {
      try await ensureCurrent(context)
      do {
        let response = try await transport.status(jobID: jobID)
        try await ensureCurrent(context)
        return response
      } catch {
        guard !(error is CancellationError), !isOwnershipError(error),
          attempt + 1 < max(1, configuration.maxConsecutiveStatusFailures),
          VideoMultipartTransportError.isTransient(error)
        else { throw error }
        try await pause(retryDelay(error: error, attempt: attempt), context: context)
      }
    }
    throw VideoMultipartError.transferTimedOut
  }

  private func acceptCompletion(
    jobID: String, status: AppBskyVideoDefs.JobStatus?, context: Context
  ) async throws -> Blob {
    try await ensureCurrent(context)
    guard !jobID.isEmpty else { throw VideoMultipartError.invalidStatus }
    if let status { try validateProcessing(status, jobID: jobID, owner: context.owner) }
    var saved = try currentCheckpoint()
    saved.completedJobID = jobID
    saved.phase = .processing
    try await save(saved)
    return try await process(jobID: jobID, initial: status, context: context)
  }

  private func process(
    jobID: String, initial: AppBskyVideoDefs.JobStatus?, context: Context
  ) async throws -> Blob {
    let deadline = min(context.deadline, configuration.now().addingTimeInterval(configuration.processingTimeout))
    var next = initial
    var consecutiveFailures = 0
    for _ in 0..<max(1, configuration.processingPollLimit) {
      try await ensureCurrent(context)
      guard configuration.now() < deadline else { throw VideoMultipartError.processingTimedOut }
      let status: AppBskyVideoDefs.JobStatus
      if let known = next {
        status = known
        next = nil
      } else {
        do {
          status = try await transport.jobStatus(jobID: jobID)
          try await ensureCurrent(context)
          consecutiveFailures = 0
        } catch {
          if error is CancellationError || isOwnershipError(error) { throw error }
          consecutiveFailures += 1
          guard consecutiveFailures < max(1, configuration.maxConsecutiveStatusFailures),
            VideoMultipartTransportError.isTransient(error)
          else { throw error }
          try await pause(retryDelay(error: error, attempt: consecutiveFailures - 1), context: context, processingDeadline: deadline)
          continue
        }
      }
      try validateProcessing(status, jobID: jobID, owner: context.owner)
      switch VideoProcessingOutcome<Blob>.resolve(
        state: status.state, progress: status.progress, blob: status.blob,
        error: status.error, message: status.message
      ) {
      case .complete(let blob):
        var saved = try currentCheckpoint()
        saved.phase = .complete
        saved.completedJobID = jobID
        try await save(saved)
        try await ensureCurrent(context)
        await context.progress(.init(phase: .complete, fraction: 1))
        try await ensureCurrent(context)
        return blob
      case .failed(let message):
        try await terminate(status.failureCode.map { "\(message) (\($0))" } ?? message)
        throw VideoMultipartError.processingFailed(code: status.failureCode, message: message)
      case .pending(let progress):
        await context.progress(.init(phase: .processing, fraction: progress))
        try await pause(configuration.pollInterval, context: context, processingDeadline: deadline)
      }
    }
    throw VideoMultipartError.processingTimedOut
  }

  private func validateProcessing(_ status: AppBskyVideoDefs.JobStatus, jobID: String, owner: VideoUploadOwner) throws {
    guard status.jobId == jobID, status.did.description == owner.accountDID else {
      throw VideoMultipartError.invalidStatus
    }
  }

  private func validate(
    status: AppBskyVideoGetUploadStatus.Output, checkpoint saved: VideoUploadCheckpoint
  ) throws -> VideoUploadPartPlan {
    guard status.jobId == saved.uploadJobID, status.partSizeBytes == saved.partSizeBytes,
      status.partCount == saved.partCount
    else { throw VideoMultipartError.invalidStatus }
    let plan = try plan(for: saved)
    _ = try plan.receivedParts(status.receivedParts)
    return plan
  }

  private func plan(for saved: VideoUploadCheckpoint) throws -> VideoUploadPartPlan {
    guard let size = saved.partSizeBytes, let count = saved.partCount else { throw VideoMultipartError.invalidPlan }
    return try .init(sizeBytes: saved.sizeBytes, partSizeBytes: size, partCount: count)
  }

  private func currentCheckpoint() throws -> VideoUploadCheckpoint {
    guard let checkpoint else { throw VideoMultipartError.invalidStatus }
    return checkpoint
  }

  private func save(_ saved: VideoUploadCheckpoint) async throws {
    checkpoint = saved
    try await store.save(saved)
  }

  private func terminate(_ reason: String) async throws {
    var saved = try currentCheckpoint()
    saved.phase = .terminal
    saved.failureReason = reason
    try await save(saved)
  }

  private func ensureCurrent(_ context: Context) async throws {
    try Task.checkCancellation()
    guard await context.isOwnerCurrent() else { throw VideoMultipartError.ownerChanged }
    try Task.checkCancellation()
    guard configuration.now() < context.deadline else { throw VideoMultipartError.transferTimedOut }
  }

  private func pause(_ seconds: TimeInterval, context: Context, processingDeadline: Date? = nil) async throws {
    try await ensureCurrent(context)
    let deadline = min(context.deadline, processingDeadline ?? context.deadline)
    guard seconds.isFinite, seconds < deadline.timeIntervalSince(configuration.now()) else {
      if processingDeadline != nil { throw VideoMultipartError.processingTimedOut }
      throw VideoMultipartError.transferTimedOut
    }
    // Never retry sooner than the server's Retry-After. Sleep in bounded cancellable intervals.
    var remaining = max(0, seconds)
    while remaining > 0 {
      let interval = min(120, remaining)
      try await configuration.sleep(interval)
      remaining -= interval
      try await ensureCurrent(context)
      if let processingDeadline, configuration.now() >= processingDeadline {
        throw VideoMultipartError.processingTimedOut
      }
    }
    try await ensureCurrent(context)
  }

  private func retryDelay(error: Error, attempt: Int) -> TimeInterval {
    if let seconds = (error as? VideoMultipartTransportError)?.retryAfterSeconds, seconds.isFinite {
      return max(0, seconds)
    }
    return min(8, pow(2, Double(attempt)))
  }

  private func isOwnershipError(_ error: Error) -> Bool {
    if case VideoMultipartError.ownerChanged = error { return true }
    if case VideoUploadFileError.ownerChanged = error { return true }
    return false
  }

  private func abandon(context: Context, terminalReason: String? = nil) async {
    guard var saved = checkpoint else { return }
    if saved.completedJobID != nil {
      saved.phase = .processing
      try? await save(saved)
      return
    }
    if saved.uploadJobID == nil {
      if saved.phase == .starting { saved.phase = .startUncertain }
      try? await save(saved)
      return
    }
    saved.phase = terminalReason == nil ? .abandoned : .terminal
    saved.failureReason = terminalReason
    try? await save(saved)
    guard await store.beginCleanup(saved) else { return }
    let transport = self.transport
    let store = self.store
    let configuration = self.configuration
    let abandonedCheckpoint = saved
    // Independent cleanup must survive cancellation of the UI task, but never change accounts or
    // write over a replacement operation. Network request deadlines are enforced by transport.
    Task.detached {
      await Self.cleanUpAbandonedUpload(
        abandonedCheckpoint, transport: transport, store: store,
        configuration: configuration, context: context
      )
      await store.finishCleanup(owner: abandonedCheckpoint.owner, runID: abandonedCheckpoint.runID)
    }
  }

  private static func cleanUpAbandonedUpload(
    _ abandonedCheckpoint: VideoUploadCheckpoint,
    transport: any VideoMultipartTransporting,
    store: VideoUploadCheckpointStore,
    configuration: VideoMultipartConfiguration,
    context: Context
  ) async {
    var abandoned = abandonedCheckpoint
    guard let jobID = abandoned.uploadJobID else { return }
    for attempt in 0..<3 {
      guard await context.canAuthorizeCleanup(), await store.isCurrentLease(abandoned) else { return }
      do {
        let response = try await transport.abort(jobID: jobID)
        guard await context.canAuthorizeCleanup(), await store.isCurrentLease(abandoned) else { return }
        if response.state == "completed" {
          abandoned.completedJobID = response.completedJobId
          if abandoned.completedJobID != nil { abandoned.phase = .processing }
        }
        abandoned.failureReason = response.failureReason ?? response.state
        try? await store.save(abandoned)
        return
      } catch {
        if (error as? VideoMultipartTransportError)?.code == "UploadNotReady" {
          // Encoding is already underway. Reconcile once; retain the ID on a failed lookup.
          guard await context.canAuthorizeCleanup(), await store.isCurrentLease(abandoned) else { return }
          if let status = try? await transport.status(jobID: jobID), status.jobId == jobID,
            await context.canAuthorizeCleanup(), await store.isCurrentLease(abandoned) {
            if status.state == "completed" {
              abandoned.completedJobID = status.completedJobId
              if abandoned.completedJobID != nil { abandoned.phase = .processing }
            }
            abandoned.failureReason = status.failureReason ?? status.state
            try? await store.save(abandoned)
          }
          return
        }
        guard attempt < 2, VideoMultipartTransportError.isTransient(error) else { return }
        try? await configuration.sleep(1)
      }
    }
  }
}
