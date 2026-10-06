//
//  SceneComposerEditingSession.swift
//  Catbird
//
//  An editor belongs to exactly one window and one account.
//

import Foundation
import Observation

struct ComposerDraftClaim: Hashable, Codable, Sendable {
  let sceneID: UUID
  let accountDID: String
  let token: UUID
}

struct ComposerEditingSnapshot {
  let claim: ComposerDraftClaim
  let revision: UInt64
  let draft: PostComposerDraft
  let savedDraftID: UUID?
}

enum ComposerEditingError: LocalizedError {
  case invalidated
  case cancelled
  case staleClaim
  case staleRevision
  case savedDraftChanged
  case wrongAccount
  case alreadyClaimed(ComposerDraftClaim)
  case draftUnavailable
  case persistenceUnavailable
  case legacyRecoveryUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidated: return "This composer session has ended. Reopen the draft to continue."
    case .cancelled: return "This draft operation was cancelled."
    case .staleClaim, .staleRevision: return "The draft changed before this operation completed. Your newer draft has been kept."
    case .savedDraftChanged: return "The saved draft changed elsewhere. The newer saved draft and your current editor have both been kept."
    case .wrongAccount: return "This draft belongs to a different account."
    case .alreadyClaimed: return "This draft is already open in another window. Close that editor before opening it here."
    case .draftUnavailable: return "This saved draft is no longer available."
    case .persistenceUnavailable: return "Draft storage is not ready. Your current draft has been kept."
    case .legacyRecoveryUnavailable: return "There is no readable previous draft to recover."
    }
  }
}

/// Ownership is outside PostComposerDraft so existing content bytes and the
/// saved-draft schema remain compatible. Runtime tokens are always reminted.
private struct ComposerMinimizedDraftEnvelope: Codable {
  let version: Int
  let sceneID: UUID
  let accountDID: String
  let claimToken: UUID
  let revision: UInt64
  let draft: PostComposerDraft
  let savedDraftID: UUID?
  let savedDraftBaseline: PostComposerDraft?
  let isMinimized: Bool
}

@MainActor
@Observable
final class SceneComposerEditingSession {
  let sceneID: UUID
  let accountDID: String
  private(set) var currentDraft: PostComposerDraft?
  private(set) var savedDraftID: UUID?
  private(set) var activeClaim: ComposerDraftClaim?
  private(set) var isMinimized = false
  private(set) var lastIssue: String?

  @ObservationIgnored private let manager: ComposerDraftManager
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let persistDelay: Duration
  @ObservationIgnored private var persistTask: Task<Void, Never>?
  @ObservationIgnored private var revision: UInt64 = 0
  @ObservationIgnored private var activeEditorID: UUID?
  @ObservationIgnored private var liveDraftProvider: LiveDraftProvider?
  @ObservationIgnored private var isFlushingLiveDraft = false
  @ObservationIgnored private var savedDraftBaseline: PostComposerDraft?
  @ObservationIgnored private var isInvalidated = false

  static let legacyRecoveryKey = "composerMinimizedDraft"

  private struct LiveDraftProvider {
    let editorID: UUID
    let claim: ComposerDraftClaim
    let snapshot: @MainActor () -> PostComposerDraft?
  }

  static func persistenceKey(sceneID: UUID, accountDID: String) -> String {
    let account = Data(accountDID.utf8).base64EncodedString()
    return "composerEditingSession.v1.\(account).\(sceneID.uuidString)"
  }

  convenience init(appState: AppState, sceneID: UUID) {
    self.init(
      manager: appState.composerDraftManager,
      accountDID: appState.userDID,
      sceneID: sceneID,
      defaults: .standard
    )
  }

  init(
    manager: ComposerDraftManager,
    accountDID: String,
    sceneID: UUID,
    defaults: UserDefaults,
    persistDelay: Duration = .milliseconds(500)
  ) {
    self.manager = manager
    self.accountDID = accountDID
    self.sceneID = sceneID
    self.defaults = defaults
    self.persistDelay = persistDelay
    restoreScopedRecovery()
  }

  var hasLegacyRecovery: Bool { defaults.data(forKey: Self.legacyRecoveryKey) != nil }

  @discardableResult
  func beginNew(draft: PostComposerDraft? = nil) throws -> ComposerDraftClaim {
    try requireValidSession()
    let draft = draft ?? Self.emptyDraft()
    try preserveReplacedEditor()
    let claim = makeClaim()
    install(draft: draft, savedID: nil, claim: claim, minimized: false)
    try persistCurrentRecovery()
    return claim
  }

  @discardableResult
  func restoreSaved(_ saved: DraftPostViewModel) throws -> ComposerDraftClaim {
    try requireValidSession()
    guard saved.accountDID == accountDID else { throw ComposerEditingError.wrongAccount }
    if savedDraftID == saved.id, let claim = activeClaim {
      _ = resume(claim: claim)
      return claim
    }
    let claim = makeClaim()
    // Acquire first: a refused second-window claim must leave this editor intact.
    let draft = try manager.claimSavedDraft(id: saved.id, claim: claim)
    do {
      try preserveReplacedEditor()
      install(draft: draft, savedID: saved.id, claim: claim, minimized: false, baseline: draft)
      try persistCurrentRecovery()
      return claim
    } catch {
      manager.releaseSavedDraft(id: saved.id, claim: claim)
      throw error
    }
  }

  func snapshot() -> ComposerEditingSnapshot? {
    guard !isInvalidated, let claim = activeClaim, let draft = currentDraft else { return nil }
    return ComposerEditingSnapshot(claim: claim, revision: revision, draft: draft, savedDraftID: savedDraftID)
  }

  /// A restored saved-row claim can outlive several composer presentations.
  /// Only the latest attached view model may apply delayed media/editor work.
  @discardableResult
  func claimEditor(_ editorID: UUID, claim: ComposerDraftClaim) -> Bool {
    guard owns(claim), !Task.isCancelled else { return false }
    if activeEditorID != editorID {
      flushLiveDraftProvider()
      guard owns(claim) else { return false }
      liveDraftProvider = nil
    }
    activeEditorID = editorID
    return true
  }

  func ownsEditor(_ editorID: UUID, claim: ComposerDraftClaim) -> Bool {
    owns(claim) && activeEditorID == editorID && !Task.isCancelled
  }

  @discardableResult
  func releaseEditor(_ editorID: UUID, claim: ComposerDraftClaim) -> Bool {
    guard owns(claim), activeEditorID == editorID else { return false }
    flushLiveDraftProvider()
    guard owns(claim), activeEditorID == editorID else { return false }
    liveDraftProvider = nil
    activeEditorID = nil
    return true
  }

  @discardableResult
  func registerLiveDraftProvider(
    editorID: UUID,
    claim: ComposerDraftClaim,
    provider: @escaping @MainActor () -> PostComposerDraft?
  ) -> Bool {
    guard ownsEditor(editorID, claim: claim) else { return false }
    liveDraftProvider = LiveDraftProvider(editorID: editorID, claim: claim, snapshot: provider)
    return true
  }

  @discardableResult
  func unregisterLiveDraftProvider(editorID: UUID, claim: ComposerDraftClaim) -> Bool {
    guard owns(claim), activeEditorID == editorID,
          let provider = liveDraftProvider,
          provider.editorID == editorID, provider.claim == claim else { return false }
    flushLiveDraftProvider()
    guard owns(claim), activeEditorID == editorID,
          liveDraftProvider?.editorID == editorID,
          liveDraftProvider?.claim == claim else { return false }
    liveDraftProvider = nil
    return true
  }

  @discardableResult
  func update(_ draft: PostComposerDraft, claim: ComposerDraftClaim) -> Bool {
    guard owns(claim), !Task.isCancelled else { return false }
    if currentDraft != draft {
      currentDraft = draft
      revision &+= 1
    }
    schedulePersistence()
    return true
  }

  @discardableResult
  func minimize(claim: ComposerDraftClaim) -> Bool {
    guard owns(claim), !Task.isCancelled else { return false }
    flushLiveDraftProvider()
    guard owns(claim) else { return false }
    if let snapshot = snapshot(), snapshot.draft.isEmptyReply {
      // Release the editor and its recovery without deleting a saved draft row.
      finish(snapshot: snapshot)
      return true
    }
    isMinimized = true
    return persistRecoveryReportingFailure()
  }

  @discardableResult
  func resume(claim: ComposerDraftClaim) -> Bool {
    guard owns(claim), !Task.isCancelled else { return false }
    flushLiveDraftProvider()
    guard owns(claim) else { return false }
    isMinimized = false
    return persistRecoveryReportingFailure()
  }

  /// Save and detach only the exact captured content. Newer typing is never
  /// cleared by a delayed stash callback, even when it has the same claim.
  @discardableResult
  func stash(_ snapshot: ComposerEditingSnapshot) throws -> UUID {
    try requireCurrent(snapshot)
    do {
      let id = try manager.saveEditingSnapshot(snapshot, expectedSavedDraft: savedDraftBaseline)
      manager.releaseSavedDraft(id: id, claim: snapshot.claim)
      finish(snapshot: snapshot)
      return id
    } catch {
      preserveEditorAfterSavedRowConflict(error)
      lastIssue = error.localizedDescription
      throw error
    }
  }

  @discardableResult
  func discard(claim: ComposerDraftClaim) -> Bool {
    guard owns(claim), !Task.isCancelled, let snapshot = snapshot() else { return false }
    do {
      if let id = snapshot.savedDraftID {
        try manager.deleteClaimedDraft(id: id, claim: claim, expectedSavedDraft: savedDraftBaseline)
      }
      finish(snapshot: snapshot)
      return true
    } catch {
      preserveEditorAfterSavedRowConflict(error)
      lastIssue = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func completeSubmission(_ snapshot: ComposerEditingSnapshot) -> Bool {
    do {
      try requireCurrent(snapshot)
      if let id = snapshot.savedDraftID {
        try manager.deleteClaimedDraft(
          id: id, claim: snapshot.claim, expectedSavedDraft: savedDraftBaseline
        )
      }
      finish(snapshot: snapshot)
      return true
    } catch {
      preserveEditorAfterSavedRowConflict(error)
      lastIssue = error.localizedDescription
      return false
    }
  }

  /// A successful cross-account handoff ends only its source editor. Its row
  /// and media continue to belong to the source account; target begins anew.
  @discardableResult
  func detachForTransfer(_ snapshot: ComposerEditingSnapshot) -> Bool {
    do {
      try requireValidSession()
      guard owns(snapshot.claim) else { throw ComposerEditingError.staleClaim }
      flushLiveDraftProvider()
      try requireCurrent(snapshot)
      try archiveRecovery(snapshot)
      finish(snapshot: snapshot)
      return true
    } catch {
      lastIssue = error.localizedDescription
      return false
    }
  }

  /// Scene/account teardown preserves recoverable content and invalidates all
  /// callbacks, including a cancelled debounce waking after a replacement.
  func invalidate() {
    guard !isInvalidated else { return }
    flushLiveDraftProvider()
    persistTask?.cancel()
    persistTask = nil
    let previous = snapshot()
    if let previous {
      do {
        // Closed windows may never get their SceneStorage identity back. Keep
        // new content discoverable in the library as well as the scoped key.
        if let recoveryID = try manager.preserveEditingRecovery(previous) {
          savedDraftID = recoveryID
          savedDraftBaseline = previous.draft
        }
      } catch {
        lastIssue = error.localizedDescription
      }
    }
    _ = persistRecoveryReportingFailure()
    if let previous {
      manager.releaseSavedDraft(id: previous.savedDraftID, claim: previous.claim)
    }
    isInvalidated = true
    liveDraftProvider = nil
    activeEditorID = nil
    activeClaim = nil
    isMinimized = false
  }

  /// Legacy minimized bytes have no provable owner. Claiming them requires a
  /// deliberate action and a successful account-owned durable library save.
  @discardableResult
  func recoverLegacyDraft() throws -> ComposerDraftClaim {
    try requireValidSession()
    guard let bytes = defaults.data(forKey: Self.legacyRecoveryKey),
          let draft = try? JSONDecoder().decode(PostComposerDraft.self, from: bytes) else {
      throw ComposerEditingError.legacyRecoveryUnavailable
    }
    try preserveReplacedEditor()
    let claim = makeClaim()
    let snapshot = ComposerEditingSnapshot(claim: claim, revision: 0, draft: draft, savedDraftID: nil)
    let id = try manager.saveEditingSnapshot(snapshot)
    install(draft: draft, savedID: id, claim: claim, minimized: false, baseline: draft)
    try persistCurrentRecovery()
    if defaults.data(forKey: Self.legacyRecoveryKey) == bytes {
      defaults.removeObject(forKey: Self.legacyRecoveryKey)
    }
    return claim
  }

  private func makeClaim() -> ComposerDraftClaim {
    ComposerDraftClaim(sceneID: sceneID, accountDID: accountDID, token: UUID())
  }

  private func install(
    draft: PostComposerDraft, savedID: UUID?, claim: ComposerDraftClaim,
    minimized: Bool, baseline: PostComposerDraft? = nil
  ) {
    persistTask?.cancel()
    persistTask = nil
    if let previousClaim = activeClaim {
      manager.releaseSavedDraft(id: savedDraftID, claim: previousClaim)
    }
    liveDraftProvider = nil
    activeEditorID = nil
    currentDraft = draft
    savedDraftID = savedID
    savedDraftBaseline = baseline
    activeClaim = claim
    revision = 0
    isMinimized = minimized
    lastIssue = nil
  }

  private func owns(_ claim: ComposerDraftClaim) -> Bool {
    !isInvalidated && claim.sceneID == sceneID && claim.accountDID == accountDID && activeClaim == claim
  }

  private func requireValidSession() throws {
    guard !isInvalidated else { throw ComposerEditingError.invalidated }
    guard !Task.isCancelled else { throw ComposerEditingError.cancelled }
  }

  private func requireCurrent(_ snapshot: ComposerEditingSnapshot) throws {
    try requireValidSession()
    guard owns(snapshot.claim) else { throw ComposerEditingError.staleClaim }
    guard snapshot.revision == revision, snapshot.savedDraftID == savedDraftID,
          snapshot.draft == currentDraft else { throw ComposerEditingError.staleRevision }
  }

  private func preserveReplacedEditor() throws {
    flushLiveDraftProvider()
    guard let snapshot = snapshot() else { return }
    try archiveRecovery(snapshot)
  }

  private func finish(snapshot: ComposerEditingSnapshot) {
    persistTask?.cancel()
    persistTask = nil
    manager.releaseSavedDraft(id: snapshot.savedDraftID, claim: snapshot.claim)
    removeRecovery(ownedBy: snapshot.claim)
    liveDraftProvider = nil
    activeEditorID = nil
    activeClaim = nil
    currentDraft = nil
    savedDraftID = nil
    savedDraftBaseline = nil
    revision &+= 1
    isMinimized = false
    // Media can also be referenced by another scene, a source account row or
    // recovery envelope. Editor teardown intentionally never unlinks files.
  }

  private var persistenceKey: String { Self.persistenceKey(sceneID: sceneID, accountDID: accountDID) }

  /// Teardown may run in a cancelled task, so ownership is checked independently
  /// of cancellation. The weak-capturing view-model provider cannot outlive or
  /// replace the exact draft claim and presentation that registered it.
  private func flushLiveDraftProvider() {
    guard !isFlushingLiveDraft, let provider = liveDraftProvider,
          owns(provider.claim), activeEditorID == provider.editorID else { return }
    isFlushingLiveDraft = true
    defer { isFlushingLiveDraft = false }
    guard let draft = provider.snapshot(),
          owns(provider.claim), activeEditorID == provider.editorID,
          liveDraftProvider?.claim == provider.claim,
          liveDraftProvider?.editorID == provider.editorID else { return }
    if currentDraft != draft {
      currentDraft = draft
      revision &+= 1
    }
    _ = persistRecoveryReportingFailure()
  }

  private func encodedEnvelope(_ snapshot: ComposerEditingSnapshot) throws -> Data {
    try JSONEncoder().encode(ComposerMinimizedDraftEnvelope(
      version: 1, sceneID: sceneID, accountDID: accountDID,
      claimToken: snapshot.claim.token, revision: snapshot.revision,
      draft: snapshot.draft, savedDraftID: snapshot.savedDraftID,
      savedDraftBaseline: savedDraftBaseline, isMinimized: isMinimized
    ))
  }

  private func archiveRecovery(_ snapshot: ComposerEditingSnapshot) throws {
    _ = try manager.preserveEditingRecovery(snapshot)
  }

  private func persistCurrentRecovery() throws {
    guard let snapshot = snapshot() else { return }
    defaults.set(try encodedEnvelope(snapshot), forKey: persistenceKey)
  }

  private func persistRecoveryReportingFailure() -> Bool {
    do {
      try persistCurrentRecovery()
      return true
    } catch {
      lastIssue = error.localizedDescription
      return false
    }
  }

  private func removeRecovery(ownedBy claim: ComposerDraftClaim) {
    guard let bytes = defaults.data(forKey: persistenceKey),
          let envelope = try? JSONDecoder().decode(ComposerMinimizedDraftEnvelope.self, from: bytes),
          envelope.claimToken == claim.token else { return }
    defaults.removeObject(forKey: persistenceKey)
  }

  private func schedulePersistence() {
    persistTask?.cancel()
    guard let captured = snapshot() else { return }
    persistTask = Task { [weak self, delay = persistDelay] in
      do { try await Task.sleep(for: delay) }
      catch { return }
      guard !Task.isCancelled, let self else { return }
      do {
        try self.requireCurrent(captured)
        // Always preserve the editor even when its saved row was deleted or
        // changed elsewhere and can no longer accept a write-through save.
        try self.persistCurrentRecovery()
        if captured.savedDraftID != nil {
          _ = try self.manager.saveEditingSnapshot(
            captured, expectedSavedDraft: self.savedDraftBaseline
          )
          self.savedDraftBaseline = captured.draft
          try self.persistCurrentRecovery()
        }
      } catch {
        self.preserveEditorAfterSavedRowConflict(error)
        self.lastIssue = error.localizedDescription
      }
    }
  }

  /// Remote reconciliation can replace a row even while its local editor owns
  /// the scene claim. Keep both versions; never write or tombstone the new row.
  private func preserveEditorAfterSavedRowConflict(_ error: Error) {
    guard let editingError = error as? ComposerEditingError else { return }
    switch editingError {
    case .savedDraftChanged, .draftUnavailable: break
    default: return
    }
    guard let previous = snapshot(), previous.savedDraftID != nil else { return }
    do {
      let recoveryID = try manager.preserveEditingRecovery(previous)
      if let recoveryID {
        _ = try manager.claimSavedDraft(id: recoveryID, claim: previous.claim)
      }
      if recoveryID != previous.savedDraftID {
        manager.releaseSavedDraft(id: previous.savedDraftID, claim: previous.claim)
      }
      persistTask?.cancel()
      persistTask = nil
      savedDraftID = recoveryID
      savedDraftBaseline = recoveryID == nil ? nil : previous.draft
      revision &+= 1
      try persistCurrentRecovery()
    } catch {
      // A failed recovery save must not discard the current editor. Its scoped
      // envelope still holds the original baseline and body for a later retry.
      _ = persistRecoveryReportingFailure()
    }
  }

  private func restoreScopedRecovery() {
    guard let bytes = defaults.data(forKey: persistenceKey),
          let envelope = try? JSONDecoder().decode(ComposerMinimizedDraftEnvelope.self, from: bytes),
          envelope.version == 1, envelope.sceneID == sceneID,
          envelope.accountDID == accountDID else { return }
    let claim = makeClaim()
    var restoredSavedID: UUID?
    var baseline: PostComposerDraft?
    var recoveryIssue: String?
    if let id = envelope.savedDraftID {
      do {
        let currentSaved = try manager.claimSavedDraft(id: id, claim: claim)
        if currentSaved == envelope.savedDraftBaseline {
          restoredSavedID = id
          baseline = currentSaved
        } else {
          manager.releaseSavedDraft(id: id, claim: claim)
          recoveryIssue = "The saved draft changed in another window. Your recovered content is a separate draft."
        }
      } catch {
        manager.releaseSavedDraft(id: id, claim: claim)
        recoveryIssue = "The original saved draft cannot be edited here. Your recovered content is a separate draft."
      }
    }
    install(
      draft: envelope.draft, savedID: restoredSavedID, claim: claim,
      minimized: true, baseline: baseline
    )
    do { try persistCurrentRecovery() }
    catch { recoveryIssue = error.localizedDescription }
    lastIssue = recoveryIssue
  }

  private static func emptyDraft() -> PostComposerDraft {
    PostComposerDraft(
      postText: "", mediaItems: [], videoItem: nil, selectedGif: nil,
      selectedLanguages: [], selectedLabels: [], outlineTags: [],
      threadEntries: [], isThreadMode: false, currentThreadIndex: 0,
      parentPostURI: nil, quotedPostURI: nil
    )
  }
}

extension PostComposerDraft {
  /// A reply reference alone is context, rather than authored draft content.
  var isEmptyReply: Bool {
    (parentPostURI != nil || threadEntries.contains { $0.parentPostURI != nil })
      && !hasMeaningfulContent
  }

  var hasMeaningfulContent: Bool {
    !postText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !mediaItems.isEmpty || videoItem != nil || selectedGif != nil
      || quotedPostURI != nil || !outlineTags.isEmpty || !selectedLabels.isEmpty
      || pendingAudioURLString != nil
      || threadEntries.contains {
        !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || !$0.mediaItems.isEmpty || $0.videoItem != nil || $0.selectedGif != nil
          || $0.quotedPostURI != nil || !$0.hashtags.isEmpty
          || $0.selectedEmbedURL != nil || !$0.urlsKeptForEmbed.isEmpty
      }
  }

  var hasRecoverableContent: Bool {
    !postText.isEmpty || !mediaItems.isEmpty || videoItem != nil || selectedGif != nil
      || parentPostURI != nil || quotedPostURI != nil || !outlineTags.isEmpty
      || pendingAudioURLString != nil
      || threadEntries.contains {
        !$0.text.isEmpty || !$0.mediaItems.isEmpty || $0.videoItem != nil
          || $0.selectedGif != nil || $0.parentPostURI != nil || $0.quotedPostURI != nil
      }
  }
}
