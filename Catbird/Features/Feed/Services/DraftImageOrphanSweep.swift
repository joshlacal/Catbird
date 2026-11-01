//
//  DraftImageOrphanSweep.swift
//  Catbird
//
//  Removes draft photo files that nothing names and nothing has used for a week.
//

import Foundation
import OSLog

// MARK: - Gate

/// Whether a sweep may start now. Pure, so every rule can be checked on its own.
enum DraftImageOrphanSweepGate {
  enum Refusal: String, Equatable, Sendable {
    /// A sweep started less than a day ago.
    case notDue
    /// Saved drafts live in an in-memory store (safe mode), so the rows that name photos are not
    /// all present.
    case storeNotDurable
    /// The app is in the foreground. The sweep reads every draft store on the main actor, so it
    /// runs only in the background.
    case appInForeground
    /// A Bluesky draft sync is running and may import a draft that names a file.
    case draftSyncRunning
    /// Draft sync is on and has not completed a pass for this account in this launch, so a
    /// Bluesky draft that names a file on this device may not have been imported yet.
    case draftSyncNotCompleted
    /// The draft photo folder cannot be found.
    case folderUnavailable
  }

  /// A last start this far in the future came from a clock that was set ahead. It does not count,
  /// so one run on a wrong clock cannot block the sweep until that date.
  static let maximumClockSkew: TimeInterval = 3_600

  static func refusal(
    storeIsDurable: Bool,
    isInBackground: Bool,
    syncEnabled: Bool,
    syncRunning: Bool,
    syncCompletedThisLaunch: Bool,
    lastStartedAt: Date?,
    now: Date
  ) -> Refusal? {
    if let lastStartedAt {
      let elapsed = now.timeIntervalSince(lastStartedAt)
      if elapsed < DraftImageOrphanSweep.minimumInterval && elapsed >= -maximumClockSkew {
        return .notDue
      }
    }
    guard storeIsDurable else { return .storeNotDurable }
    guard isInBackground else { return .appInForeground }
    guard !syncRunning else { return .draftSyncRunning }
    guard !syncEnabled || syncCompletedThisLaunch else { return .draftSyncNotCompleted }
    return nil
  }
}

// MARK: - Sweep

/// Removes managed draft photos (`draft_image_<sha256>.jpg` directly in the SharedDrafts folder)
/// that nothing names and nothing has used for `minimumUnusedAge`, oldest first, in batches of
/// `batchSize`. It reclaims what composition-end cleanup cannot: files left by earlier versions,
/// files a composition reused by content hash, and a deleted draft's own photos.
///
/// Each batch runs DraftImageFileJanitor's reference check and unlink in one main-actor turn and
/// re-reads every file's modification date right before its unlink; CodableMediaItem
/// .writeImageData refreshes that date whenever it reuses a file. Between batches the sweep stops
/// when its task is cancelled (background time ran out), when `interruption` names a reason (a
/// draft sync started, the app came back to the foreground), or when a store cannot be read.
///
/// Files first written before the newest store quarantine or reset are never taken: the rows that
/// named them may still come back, from the quarantined store or as Bluesky drafts re-imported
/// into the new store, and the app cannot read either ahead of time.
@MainActor
struct DraftImageOrphanSweep {
  nonisolated static let minimumUnusedAge: TimeInterval = 7 * 86_400
  nonisolated static let minimumInterval: TimeInterval = 86_400
  nonisolated static let batchSize = 32
  /// Seconds since 1970 of the last start, in the defaults that hold the recovery envelopes.
  nonisolated static let lastStartedKey = "draftImageOrphanSweep.lastStartedAt"

  struct Report: Equatable, Sendable {
    var removed = 0
    var keptNamed = 0
    var skippedByDate = 0
    var removedBytes: Int64 = 0
    var stopReason: StopReason?
  }

  enum StopReason: String, Equatable, Sendable {
    case cancelled
    case draftSyncStarted
    case returnedToForeground
    case storeUnreadable
    case folderUnreadable
    case quarantineUnreadable
  }

  enum Result: Equatable, Sendable {
    case refused(DraftImageOrphanSweepGate.Refusal)
    case finished(Report)
  }

  /// The files a run will consider, oldest first, and the modification dates it may remove.
  struct Discovery: Equatable, Sendable {
    var candidates: [URL]
    var eligible: Range<Date>?
    var createdAfter: Date? = nil
  }

  enum DiscoveryError: Error, Equatable {
    case folderUnreadable
    case quarantineUnreadable
  }

  /// The SharedDrafts folder.
  let directory: URL
  /// Where quarantined stores are set aside (CatbirdSwiftDataStore.quarantineDirectory).
  let quarantineDirectory: URL?
  /// When the store last lost rows: reset, quarantined or stripped of its write-ahead log
  /// (CatbirdSwiftDataStore.lastStoreResetDate).
  let storeResetDate: Date?
  var minimumUnusedAge: TimeInterval = Self.minimumUnusedAge
  var batchSize: Int = Self.batchSize
  /// A janitor over every draft store, built for each batch.
  let janitor: @MainActor () -> DraftImageFileJanitor
  /// Why the sweep must stop before its next batch, if it must.
  let interruption: @MainActor () -> StopReason?

  private static let logger = Logger(subsystem: "blue.catbird", category: "DraftImageOrphanSweep")

  func run(now: Date = Date()) async -> Report {
    var report = Report()
    let directory = directory, quarantineDirectory = quarantineDirectory
    let storeResetDate = storeResetDate, minimumUnusedAge = minimumUnusedAge
    let discovery: Discovery
    do {
      discovery = try await Task.detached(priority: .utility) {
        try Self.discover(
          directory: directory, quarantineDirectory: quarantineDirectory,
          storeResetDate: storeResetDate, now: now, minimumUnusedAge: minimumUnusedAge
        )
      }.value
    } catch DiscoveryError.quarantineUnreadable {
      report.stopReason = .quarantineUnreadable
      Self.log(report)
      return report
    } catch {
      report.stopReason = .folderUnreadable
      Self.log(report)
      return report
    }

    let batchSize = max(1, batchSize)
    var start = discovery.candidates.startIndex
    while start < discovery.candidates.endIndex {
      if Task.isCancelled {
        report.stopReason = .cancelled
        break
      }
      if let reason = interruption() {
        report.stopReason = reason
        break
      }
      let end = min(start + batchSize, discovery.candidates.endIndex)
      let batch = Set(discovery.candidates[start..<end].map(\.absoluteString))
      let outcome = janitor().removeUnreferenced(
        batch, eligibleModificationDates: discovery.eligible, createdAfter: discovery.createdAfter
      )
      if outcome.cancelled {
        report.stopReason = .storeUnreadable
        break
      }
      report.removed += outcome.removed.count
      report.keptNamed += outcome.kept.count
      report.skippedByDate += outcome.skippedByDate.count
      report.removedBytes += outcome.removedBytes
      start = end
      await Task.yield()
    }
    Self.log(report)
    return report
  }

  /// Lists the managed files directly in `directory` last modified at least `minimumUnusedAge`
  /// before `now`, first written after the newest quarantine or store reset. Birth provenance
  /// is separate from inactivity: reusing a hash refreshes mtime without releasing protection
  /// for the original lost row. Unknown birth dates stay protected whenever a fence exists.
  /// A missing folder has nothing to list; one that cannot be read throws.
  nonisolated static func discover(
    directory: URL,
    quarantineDirectory: URL?,
    storeResetDate: Date?,
    now: Date,
    minimumUnusedAge: TimeInterval
  ) throws -> Discovery {
    let fileManager = FileManager.default
    let fence = [try newestQuarantineDate(in: quarantineDirectory, fileManager: fileManager), storeResetDate]
      .compactMap { $0 }.max()
    let upper = now.addingTimeInterval(-minimumUnusedAge)
    let lower = fence ?? .distantPast
    guard lower < upper else { return Discovery(candidates: [], eligible: nil) }
    let eligible = lower..<upper

    let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]
    let entries: [URL]
    do {
      entries = try fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
      )
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
      return Discovery(candidates: [], eligible: eligible)
    } catch {
      throw DiscoveryError.folderUnreadable
    }

    var dated: [(url: URL, modified: Date)] = []
    for url in entries where DraftImageFileJanitor.isManagedFileName(url.lastPathComponent) {
      guard let values = try? url.resourceValues(forKeys: Set(keys)),
            values.isRegularFile == true,
            let modified = values.contentModificationDate,
            eligible.contains(modified) else { continue }
      if let fence {
        guard let created = values.creationDate, created > fence else { continue }
      }
      dated.append((url, modified))
    }
    dated.sort { $0.modified < $1.modified }
    return Discovery(candidates: dated.map(\.url), eligible: eligible, createdAfter: fence)
  }

  /// The creation date of the newest quarantined store, or nil when there is none.
  private nonisolated static func newestQuarantineDate(
    in directory: URL?, fileManager: FileManager
  ) throws -> Date? {
    guard let directory else { return nil }
    let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey]
    let entries: [URL]
    do {
      entries = try fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
      )
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
      return nil
    } catch {
      throw DiscoveryError.quarantineUnreadable
    }
    var newest: Date?
    for entry in entries {
      let values: URLResourceValues
      do { values = try entry.resourceValues(forKeys: Set(keys)) } catch { throw DiscoveryError.quarantineUnreadable }
      guard values.isDirectory == true else { continue }
      guard let created = values.creationDate else { throw DiscoveryError.quarantineUnreadable }
      newest = max(newest ?? created, created)
    }
    return newest
  }

  private static func log(_ report: Report) {
    let stop = report.stopReason?.rawValue ?? "none"
    logger.info("Draft photo sweep removed \(report.removed) file(s), \(report.removedBytes) bytes; kept \(report.keptNamed) still named, \(report.skippedByDate) used since listed; stop: \(stop, privacy: .public)")
  }

  static func logRefusal(_ refusal: DraftImageOrphanSweepGate.Refusal) {
    logger.info("Draft photo sweep not started: \(refusal.rawValue, privacy: .public)")
  }
}
