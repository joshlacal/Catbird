import Foundation
import Petrel
#if !MULTIPART_HARNESS
import Testing
@testable import Catbird
#endif

enum VideoMultipartUploadChecks {
  static let owner = VideoUploadOwner(accountDID: "did:plc:alice", draftID: "draft", entryID: "entry", mediaID: "media")
  static let expiry = Date(timeIntervalSince1970: 4_000_000_000)
  static let blob = Blob(type: "blob", mimeType: "video/mp4", size: 10, cid: "synthetic-video")

  static func partBounds() throws {
    let plan = try VideoUploadPartPlan(sizeBytes: 10, partSizeBytes: 4, partCount: 3)
    let last = try plan.byteRange(partNumber: 3)
    try check(last.offset == 8 && last.count == 2, "last part is exactly remaining bytes")
    let maximum = try VideoUploadPartPlan(sizeBytes: Int.max, partSizeBytes: Int.max - 1, partCount: 2)
    try check(try maximum.byteRange(partNumber: 2).count == 1, "overflow-safe plan math")
    for values in [(0, 4, 1), (10, 0, 1), (10, 4, 2), (Int.max, 1, 1)] {
      do {
        _ = try VideoUploadPartPlan(sizeBytes: values.0, partSizeBytes: values.1, partCount: values.2)
        throw CheckFailure("invalid part plan accepted")
      } catch VideoMultipartError.invalidPlan {}
    }
    for number in [0, -1, 4] {
      do { _ = try plan.byteRange(partNumber: number); throw CheckFailure("invalid part index accepted") }
      catch VideoMultipartError.invalidPlan {}
    }
    try check(try plan.receivedParts([1, 1, 3]) == Set([1, 3]), "duplicate server receipts do not inflate progress")
    do { _ = try plan.receivedParts([4]); throw CheckFailure("out-of-plan receipt accepted") }
    catch VideoMultipartError.invalidReceipt {}
  }

  static func checkpointOwnershipAndSource() async throws {
    let fixture = try Self.fixture()
    let checkpoint = try await fixture.store.prepare(sourceURL: fixture.source, owner: owner, mimeType: "video/mp4")
    do {
      _ = try await fixture.store.prepare(sourceURL: fixture.source, owner: owner, mimeType: "video/mp4")
      throw CheckFailure("concurrent same-owner upload acquired active lease")
    } catch VideoUploadFileError.uploadAlreadyActive {}
    await fixture.store.release(owner: owner, runID: checkpoint.runID)
    let repeated = try await fixture.store.prepare(sourceURL: fixture.source, owner: owner, mimeType: "video/mp4")
    try check(checkpoint.operationID == repeated.operationID, "same owner and bytes retain upload identity")
    try check(checkpoint.runID != repeated.runID, "retry rotates run lease while preserving session")
    do { try await fixture.store.save(checkpoint); throw CheckFailure("old same-session cleanup overwrote new run") }
    catch VideoUploadFileError.ownerChanged {}
    let reopened = try VideoUploadCheckpointStore(rootURL: fixture.root)
    try check(try await reopened.load(owner: owner)?.operationID == checkpoint.operationID, "checkpoint persists across store instances")
    let other = VideoUploadOwner(accountDID: "did:plc:bob", draftID: owner.draftID, entryID: owner.entryID, mediaID: owner.mediaID)
    try check(try await reopened.load(owner: other) == nil, "another account cannot recover this checkpoint")
    do {
      _ = try await fixture.store.makePart(checkpoint: checkpoint, partNumber: 3, offset: 8, count: 2)
      throw CheckFailure("stale lease created an upload part")
    } catch VideoUploadFileError.ownerChanged {}
    let part = try await fixture.store.makePart(checkpoint: repeated, partNumber: 3, offset: 8, count: 2)
    try check(try Data(contentsOf: part) == Data([8, 9]), "part file exact source range")
    let replacement = try await fixture.store.beginNewAttempt(from: repeated)
    try check(replacement.operationID != checkpoint.operationID, "explicit retry gets new operation identity")
    do { try await fixture.store.save(checkpoint); throw CheckFailure("old callback overwrote replacement") }
    catch VideoUploadFileError.ownerChanged {}
    await fixture.store.release(owner: owner, runID: repeated.runID)
    try Data(repeating: 99, count: 10).write(to: fixture.source)
    do {
      _ = try await fixture.store.prepare(sourceURL: fixture.source, owner: owner, mimeType: "video/mp4")
      throw CheckFailure("same-size changed source reused old upload")
    } catch VideoUploadFileError.sourceChanged {}
    try check(try Data(contentsOf: fixture.source) == Data(repeating: 99, count: 10), "changed source remains intact")
    let files = FileManager.default.enumerator(at: fixture.root, includingPropertiesForKeys: nil)!.allObjects as! [URL]
    let snapshots = files.filter { $0.pathExtension == "video" }
    try check(snapshots.count == 1 && (try Data(contentsOf: snapshots[0])) == Data(0..<10), "original immutable snapshot retained")
    for path in files where path.pathExtension == "json" {
      let text = String(decoding: try Data(contentsOf: path), as: UTF8.self)
      try check(!text.contains("Bearer") && !text.contains("access_token") && !text.contains("service-"), "checkpoint metadata has no credentials")
    }
    let changed = try await fixture.store.prepare(sourceURL: fixture.source, owner: owner, mimeType: "video/mp4", allowReplacementSource: true)
    try check(changed.operationID != replacement.operationID && changed.sha256 != replacement.sha256, "explicit changed-source retry allocates a distinct snapshot and operation")
    let after = FileManager.default.enumerator(at: fixture.root, includingPropertiesForKeys: nil)!.allObjects as! [URL]
    let allSnapshots = after.filter { $0.pathExtension == "video" }
    try check(allSnapshots.count == 2, "explicit source replacement retains both old and new video files")
    try check(try Data(contentsOf: snapshots[0]) == Data(0..<10), "replacement never overwrites prior snapshot")
    await fixture.store.release(owner: owner, runID: changed.runID)
  }

  static func retryPartsAndCanonicalProcessing() async throws {
    let fixture = try Self.fixture()
    let transport = ScriptedVideoTransport(statuses: [.success(status("created", received: [1]))],
                                          finishes: [.success(.init(completedJobId: "canonical", jobStatus: try job("canonical")))],
                                          jobs: [.success(try job("canonical", state: "JOB_STATE_COMPLETED", blob: blob))])
    await transport.failPart(2, with: [URLError(.networkConnectionLost)])
    let progress = ProgressRecorder()
    let engine = VideoMultipartUpload(transport: transport, store: fixture.store, configuration: configuration())
    let result = try await run(engine, fixture: fixture, progress: { await progress.add($0) })
    try check(result == blob, "returns final blob")
    let parts = await transport.parts
    try check(parts.map(\.number) == [2, 2, 3], "retry same part; skip authoritative received part")
    try check(parts[0].bytes == parts[1].bytes && parts[2].bytes == Data([8, 9]), "retry and last-part bytes exact")
    try check(await [transport.startCount, transport.finishCount] == [1, 1], "one session and one finalization")
    try check(await transport.polledJobs == ["canonical"], "poll deduplicated canonical processing ID")
    let stages = await progress.values
    try check(stages.allSatisfy { $0.fraction >= 0 && $0.fraction <= 1 }, "progress clamped under retries")
    try check(stages.filter { $0.phase == .uploading }.map(\.fraction) == [0.4, 0.8, 1.0], "failed attempt never double-counts bytes")
    try check(try await fixture.store.load(owner: owner)?.phase == .complete, "success checkpoint retained")
    try retained(fixture)
  }

  static func fourWorkersStayBoundedAndSendExactBytes() async throws {
    let bytes = Data(0..<18)
    let source = try VideoMultipartTransportChecks.fixtureFile(bytes)
    let root = source.deletingLastPathComponent().appendingPathComponent("checkpoints")
    let store = try VideoUploadCheckpointStore(rootURL: root)
    let probe = MultipartConcurrencyProbe()
    let watchdog = Task {
      try await Task.sleep(for: .seconds(2))
      await probe.releaseAll()
    }
    defer { watchdog.cancel() }
    let completed = Blob(type: "blob", mimeType: "video/mp4", size: 18, cid: "synthetic-parallel-video")
    let transport = ScriptedVideoTransport(
      statuses: [.success(.init(jobId: "upload", partSizeBytes: 4, partCount: 5,
        receivedParts: [], expiresAt: ATProtocolDate(date: expiry), state: "created"))],
      finishes: [.success(.init(completedJobId: "canonical",
        jobStatus: try job("canonical", state: "JOB_STATE_COMPLETED", blob: completed)))],
      onPart: { await probe.enter(); await probe.leave() }, partCount: 5)
    var config = configuration()
    config.workerCount = 4
    let engine = VideoMultipartUpload(transport: transport, store: store, configuration: config)
    let result = try await engine.run(sourceURL: source, owner: owner, mimeType: "video/mp4",
      progress: { _ in }, isOwnerCurrent: { true })
    try check(result == completed, "parallel upload returns the canonical blob")
    try check(await probe.maximum == 4, "exactly four part requests run concurrently")
    let parts = await transport.parts.sorted { $0.number < $1.number }
    try check(parts.map(\.number) == [1, 2, 3, 4, 5], "each part is sent exactly once")
    try check(parts.reduce(into: Data()) { $0.append($1.bytes) } == bytes, "parallel parts reconstruct exact source")
    try check(try Data(contentsOf: source) == bytes, "parallel upload preserves original source")
  }

  static func missingPartsAndLostFinish() async throws {
    let fixture = try Self.fixture()
    let transport = ScriptedVideoTransport(
      statuses: [.success(status("created", received: [1, 2, 3])), .success(status("created", received: [1, 3]))],
      finishes: [.failure(VideoMultipartTransportError(statusCode: 400, code: "MissingParts", message: "do not parse this prose")),
                 .success(.init(completedJobId: "canonical", jobStatus: try job("canonical", state: "JOB_STATE_COMPLETED", blob: blob)))])
    let result = try await run(VideoMultipartUpload(transport: transport, store: fixture.store, configuration: configuration()), fixture: fixture)
    try check(result == blob, "missing-parts recovery succeeds")
    try check(await transport.parts.map(\.number) == [2], "server status alone picks missing part")
    try check(await [transport.finishCount, transport.startCount] == [2, 1], "same upload finalized again without restart")
    try retained(fixture)

    let lost = try Self.fixture()
    let uncertain = ScriptedVideoTransport(
      statuses: [.success(status("created", received: [1, 2, 3])), .success(status("finishing")),
                 .success(status("completed", completedID: "canonical", job: try job("canonical", state: "JOB_STATE_COMPLETED", blob: blob)))],
      finishes: [.failure(URLError(.timedOut))])
    _ = try await run(VideoMultipartUpload(transport: uncertain, store: lost.store, configuration: configuration()), fixture: lost)
    try check(await [uncertain.startCount, uncertain.finishCount] == [1, 1], "lost finish does not restart or refinish while finishing")
    try check(await uncertain.polledJobs.isEmpty, "completed status blob short-circuits public poll")
    try retained(lost)
  }

  static func uncertainStartRequiresExplicitRetry() async throws {
    let fixture = try Self.fixture()
    let transport = ScriptedVideoTransport(startFailure: URLError(.timedOut))
    let engine = VideoMultipartUpload(transport: transport, store: fixture.store, configuration: configuration())
    for _ in 0..<2 {
      do { _ = try await run(engine, fixture: fixture); throw CheckFailure("uncertain start must fail") }
      catch VideoMultipartError.startUncertain {}
    }
    try check(await transport.startCount == 1, "retrying recovery never blindly replays unknown start")
    try check(try await fixture.store.load(owner: owner)?.phase == .startUncertain, "unknown reservation explicitly checkpointed")
    try retained(fixture)
  }

  static func boundedFinalizationAndProcessingResume() async throws {
    let finishing = try Self.fixture()
    let transport = ScriptedVideoTransport(statuses: [.success(status("finishing"))])
    var config = configuration(); config.finalizationPollLimit = 3
    do {
      _ = try await run(VideoMultipartUpload(transport: transport, store: finishing.store, configuration: config), fixture: finishing)
      throw CheckFailure("forever-finishing should time out")
    } catch VideoMultipartError.transferTimedOut {}
    try check(await [transport.statusCount, transport.finishCount] == [3, 0], "finalization bounded without finish spam")
    try retained(finishing)

    let processing = try Self.fixture()
    let pending = try job("canonical")
    let poller = ScriptedVideoTransport(statuses: [.success(status("completed", completedID: "canonical", job: pending))], jobs: [.success(pending)])
    config.processingPollLimit = 3
    let engine = VideoMultipartUpload(transport: poller, store: processing.store, configuration: config)
    do { _ = try await run(engine, fixture: processing); throw CheckFailure("forever-processing should time out") }
    catch VideoMultipartError.processingTimedOut {}
    try check(await poller.polledJobs.count == 2, "initial processing status counts toward finite budget")
    try check(try await processing.store.load(owner: owner)?.completedJobID == "canonical", "processing identity saved for retry")
    await poller.replaceJobs([.success(try job("canonical", state: "JOB_STATE_COMPLETED", blob: blob))])
    let resume = VideoMultipartUpload(transport: poller, store: try VideoUploadCheckpointStore(rootURL: processing.root), configuration: config)
    _ = try await run(resume, fixture: processing)
    try check(await [poller.startCount, poller.statusCount] == [1, 1], "reopened processing checkpoint resumes polling without reupload")
    try retained(processing)
  }

  static func terminalProcessingFailureAndOwnerMismatch() async throws {
    for supplied in [try job("canonical", state: "JOB_STATE_FAILED", code: "pds_upload_unsupported_blob_size"),
                     try job("canonical", state: "JOB_STATE_COMPLETED")] {
      let fixture = try Self.fixture()
      let transport = ScriptedVideoTransport(statuses: [.success(status("created", received: [1, 2, 3]))],
                                            finishes: [.success(.init(completedJobId: "canonical", jobStatus: supplied))])
      do {
        _ = try await run(VideoMultipartUpload(transport: transport, store: fixture.store, configuration: configuration()), fixture: fixture)
        throw CheckFailure("terminal processing error should be returned")
      } catch VideoMultipartError.processingFailed(let code, _) {
        try check(code == supplied.failureCode, "structured delayed failure code survives")
      }
      try check(await [transport.statusCount, transport.finishCount] == [1, 1], "processing error must not be swallowed as finish ambiguity")
      try retained(fixture)
    }
    let fixture = try Self.fixture()
    let wrong = try job("canonical", state: "JOB_STATE_COMPLETED", blob: blob, did: "did:plc:bob")
    let transport = ScriptedVideoTransport(statuses: [.success(status("completed", completedID: "canonical", job: wrong))])
    do {
      _ = try await run(VideoMultipartUpload(transport: transport, store: fixture.store, configuration: configuration()), fixture: fixture)
      throw CheckFailure("another account's blob must not return")
    } catch VideoMultipartError.invalidStatus {}
    try retained(fixture)
  }

  static func cancellationAndOwnershipStopCompletion() async throws {
    let fixture = try Self.fixture()
    let started = VideoTestGate()
    let transport = ScriptedVideoTransport(statuses: [.success(status("created"))], onPart: {
      await started.open()
      try await Task.sleep(nanoseconds: 60_000_000_000)
    })
    let engine = VideoMultipartUpload(transport: transport, store: fixture.store, configuration: configuration())
    let operation = Task { try await run(engine, fixture: fixture) }
    await started.wait()
    operation.cancel()
    do { _ = try await operation.value; throw CheckFailure("canceled part returned a blob") }
    catch is CancellationError {}
    try check(await transport.finishCount == 0, "cancellation cannot finalize or publish")
    try check(try await fixture.store.load(owner: owner)?.phase == .abandoned, "intentional cancellation marked abandoned")
    try retained(fixture)

    let switched = try Self.fixture()
    let ownership = OwnerSwitch()
    let changed = ScriptedVideoTransport(statuses: [.success(status("created"))], onPart: { await ownership.invalidate() })
    do {
      _ = try await VideoMultipartUpload(transport: changed, store: switched.store, configuration: configuration()).run(
        sourceURL: switched.source, owner: owner, mimeType: "video/mp4", progress: { _ in }, isOwnerCurrent: { await ownership.current })
      throw CheckFailure("account change returned a blob")
    } catch VideoMultipartError.ownerChanged {}
    try check(await [changed.finishCount, changed.abortCount] == [0, 0], "changed account neither finalizes nor mints cleanup authority")
    try retained(switched)
  }

  static func authorizationOnlyForNewSession() async throws {
    let fixture = try Self.fixture()
    let quota = QuotaRecorder()
    let transport = ScriptedVideoTransport(statuses: [.success(status("created", received: [1, 2, 3]))],
      finishes: [.success(.init(completedJobId: "canonical", jobStatus: try job("canonical", state: "JOB_STATE_COMPLETED", blob: blob)))],
      jobs: [.success(try job("canonical", state: "JOB_STATE_COMPLETED", blob: blob))])
    let engine = VideoMultipartUpload(transport: transport, store: fixture.store, configuration: configuration())
    do {
      _ = try await engine.run(sourceURL: fixture.source, owner: owner, mimeType: "video/mp4", progress: { _ in }, isOwnerCurrent: { true }, authorizeNewSession: {
        await quota.record()
        throw VideoMultipartTransportError(statusCode: 403, code: "UploadForbidden")
      })
      throw CheckFailure("denied allowance created an upload")
    } catch let error as VideoMultipartTransportError { try check(error.code == "UploadForbidden", "grant denial propagated unchanged") }
    try check(await transport.startCount == 0, "denied allowance makes no start request")
    _ = try await engine.run(sourceURL: fixture.source, owner: owner, mimeType: "video/mp4", progress: { _ in }, isOwnerCurrent: { true }, authorizeNewSession: { await quota.record() })
    try check(await quota.count == 2, "fresh session checks existing account allowance")
    _ = try await engine.run(sourceURL: fixture.source, owner: owner, mimeType: "video/mp4", progress: { _ in }, isOwnerCurrent: { true }, authorizeNewSession: {
      throw CheckFailure("processing resume must not ask to reserve new quota")
    })
    try check(await transport.startCount == 1, "completed processing retry does not reserve again")
    try retained(fixture)

    let uploading = try Self.fixture()
    var saved = try await uploading.store.prepare(sourceURL: uploading.source, owner: owner, mimeType: "video/mp4")
    saved.phase = .uploading; saved.uploadJobID = "upload"; saved.partSizeBytes = 4; saved.partCount = 3; saved.expiresAt = expiry
    try await uploading.store.save(saved)
    await uploading.store.release(owner: owner, runID: saved.runID)
    let resumeTransport = ScriptedVideoTransport(statuses: [.success(status("completed", completedID: "canonical", job: try job("canonical", state: "JOB_STATE_COMPLETED", blob: blob)))])
    _ = try await VideoMultipartUpload(transport: resumeTransport, store: uploading.store, configuration: configuration()).run(
      sourceURL: uploading.source, owner: owner, mimeType: "video/mp4", progress: { _ in }, isOwnerCurrent: { true }, authorizeNewSession: {
        throw CheckFailure("upload resume must use existing reservation")
      })
    try check(await resumeTransport.startCount == 0, "uploading resume never allocates another session")
  }

  static func retryBudgetsAndTerminalStates() async throws {
    for errors: [Error] in [[URLError(.timedOut), URLError(.networkConnectionLost)],
                             [VideoMultipartTransportError(statusCode: 400, code: "InvalidPart")]] {
      let fixture = try Self.fixture()
      let transport = ScriptedVideoTransport(statuses: [.success(status("created", received: [2, 3]))])
      await transport.failPart(1, with: errors)
      do {
        _ = try await run(VideoMultipartUpload(transport: transport, store: fixture.store, configuration: configuration()), fixture: fixture)
        throw CheckFailure("part failure exceeded retry contract")
      } catch is URLError {} catch is VideoMultipartTransportError {}
      try check(await transport.parts.count == errors.count, "part retry budget stops; permanent rejection not retried")
      try check(await transport.finishCount == 0, "failed transfer never finalizes")
      try retained(fixture)
    }
    for state in ["expired", "aborted", "failed"] {
      let fixture = try Self.fixture()
      let transport = ScriptedVideoTransport(statuses: [.success(status(state))])
      do {
        _ = try await run(VideoMultipartUpload(transport: transport, store: fixture.store, configuration: configuration()), fixture: fixture)
        throw CheckFailure("terminal session restarted")
      } catch VideoMultipartError.sessionTerminal {}
      try check(await [transport.startCount, transport.statusCount, transport.finishCount] == [1, 1, 0], "terminal session ends without restart")
      try check(try await fixture.store.load(owner: owner)?.phase == .terminal, "terminal state checkpointed")
      try retained(fixture)
    }
    let fixture = try Self.fixture()
    let transport = ScriptedVideoTransport(statuses: [.failure(URLError(.timedOut))])
    var config = configuration(); config.maxConsecutiveStatusFailures = 3
    do {
      _ = try await run(VideoMultipartUpload(transport: transport, store: fixture.store, configuration: config), fixture: fixture)
      throw CheckFailure("status failures never stopped")
    } catch is URLError {}
    try check(await transport.statusCount == 3, "consecutive status transport failures bounded")
    try retained(fixture)
  }

  static func authBeforeDispatchIsNotUncertain() async throws {
    let fixture = try Self.fixture()
    let transport = ScriptedVideoTransport(startFailure: VideoMultipartStartNotSent(
      underlying: VideoMultipartTransportError(statusCode: 403, code: "InsufficientScope")))
    do {
      _ = try await run(VideoMultipartUpload(transport: transport, store: fixture.store, configuration: configuration()), fixture: fixture)
      throw CheckFailure("grant denial should fail")
    } catch let error as VideoMultipartTransportError {
      try check(error.code == "InsufficientScope", "pre-dispatch original grant error preserved")
    }
    try check(try await fixture.store.load(owner: owner)?.phase == .prepared, "no undispatched start is marked uncertain")
    try retained(fixture)
  }

  static func canceledProcessingResumesSameJob() async throws {
    let fixture = try Self.fixture()
    let started = VideoTestGate()
    let transport = ScriptedVideoTransport(
      statuses: [.success(status("completed", completedID: "canonical", job: try job("canonical")))],
      jobs: [.success(try job("canonical", state: "JOB_STATE_COMPLETED", blob: blob))], onJob: {
        await started.open()
        try await Task.sleep(nanoseconds: 60_000_000_000)
      })
    let engine = VideoMultipartUpload(transport: transport, store: fixture.store, configuration: configuration())
    let operation = Task { try await run(engine, fixture: fixture) }
    await started.wait()
    operation.cancel()
    do { _ = try await operation.value; throw CheckFailure("canceled processing returned a blob") }
    catch is CancellationError {}
    let saved = try await fixture.store.load(owner: owner)
    try check(saved?.phase == .processing && saved?.completedJobID == "canonical", "processing cancellation preserves canonical resumable job")
    try check(await transport.abortCount == 0, "local poll cancellation does not claim to cancel server encoding")
    await transport.replaceJobHook(nil)
    let result = try await run(engine, fixture: fixture)
    try check(result == blob, "explicit retry gets same completed job")
    try check(await [transport.startCount, transport.statusCount] == [1, 1], "processing retry allocates no new upload")
    try retained(fixture)
  }

  static func abandonedFinalizationNeverBlindlyRestarts() async throws {
    for completedID: String? in [nil, "canonical"] {
      let fixture = try Self.fixture()
      var saved = try await fixture.store.prepare(sourceURL: fixture.source, owner: owner, mimeType: "video/mp4")
      saved.phase = .abandoned; saved.uploadJobID = "upload"; saved.partSizeBytes = 4; saved.partCount = 3
      saved.expiresAt = expiry; saved.completedJobID = completedID
      try await fixture.store.save(saved)
      await fixture.store.release(owner: owner, runID: saved.runID)
      let ready = try job("canonical", state: "JOB_STATE_COMPLETED", blob: blob)
      let transport = ScriptedVideoTransport(statuses: [.success(status("finishing")),
        .success(status("completed", completedID: "canonical", job: ready))], jobs: [.success(ready)])
      let result = try await VideoMultipartUpload(transport: transport, store: fixture.store, configuration: configuration()).run(
        sourceURL: fixture.source, owner: owner, mimeType: "video/mp4", allowNewSessionAfterTerminal: true,
        progress: { _ in }, isOwnerCurrent: { true }, authorizeNewSession: {
          throw CheckFailure("retry of canceled uncertain-finalization job must reconcile its existing reservation")
        })
      try check(result == blob, "abandoned server-completed result recovered")
      try check(await [transport.startCount, transport.finishCount, transport.parts.count] == [0, 0, 0], "ambiguous abort/finalization retry does not resend or restart")
      try check(await transport.statusCount == (completedID == nil ? 2 : 0), "known canonical completion skips upload status")
      try retained(fixture)
    }
  }

  static func operationDeadlinesEndPolling() async throws {
    for processing in [false, true] {
      let fixture = try Self.fixture()
      let clock = VideoTestClock()
      var config = configuration()
      config.now = { clock.now() }
      config.sleep = { seconds in try Task.checkCancellation(); clock.advance(seconds) }
      config.operationTimeout = processing ? 30 : 1
      config.processingTimeout = 1
      config.finalizationPollLimit = 100
      config.processingPollLimit = 100
      let transport = ScriptedVideoTransport(statuses: [.success(processing
        ? status("completed", completedID: "canonical", job: try job("canonical")) : status("finishing"))])
      do {
        _ = try await run(VideoMultipartUpload(transport: transport, store: fixture.store, configuration: config), fixture: fixture)
        throw CheckFailure("deadline did not end polling")
      } catch VideoMultipartError.transferTimedOut {
        try check(!processing, "transfer deadline only expected before processing")
      } catch VideoMultipartError.processingTimedOut {
        try check(processing, "processing deadline retained stage-specific error")
      }
      try check(await transport.statusCount == 1, "deadline stops before another status request")
      try retained(fixture)
    }
  }

  static func cleanupLeaseBlocksRetryUntilSettled() async throws {
    let fixture = try Self.fixture()
    let saved = try await fixture.store.prepare(sourceURL: fixture.source, owner: owner, mimeType: "video/mp4")
    try check(await fixture.store.beginCleanup(saved), "current operation acquires cleanup lease")
    await fixture.store.release(owner: owner, runID: saved.runID)
    for releaseID in [UUID(), saved.runID] {
      do {
        _ = try await fixture.store.prepare(sourceURL: fixture.source, owner: owner, mimeType: "video/mp4")
        throw CheckFailure("retry raced an in-flight abort")
      } catch VideoUploadFileError.uploadAlreadyActive {}
      await fixture.store.finishCleanup(owner: owner, runID: releaseID)
    }
    let resumed = try await fixture.store.prepare(sourceURL: fixture.source, owner: owner, mimeType: "video/mp4")
    try check(resumed.operationID == saved.operationID && resumed.runID != saved.runID, "retry proceeds only after matching cleanup settles")
    try check(!(await fixture.store.beginCleanup(saved)), "stale cleanup cannot reacquire against resumed run")
    await fixture.store.release(owner: owner, runID: resumed.runID)
    try retained(fixture)
  }

  static func suspendedAbortBlocksCompetingEngine() async throws {
    let fixture = try Self.fixture()
    let partEntered = VideoTestGate()
    let abortEntered = VideoTestGate()
    let abortRelease = VideoTestGate()
    let transport = ScriptedVideoTransport(statuses: [.success(status("created"))],
      jobs: [.success(try job("canonical", state: "JOB_STATE_COMPLETED", blob: blob))],
      onPart: {
        await partEntered.open()
        try await Task.sleep(nanoseconds: 60_000_000_000)
      }, onAbort: {
        await abortEntered.open()
        await abortRelease.wait()
      }, abortResult: .init(state: "completed", completedJobId: "canonical"))
    let original = VideoMultipartUpload(transport: transport, store: fixture.store, configuration: configuration())
    let operation = Task { try await run(original, fixture: fixture) }
    await partEntered.wait()
    operation.cancel()
    do { _ = try await operation.value; throw CheckFailure("canceled original returned") }
    catch is CancellationError {}
    await abortEntered.wait()
    let partsBefore = await transport.parts.count
    let replacement = VideoMultipartUpload(transport: transport, store: fixture.store, configuration: configuration())
    do {
      _ = try await run(replacement, fixture: fixture)
      throw CheckFailure("replacement started while actual engine abort suspended")
    } catch VideoUploadFileError.uploadAlreadyActive {}
    try check(await transport.parts.count == partsBefore, "blocked replacement sends no parts")
    try check(await transport.startCount == 1, "blocked replacement never creates another reservation")
    await abortRelease.open()
    // Observe the asynchronous cleanup's actual release, bounded independently of the fake clock.
    var result: Blob?
    for _ in 0..<200 {
      do { result = try await run(replacement, fixture: fixture); break }
      catch VideoUploadFileError.uploadAlreadyActive { try await Task.sleep(nanoseconds: 1_000_000) }
    }
    try check(result == blob, "replacement resumes only after suspended abort completes and lease releases")
    try check(await [transport.startCount, transport.abortCount, transport.parts.count] == [1, 1, partsBefore], "abort completion race recovers canonical blob without reupload")
    try retained(fixture)
  }

  struct Fixture: Sendable { let source: URL; let root: URL; let store: VideoUploadCheckpointStore }
  static func fixture() throws -> Fixture {
    let source = try VideoMultipartTransportChecks.fixtureFile(Data(0..<10))
    let root = source.deletingLastPathComponent().appendingPathComponent("checkpoints")
    return Fixture(source: source, root: root, store: try VideoUploadCheckpointStore(rootURL: root))
  }
  static func configuration() -> VideoMultipartConfiguration {
    var value = VideoMultipartConfiguration()
    value.workerCount = 1
    value.partAttempts = 2
    value.finalizationPollLimit = 5
    value.processingPollLimit = 5
    value.now = { Date(timeIntervalSince1970: 1000) }
    value.sleep = { _ in try Task.checkCancellation() }
    return value
  }
  static func status(_ state: String, received: [Int] = [], completedID: String? = nil, job: AppBskyVideoDefs.JobStatus? = nil) -> AppBskyVideoGetUploadStatus.Output {
    .init(jobId: "upload", partSizeBytes: 4, partCount: 3, receivedParts: received,
          expiresAt: ATProtocolDate(date: expiry), state: state, completedJobId: completedID, jobStatus: job)
  }
  static func job(_ id: String, state: String = "JOB_STATE_PROCESSING", blob: Blob? = nil, code: String? = nil, did: String = "did:plc:alice") throws -> AppBskyVideoDefs.JobStatus {
    .init(jobId: id, did: try DID(didString: did), state: state, progress: 20, blob: blob, failureCode: code)
  }
  static func run(_ engine: VideoMultipartUpload, fixture: Fixture, progress: @escaping @Sendable (VideoMultipartProgress) async -> Void = { _ in }) async throws -> Blob {
    try await engine.run(sourceURL: fixture.source, owner: owner, mimeType: "video/mp4", progress: progress, isOwnerCurrent: { true })
  }
  static func retained(_ fixture: Fixture) throws {
    try check(try Data(contentsOf: fixture.source) == Data(0..<10), "original source preserved byte for byte")
  }
  static func check(_ condition: Bool, _ message: String) throws { try VideoMultipartTransportChecks.verify(condition, message) }
}

actor ProgressRecorder {
  private(set) var values: [VideoMultipartProgress] = []
  func add(_ value: VideoMultipartProgress) { values.append(value) }
}
actor MultipartConcurrencyProbe {
  private var active = 0
  private var arrivals = 0
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private(set) var maximum = 0
  func enter() async {
    active += 1
    arrivals += 1
    maximum = max(maximum, active)
    if arrivals == 4 { releaseAll() }
    if !isOpen { await withCheckedContinuation { waiters.append($0) } }
  }
  func leave() { active -= 1 }
  func releaseAll() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    pending.forEach { $0.resume() }
  }
}
actor OwnerSwitch {
  private(set) var current = true
  func invalidate() { current = false }
}
actor QuotaRecorder {
  private(set) var count = 0
  func record() { count += 1 }
}
final class VideoTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 1000)
  func now() -> Date { lock.withLock { value } }
  func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

actor ScriptedVideoTransport: VideoMultipartTransporting {
  struct SentPart: Sendable { let number: Int; let bytes: Data }
  private var statuses: [Result<AppBskyVideoGetUploadStatus.Output, Error>]
  private var finishes: [Result<AppBskyVideoFinishUpload.Output, Error>]
  private var jobs: [Result<AppBskyVideoDefs.JobStatus, Error>]
  private let startFailure: Error?
  private var partFailures: [Int: [Error]] = [:]
  private let onPart: (@Sendable () async throws -> Void)?
  private var onJob: (@Sendable () async throws -> Void)?
  private let onAbort: (@Sendable () async throws -> Void)?
  private let abortResult: AppBskyVideoAbortUpload.Output
  private let partCount: Int
  private(set) var startCount = 0
  private(set) var statusCount = 0
  private(set) var finishCount = 0
  private(set) var abortCount = 0
  private(set) var polledJobs: [String] = []
  private(set) var parts: [SentPart] = []
  init(statuses: [Result<AppBskyVideoGetUploadStatus.Output, Error>] = [],
       finishes: [Result<AppBskyVideoFinishUpload.Output, Error>] = [],
       jobs: [Result<AppBskyVideoDefs.JobStatus, Error>] = [], startFailure: Error? = nil,
       onPart: (@Sendable () async throws -> Void)? = nil,
       onJob: (@Sendable () async throws -> Void)? = nil,
       onAbort: (@Sendable () async throws -> Void)? = nil,
       abortResult: AppBskyVideoAbortUpload.Output = .init(state: "aborted"), partCount: Int = 3) {
    self.statuses = statuses; self.finishes = finishes; self.jobs = jobs
    self.startFailure = startFailure; self.onPart = onPart; self.onJob = onJob
    self.onAbort = onAbort; self.abortResult = abortResult
    self.partCount = partCount
  }
  func failPart(_ number: Int, with errors: [Error]) { partFailures[number] = errors }
  func replaceJobs(_ values: [Result<AppBskyVideoDefs.JobStatus, Error>]) { jobs = values }
  func replaceJobHook(_ hook: (@Sendable () async throws -> Void)?) { onJob = hook }
  func start(input: AppBskyVideoStartUpload.Input) async throws -> AppBskyVideoStartUpload.Output {
    startCount += 1
    if let startFailure { throw startFailure }
    return .init(jobId: "upload", partSizeBytes: 4, partCount: partCount, expiresAt: ATProtocolDate(date: VideoMultipartUploadChecks.expiry))
  }
  func uploadPart(jobID: String, partNumber: Int, fileURL: URL, byteCount: Int, onProgress: (@Sendable (Int64) -> Void)?) async throws -> AppBskyVideoUploadPart.Output {
    let bytes = try Data(contentsOf: fileURL)
    parts.append(SentPart(number: partNumber, bytes: bytes))
    try await onPart?()
    if partFailures[partNumber]?.isEmpty == false { throw partFailures[partNumber]!.removeFirst() }
    return .init(partNumber: partNumber, sizeBytes: bytes.count)
  }
  func status(jobID: String) async throws -> AppBskyVideoGetUploadStatus.Output {
    statusCount += 1
    guard let first = statuses.first else { throw CheckFailure("Unexpected upload status request") }
    if statuses.count > 1 { statuses.removeFirst() }
    return try first.get()
  }
  func finish(jobID: String) async throws -> AppBskyVideoFinishUpload.Output {
    finishCount += 1
    guard !finishes.isEmpty else { throw CheckFailure("Unexpected finish request") }
    return try finishes.removeFirst().get()
  }
  func abort(jobID: String) async throws -> AppBskyVideoAbortUpload.Output {
    abortCount += 1
    try await onAbort?()
    return abortResult
  }
  func jobStatus(jobID: String) async throws -> AppBskyVideoDefs.JobStatus {
    polledJobs.append(jobID)
    try await onJob?()
    guard let first = jobs.first else { throw CheckFailure("Unexpected processing request") }
    if jobs.count > 1 { jobs.removeFirst() }
    return try first.get()
  }
}

#if !MULTIPART_HARNESS
@Suite("Multipart video recovery")
struct VideoMultipartUploadTests {
  @Test func fourWorkersAndExactBytes() async throws { try await VideoMultipartUploadChecks.fourWorkersStayBoundedAndSendExactBytes() }
  @Test func planBounds() throws { try VideoMultipartUploadChecks.partBounds() }
  @Test func checkpointOwnership() async throws { try await VideoMultipartUploadChecks.checkpointOwnershipAndSource() }
  @Test func retryAndCanonicalID() async throws { try await VideoMultipartUploadChecks.retryPartsAndCanonicalProcessing() }
  @Test func ambiguousFinish() async throws { try await VideoMultipartUploadChecks.missingPartsAndLostFinish() }
  @Test func ambiguousStart() async throws { try await VideoMultipartUploadChecks.uncertainStartRequiresExplicitRetry() }
  @Test func boundedResume() async throws { try await VideoMultipartUploadChecks.boundedFinalizationAndProcessingResume() }
  @Test func processingErrors() async throws { try await VideoMultipartUploadChecks.terminalProcessingFailureAndOwnerMismatch() }
  @Test func cancelAndOwnership() async throws { try await VideoMultipartUploadChecks.cancellationAndOwnershipStopCompletion() }
  @Test func existingReservationNeedsNoNewQuota() async throws { try await VideoMultipartUploadChecks.authorizationOnlyForNewSession() }
  @Test func retryAndTerminalBudgets() async throws { try await VideoMultipartUploadChecks.retryBudgetsAndTerminalStates() }
  @Test func undispatchedAuthFailure() async throws { try await VideoMultipartUploadChecks.authBeforeDispatchIsNotUncertain() }
  @Test func processingCancellationResume() async throws { try await VideoMultipartUploadChecks.canceledProcessingResumesSameJob() }
  @Test func abandonedFinalizationResume() async throws { try await VideoMultipartUploadChecks.abandonedFinalizationNeverBlindlyRestarts() }
  @Test func operationAndProcessingDeadlines() async throws { try await VideoMultipartUploadChecks.operationDeadlinesEndPolling() }
  @Test func cleanupBlocksConcurrentRetry() async throws { try await VideoMultipartUploadChecks.cleanupLeaseBlocksRetryUntilSettled() }
  @Test func suspendedAbortBlocksActualReplacement() async throws { try await VideoMultipartUploadChecks.suspendedAbortBlocksCompetingEngine() }
}
#endif
