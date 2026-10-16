//
//  DraftImageFileJanitor.swift
//  Catbird
//
//  Removes draft photo files once nothing names them.
//

import Foundation
import OSLog

/// Composer photos are copied into the App Group's SharedDrafts folder as
/// `draft_image_<sha256>.jpg` (CodableMediaItem.writeImageData). The names are content hashes,
/// so two compositions holding the same photo share one file, and a saved draft of any account,
/// a scene's recovery envelope, an account handoff or another open editor can name it.
///
/// Two callers hand files over. A composition that ends (discarded, posted, saved as a draft,
/// closed as an empty reply, or replaced) passes the files it created, and DraftImageOrphanSweep
/// passes batches of files nothing has used for a week. A file is deleted only when it sits
/// directly in that folder, has the managed name, and no stored or open draft names it. A store
/// that cannot be read cancels the whole pass. The check and the unlink run in one main-actor
/// turn, so no editor can claim a file in between. An editor that already holds the URL of a
/// file removed here writes it again on its next save (`DraftImageFile.exists`).
@MainActor
struct DraftImageFileJanitor {
  struct Outcome: Equatable {
    var removed: Set<String> = []
    var kept: Set<String> = []
    /// Not a managed draft photo in the draft folder; never touched.
    var ignored: Set<String> = []
    /// Named by nothing, but modified outside the window the caller allowed; never touched.
    var skippedByDate: Set<String> = []
    /// The total size of the removed files.
    var removedBytes: Int64 = 0
    var cancelled = false
  }

  /// The folder draft photos are written to.
  let directory: URL?
  /// Stored bytes that may name a draft file. Throwing cancels the pass.
  let storedReferences: () throws -> [Data]
  /// File names that open editors, scene sessions and pending handoffs hold in memory.
  let liveFileNames: () -> Set<String>
  var fileManager: FileManager = .default

  private static let logger = Logger(subsystem: "blue.catbird", category: "DraftImageFileJanitor")

  /// Removes the files in `urlStrings` that nothing names. With `eligibleModificationDates`, a
  /// file is removed only while its modification date, read right before the unlink, lies in
  /// that range, so a file reused since the caller listed it stays.
  func removeUnreferenced(
    _ urlStrings: Set<String>, eligibleModificationDates: Range<Date>? = nil
  ) -> Outcome {
    var outcome = Outcome()
    guard !urlStrings.isEmpty else { return outcome }
    guard let directory else {
      outcome.cancelled = true
      Self.logger.error("Draft folder unavailable; kept \(urlStrings.count) draft photo file(s)")
      return outcome
    }
    let folder = Self.canonicalPath(directory)
    var candidates: [(urlString: String, url: URL)] = []
    for urlString in urlStrings {
      guard let url = URL(string: urlString), url.isFileURL,
            Self.isManagedFileName(url.lastPathComponent),
            Self.canonicalPath(url.deletingLastPathComponent()) == folder else {
        outcome.ignored.insert(urlString)
        continue
      }
      candidates.append((urlString, url))
    }
    guard !candidates.isEmpty else { return outcome }

    let stored: [Data]
    do {
      stored = try storedReferences()
    } catch {
      outcome.cancelled = true
      Self.logger.error("Could not read every draft store (\(error.localizedDescription)); kept \(candidates.count) draft photo file(s)")
      return outcome
    }
    // One pass over the stored bytes for every name they hold, however many candidates there are.
    let referenced = stored.reduce(into: liveFileNames()) { $0.formUnion(Self.managedFileNames(in: $1)) }

    for candidate in candidates {
      if referenced.contains(candidate.url.lastPathComponent) {
        outcome.kept.insert(candidate.urlString)
      } else {
        remove(candidate, eligibleModificationDates: eligibleModificationDates, into: &outcome)
      }
    }
    Self.logger.info("Draft photo cleanup removed \(outcome.removed.count) (\(outcome.removedBytes) bytes), kept \(outcome.kept.count) still named elsewhere, \(outcome.skippedByDate.count) used since listed")
    return outcome
  }

  /// Unlinks one file nothing names, after re-reading its modification date when a window applies.
  private func remove(
    _ candidate: (urlString: String, url: URL),
    eligibleModificationDates: Range<Date>?,
    into outcome: inout Outcome
  ) {
    // Gone already when this fails.
    guard let attributes = try? fileManager.attributesOfItem(atPath: candidate.url.path) else { return }
    if let eligibleModificationDates {
      guard let modified = attributes[.modificationDate] as? Date,
            eligibleModificationDates.contains(modified) else {
        outcome.skippedByDate.insert(candidate.urlString)
        return
      }
    }
    do {
      try fileManager.removeItem(at: candidate.url)
      outcome.removed.insert(candidate.urlString)
      outcome.removedBytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    } catch {
      outcome.kept.insert(candidate.urlString)
      Self.logger.error("Could not remove an unreferenced draft photo file: \(error.localizedDescription)")
    }
  }

  /// `draft_image_` followed by a lowercase SHA-256 hex digest and `.jpg`.
  nonisolated static func isManagedFileName(_ name: String) -> Bool {
    let prefix = "draft_image_", suffix = ".jpg"
    guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
    let digest = name.dropFirst(prefix.count).dropLast(suffix.count)
    return digest.count == 64 && digest.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
  }

  /// Every managed name (`isManagedFileName`) spelled anywhere in `data`: in a URL, a path or an
  /// escaped JSON string. A name has no characters JSON or URL encoding would escape, so any
  /// stored form that names a file contains its bytes.
  nonisolated static func managedFileNames(in data: Data) -> Set<String> {
    let prefix = Data("draft_image_".utf8), suffix = Data(".jpg".utf8)
    let digestLength = 64
    var names = Set<String>()
    var cursor = data.startIndex
    while cursor < data.endIndex, let found = data.range(of: prefix, in: cursor..<data.endIndex) {
      cursor = found.upperBound
      let digestEnd = found.upperBound + digestLength
      let nameEnd = digestEnd + suffix.count
      // A later prefix starts later still, so it cannot fit either.
      guard nameEnd <= data.endIndex else { break }
      guard data[found.upperBound..<digestEnd].allSatisfy(isLowercaseHexDigit),
            data[digestEnd..<nameEnd].elementsEqual(suffix),
            let name = String(bytes: data[found.lowerBound..<nameEnd], encoding: .ascii) else { continue }
      names.insert(name)
    }
    return names
  }

  private nonisolated static func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
  }

  private static func canonicalPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
  }
}

extension DraftImageFileJanitor {
  enum ReferenceStoreError: LocalizedError {
    case unavailable(String)
    case unreadable(String)

    var errorDescription: String? {
      switch self {
      case .unavailable(let store): return "\(store) is unavailable"
      case .unreadable(let store): return "\(store) could not be read"
      }
    }
  }

  /// Every place the app keeps a draft that can name a draft photo:
  /// - the JSON drafts an earlier version saved in Application Support/Catbird/Drafts: one whose
  ///   migration failed stays there and can still migrate. They are read before the rows, so a
  ///   migration that moves one into a row meanwhile is seen in one or the other;
  /// - live saved-draft rows of every account, recovery copies and tombstones whose create is
  ///   unconfirmed included, with the remote snapshots in their sync metadata
  ///   (DraftPersistence.storedMediaReferenceData);
  /// - every scene's recovery envelope and the legacy minimized draft (`recoveryDefaults`);
  /// - the App Group handoff slot the share extension and the Draft Post intent fill;
  /// - the composer outbox queue. It holds no media today; it is searched so that an outbox
  ///   that starts carrying photos keeps them without another change here;
  /// - open editors, scene sessions, and account handoffs both queued and claimed by a window
  ///   that has not opened them yet (LiveDraftMediaReferences).
  static func standard(
    persistence: DraftPersistence?,
    recoveryDefaults: UserDefaults,
    handoffDefaults: UserDefaults? = UserDefaults(suiteName: "group.blue.catbird.shared"),
    outboxQueueURL: URL? = ComposerOutbox.queueFileURL,
    legacyDraftsDirectory: URL? = ComposerDraftManager.legacyDraftsDirectoryURL,
    directory: URL? = CodableMediaItem.draftImagesDirectory
  ) -> DraftImageFileJanitor {
    DraftImageFileJanitor(
      directory: directory,
      storedReferences: {
        guard let persistence else { throw ReferenceStoreError.unavailable("Saved-draft storage") }
        var stored = try legacyDraftsDirectory.map(legacyDraftData(in:)) ?? []
        stored += try persistence.storedMediaReferenceData()
        stored += try SceneComposerEditingSession.storedRecoveryData(in: recoveryDefaults)
        guard let handoffDefaults else { throw ReferenceStoreError.unavailable("The App Group handoff slot") }
        if let slot = handoffDefaults.object(forKey: ComposeDraftStasher.draftKey) {
          guard let bytes = slot as? Data else { throw ReferenceStoreError.unreadable("The App Group handoff slot") }
          stored.append(bytes)
        }
        if let outboxQueueURL, FileManager.default.fileExists(atPath: outboxQueueURL.path) {
          stored.append(try Data(contentsOf: outboxQueueURL))
        }
        return stored
      },
      liveFileNames: { LiveDraftMediaReferences.fileNames() }
    )
  }

  /// The bytes of every JSON draft in `directory`. A missing folder holds none; one that cannot
  /// be listed or read throws. A file the migration removes between listing and reading was
  /// stored as a row first, and the rows are read after this.
  private static func legacyDraftData(in directory: URL) throws -> [Data] {
    let files: [URL]
    do {
      files = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
      )
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
      return []
    } catch {
      throw ReferenceStoreError.unreadable("Legacy saved drafts")
    }
    var stored: [Data] = []
    for file in files where file.pathExtension == "json" {
      do {
        stored.append(try Data(contentsOf: file))
      } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
        continue
      } catch {
        throw ReferenceStoreError.unreadable("Legacy saved drafts")
      }
    }
    return stored
  }
}

// MARK: - Drafts held in memory

/// An object that holds draft media in memory: an open editor, a scene's editing session, the
/// account-switch queue's pending handoffs or a handoff a window has claimed. Anything new that
/// holds a draft-file URL outside a stored draft must register as one, or the janitor and the
/// orphan sweep cannot see it.
@MainActor
protocol DraftMediaReferenceHolder: AnyObject {
  /// URL strings of the local files this object may still save, reopen or upload.
  var heldDraftMediaURLStrings: [String] { get }
}

/// A weak registry of every live DraftMediaReferenceHolder.
@MainActor
enum LiveDraftMediaReferences {
  private struct Entry {
    weak var holder: (any DraftMediaReferenceHolder)?
  }

  private static var entries: [ObjectIdentifier: Entry] = [:]

  static func register(_ holder: any DraftMediaReferenceHolder) {
    entries = entries.filter { $0.value.holder != nil }
    entries[ObjectIdentifier(holder)] = Entry(holder: holder)
  }

  /// The file names every live holder names.
  static func fileNames() -> Set<String> {
    entries = entries.filter { $0.value.holder != nil }
    var names = Set<String>()
    for entry in entries.values {
      guard let holder = entry.holder else { continue }
      for urlString in holder.heldDraftMediaURLStrings {
        if let name = URL(string: urlString)?.lastPathComponent, !name.isEmpty { names.insert(name) }
      }
    }
    return names
  }
}

extension PostComposerDraft {
  /// Every local file this draft names: photos, videos and a pending audio recording.
  var referencedFileURLStrings: [String] {
    let entries = threadEntries
    let items = mediaItems + [videoItem].compactMap { $0 }
      + entries.flatMap { $0.mediaItems + [$0.videoItem].compactMap { $0 } }
    return items.flatMap { [$0.rawImageURLString, $0.rawVideoURLString].compactMap { $0 } }
      + [pendingAudioURLString].compactMap { $0 }
  }
}
