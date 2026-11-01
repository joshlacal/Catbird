import Foundation
import Petrel
import Testing
@testable import Catbird

/// A checkpoint snapshot is a full copy of the uploaded video. Snapshots made before uploads were
/// sanitized are raw clones of the attachment, with its location and device metadata. These
/// checks pin down when the store deletes them.
@Suite("Video upload checkpoint snapshot retention")
struct VideoUploadCheckpointRetentionTests {
  private let owner = VideoMultipartUploadChecks.owner

  // MARK: - Rule

  @Test("Only an unfinished, unexpired upload session keeps its snapshot")
  func retentionRule() {
    let now = Date(timeIntervalSince1970: 1_000)
    var session = VideoUploadCheckpoint(
      operationID: UUID(), runID: UUID(), owner: owner, snapshotName: "snapshot.video",
      sha256: String(repeating: "0", count: 64), sizeBytes: 10, mimeType: "video/mp4", phase: .uploading,
      uploadJobID: "upload", expiresAt: now.addingTimeInterval(60)
    )
    for phase in [VideoUploadCheckpoint.Phase.uploading, .finishing, .abandoned] {
      session.phase = phase
      #expect(VideoUploadCheckpointStore.keepsSnapshot(session, at: now), "\(phase)")
    }
    for phase in [VideoUploadCheckpoint.Phase.prepared, .starting, .startUncertain, .processing, .complete, .terminal] {
      session.phase = phase
      #expect(!VideoUploadCheckpointStore.keepsSnapshot(session, at: now), "\(phase)")
    }
    session.phase = .uploading
    var expired = session
    expired.expiresAt = now
    var finished = session
    finished.completedJobID = "canonical"
    var unstarted = session
    unstarted.uploadJobID = nil
    var undated = session
    undated.expiresAt = nil
    for checkpoint in [expired, finished, unstarted, undated] {
      #expect(!VideoUploadCheckpointStore.keepsSnapshot(checkpoint, at: now))
    }
  }

  @Test("The store's folder is excluded from device backups")
  func rootIsExcludedFromBackup() throws {
    let folder = try Folder()
    _ = try VideoUploadCheckpointStore(rootURL: folder.root)
    var root = folder.root
    root.removeAllCachedResourceValues()
    #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
  }

  // MARK: - Lease End

  @Test("A completed checkpoint's snapshot is deleted at lease end and cloned again for a retry")
  func completedSnapshotIsRestoredForRetry() async throws {
    let folder = try Folder()
    let store = try VideoUploadCheckpointStore(rootURL: folder.root)
    let prepared = try await store.prepare(sourceURL: folder.source, owner: owner, mimeType: "video/mp4")
    var complete = try await startSession(prepared, store: store)
    complete.completedJobID = "canonical"
    complete.phase = .complete
    try await store.save(complete)
    #expect(files("video", in: folder.root).count == 1, "the run's lease keeps its snapshot")
    await store.release(owner: owner, runID: complete.runID)
    #expect(files("video", in: folder.root).isEmpty)
    #expect(try await store.load(owner: owner)?.phase == .complete, "the checkpoint record is kept")

    let retry = try await store.prepare(sourceURL: folder.source, owner: owner, mimeType: "video/mp4")
    #expect(retry.operationID == prepared.operationID && retry.completedJobID == "canonical")
    let restored = try #require(files("video", in: folder.root).first)
    #expect(restored.lastPathComponent == prepared.snapshotName)
    #expect(try Data(contentsOf: restored) == Data(0..<10))
    let part = try await store.makePart(checkpoint: retry, partNumber: 1, offset: 0, count: 4)
    #expect(try Data(contentsOf: part) == Data(0..<4))
    await store.release(owner: owner, runID: retry.runID)
    #expect(files("video", in: folder.root).isEmpty)
    #expect(files("part", in: folder.root).isEmpty)
  }

  @Test("A resumable session keeps its snapshot across release and reopen until it expires")
  func liveSessionKeepsSnapshotUntilExpiry() async throws {
    let folder = try Folder()
    let store = try VideoUploadCheckpointStore(rootURL: folder.root)
    let prepared = try await store.prepare(sourceURL: folder.source, owner: owner, mimeType: "video/mp4")
    let session = try await startSession(prepared, store: store, phase: .abandoned)
    await store.release(owner: owner, runID: session.runID)
    #expect(files("video", in: folder.root).map(\.lastPathComponent) == [prepared.snapshotName])

    let reopened = try VideoUploadCheckpointStore(rootURL: folder.root)
    #expect(files("video", in: folder.root).map(\.lastPathComponent) == [prepared.snapshotName],
            "opening a store keeps a resumable snapshot")
    let resumed = try await reopened.prepare(sourceURL: folder.source, owner: owner, mimeType: "video/mp4")
    #expect(resumed.operationID == prepared.operationID && resumed.uploadJobID == "upload")
    var expired = resumed
    expired.expiresAt = Date(timeIntervalSinceNow: -60)
    try await reopened.save(expired)
    await reopened.release(owner: owner, runID: expired.runID)
    #expect(files("video", in: folder.root).isEmpty, "an expired session can take no more parts")
  }

  @Test("Neither a stale release nor a pending cleanup removes a snapshot in use")
  func leasesProtectSnapshot() async throws {
    let folder = try Folder()
    let store = try VideoUploadCheckpointStore(rootURL: folder.root)
    let prepared = try await store.prepare(sourceURL: folder.source, owner: owner, mimeType: "video/mp4")
    await store.release(owner: owner, runID: UUID())
    #expect(files("video", in: folder.root).count == 1, "a stale release leaves the current run's snapshot")
    _ = try await store.makePart(checkpoint: prepared, partNumber: 1, offset: 0, count: 4)
    #expect(await store.beginCleanup(prepared))
    await store.release(owner: owner, runID: prepared.runID)
    #expect(files("video", in: folder.root).count == 1, "an abort in flight still holds the owner")
    await store.finishCleanup(owner: owner, runID: prepared.runID)
    #expect(files("video", in: folder.root).isEmpty)
    #expect(files("part", in: folder.root).isEmpty)
  }

  @Test("Changed bytes replace a resumable session and delete its snapshot")
  func replacementDeletesSupersededSnapshot() async throws {
    let folder = try Folder()
    let store = try VideoUploadCheckpointStore(rootURL: folder.root)
    let prepared = try await store.prepare(sourceURL: folder.source, owner: owner, mimeType: "video/mp4")
    let session = try await startSession(prepared, store: store)
    await store.release(owner: owner, runID: session.runID)
    #expect(files("video", in: folder.root).count == 1)

    try Data(repeating: 7, count: 12).write(to: folder.source)
    let replacement = try await store.prepare(
      sourceURL: folder.source, owner: owner, mimeType: "video/mp4", allowReplacementSource: true)
    #expect(replacement.operationID != prepared.operationID && replacement.uploadJobID == nil)
    let snapshots = files("video", in: folder.root)
    #expect(snapshots.map(\.lastPathComponent) == [replacement.snapshotName])
    #expect(try Data(contentsOf: try #require(snapshots.first)) == Data(repeating: 7, count: 12))
    #expect(files("json", in: folder.root).contains { $0.lastPathComponent == "\(prepared.operationID.uuidString).json" },
            "the replaced reservation stays in history")
    await store.release(owner: owner, runID: replacement.runID)
  }

  // MARK: - Opening a Store

  @Test("Opening a store deletes unreferenced snapshots and every part, and keeps checkpoint records")
  func openingSweepsOrphans() async throws {
    let folder = try Folder()
    let store = try VideoUploadCheckpointStore(rootURL: folder.root)
    let prepared = try await store.prepare(sourceURL: folder.source, owner: owner, mimeType: "video/mp4")
    let session = try await startSession(prepared, store: store)
    _ = try await store.makePart(checkpoint: session, partNumber: 1, offset: 0, count: 4)
    // The app is killed mid-upload, so its lease is never released, beside leftovers of older
    // builds: a superseded raw clone, and a folder with no checkpoint at all.
    let checkpointFile = try #require(files("json", in: folder.root).first { $0.lastPathComponent == "checkpoint.json" })
    let directory = checkpointFile.deletingLastPathComponent()
    let superseded = directory.appendingPathComponent("\(UUID().uuidString).video")
    try Data("raw clone".utf8).write(to: superseded)
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: superseded.path)
    let unowned = folder.root.appendingPathComponent(String(repeating: "a", count: 64), isDirectory: true)
    try FileManager.default.createDirectory(at: unowned, withIntermediateDirectories: true)
    try Data("raw clone".utf8).write(to: unowned.appendingPathComponent("\(UUID().uuidString).video"))
    let unrelated = folder.root.appendingPathComponent("unrelated.txt")
    try Data("keep".utf8).write(to: unrelated)

    let relaunched = try VideoUploadCheckpointStore(rootURL: folder.root)
    #expect(files("video", in: folder.root).map(\.lastPathComponent) == [prepared.snapshotName])
    #expect(files("part", in: folder.root).isEmpty)
    #expect(FileManager.default.fileExists(atPath: checkpointFile.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
    #expect(try await relaunched.load(owner: owner)?.uploadJobID == "upload")
  }

  @Test("The first open of a root from an older build deletes every snapshot, even a resumable one")
  func firstOpenPurgesOlderSnapshots() async throws {
    let folder = try Folder()
    let store = try VideoUploadCheckpointStore(rootURL: folder.root)
    let marker = folder.root.appendingPathComponent(VideoUploadCheckpointStore.sanitizedSnapshotsMarker)
    #expect(FileManager.default.fileExists(atPath: marker.path))
    let prepared = try await store.prepare(sourceURL: folder.source, owner: owner, mimeType: "video/mp4")
    let session = try await startSession(prepared, store: store, phase: .abandoned)
    await store.release(owner: owner, runID: session.runID)
    #expect(files("video", in: folder.root).count == 1)

    // An older build wrote this root: no marker, and its snapshot may be a raw attachment clone.
    try FileManager.default.removeItem(at: marker)
    let upgraded = try VideoUploadCheckpointStore(rootURL: folder.root)
    #expect(files("video", in: folder.root).isEmpty)
    #expect(FileManager.default.fileExists(atPath: marker.path))

    // The sanitized copy's bytes differ from the raw clone's: a new session and snapshot.
    try Data(repeating: 3, count: 10).write(to: folder.source)
    let sanitized = try await upgraded.prepare(
      sourceURL: folder.source, owner: owner, mimeType: "video/mp4", allowReplacementSource: true)
    #expect(sanitized.operationID != prepared.operationID && sanitized.phase == .prepared)
    #expect(files("video", in: folder.root).map(\.lastPathComponent) == [sanitized.snapshotName])
    await upgraded.release(owner: owner, runID: sanitized.runID)
  }

  @Test("The launch open runs the shared store's sweep and excludes its folder from backups")
  func launchOpensSharedStore() async throws {
    await VideoUploadCheckpointStore.openSharedInBackground().value
    _ = try VideoUploadCheckpointStore.shared.get()
    var root = try VideoUploadCheckpointStore.defaultRootURL()
    root.removeAllCachedResourceValues()
    #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    #expect(FileManager.default.fileExists(
      atPath: root.appendingPathComponent(VideoUploadCheckpointStore.sanitizedSnapshotsMarker).path))
  }

  // MARK: - Through the Engine

  @Test("A completed upload keeps no snapshot, and a post retry reuses the finished job without sending bytes")
  func completedUploadRetryReusesJob() async throws {
    let fixture = try VideoMultipartUploadChecks.fixture()
    let blob = VideoMultipartUploadChecks.blob
    let completed = try VideoMultipartUploadChecks.job("canonical", state: "JOB_STATE_COMPLETED", blob: blob)
    let transport = ScriptedVideoTransport(
      statuses: [.success(VideoMultipartUploadChecks.status("created"))],
      finishes: [.success(.init(completedJobId: "canonical", jobStatus: completed))],
      jobs: [.success(completed)]
    )
    let engine = VideoMultipartUpload(
      transport: transport, store: fixture.store, configuration: VideoMultipartUploadChecks.configuration())
    #expect(try await VideoMultipartUploadChecks.run(engine, fixture: fixture) == blob)
    #expect(files("video", in: fixture.root).isEmpty)
    #expect(files("part", in: fixture.root).isEmpty)

    #expect(try await VideoMultipartUploadChecks.run(engine, fixture: fixture) == blob)
    #expect(await transport.startCount == 1)
    #expect(await transport.parts.count == 3)
    #expect(await transport.polledJobs == ["canonical"])
    #expect(files("video", in: fixture.root).isEmpty)
    #expect(try Data(contentsOf: fixture.source) == Data(0..<10))
  }

  @Test("A failed session drops its snapshot, and a new submit clones it again for a new session")
  func terminalSessionRetryClonesSnapshot() async throws {
    let fixture = try VideoMultipartUploadChecks.fixture()
    let blob = VideoMultipartUploadChecks.blob
    let transport = ScriptedVideoTransport(
      statuses: [.success(VideoMultipartUploadChecks.status("expired")),
                 .success(VideoMultipartUploadChecks.status("created"))],
      finishes: [.success(.init(completedJobId: "canonical",
        jobStatus: try VideoMultipartUploadChecks.job("canonical", state: "JOB_STATE_COMPLETED", blob: blob)))]
    )
    let engine = VideoMultipartUpload(
      transport: transport, store: fixture.store, configuration: VideoMultipartUploadChecks.configuration())
    await #expect(throws: VideoMultipartError.self) {
      _ = try await VideoMultipartUploadChecks.run(engine, fixture: fixture)
    }
    #expect(try await fixture.store.load(owner: owner)?.phase == .terminal)
    #expect(files("video", in: fixture.root).isEmpty)

    let result = try await engine.run(
      attachmentURL: fixture.source, copies: SyntheticVideoCopies.mp4, owner: owner,
      allowNewSessionAfterTerminal: true, progress: { _ in }, isOwnerCurrent: { true })
    #expect(result == blob)
    #expect(await transport.startCount == 2)
    #expect(await transport.parts.map(\.bytes).reduce(into: Data()) { $0.append($1) } == Data(0..<10))
    #expect(files("video", in: fixture.root).isEmpty)
  }

  // MARK: - Helpers

  /// A new temporary folder with a 10-byte source and a store root that does not exist yet.
  private struct Folder {
    let source: URL
    let root: URL

    init() throws {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("checkpoint-retention-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      source = url.appendingPathComponent("source.mp4")
      try Data(0..<10).write(to: source)
      root = url.appendingPathComponent("checkpoints", isDirectory: true)
    }
  }

  /// Records a server session for `checkpoint` the way the engine does after a start.
  private func startSession(
    _ checkpoint: VideoUploadCheckpoint, store: VideoUploadCheckpointStore,
    phase: VideoUploadCheckpoint.Phase = .uploading
  ) async throws -> VideoUploadCheckpoint {
    var session = checkpoint
    session.phase = phase
    session.uploadJobID = "upload"
    session.partSizeBytes = 4
    session.partCount = 3
    session.expiresAt = .distantFuture
    try await store.save(session)
    return session
  }

  private func files(_ pathExtension: String, in root: URL) -> [URL] {
    let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects ?? []
    return all.compactMap { $0 as? URL }.filter { $0.pathExtension == pathExtension }
  }
}
