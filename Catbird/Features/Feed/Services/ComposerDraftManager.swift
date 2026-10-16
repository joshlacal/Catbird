//
//  ComposerDraftManager.swift
//  Catbird
//
//  Account-owned saved library. Active editing belongs to a scene session.
//

import Foundation
import SwiftUI
import SwiftData
import Petrel
import OSLog

@MainActor
@Observable
final class ComposerDraftManager {
  private(set) var savedDrafts: [DraftPostViewModel] = []
  private(set) var draftsLoaded = false
  var draftSyncIssue: String?

  @ObservationIgnored private weak var appState: AppState?
  @ObservationIgnored private var draftPersistence: DraftPersistence?
  @ObservationIgnored private var modelContext: ModelContext?
  @ObservationIgnored private var draftSyncService: DraftSyncService?
  @ObservationIgnored private var accountObservation: Task<Void, Never>?
  private struct SavedDraftClaimKey: Hashable {
    let accountDID: String
    let id: UUID
  }
  // AppState instances can be replaced during authentication while another
  // window still owns the same account. Claims span those manager instances.
  private static var savedDraftClaims: [SavedDraftClaimKey: ComposerDraftClaim] = [:]
  @ObservationIgnored private var testingAccountDID: String?
  /// Where scene recovery envelopes live (`.standard` in the app, a suite in tests). Draft photo
  /// cleanup reads them by default.
  private let recoveryDefaults: UserDefaults
  #if DEBUG
  /// Temporary stand-ins for the stores draft photo cleanup reads and the folder it works in, so
  /// tests neither depend on nor touch what the host app left there.
  struct DraftImageTestingStores {
    let handoff: UserDefaults
    let outboxQueue: URL
    let legacyDrafts: URL?
    let draftImages: URL?
    let quarantine: URL?
    let storeResetDate: Date?
  }

  @ObservationIgnored private var testingDraftImageStores: DraftImageTestingStores?
  #endif
  private var hasMigratedLegacyDrafts = false
  private let logger = Logger(subsystem: "blue.catbird", category: "ComposerDraftManager")

  init(appState: AppState? = nil) {
    self.appState = appState
    self.recoveryDefaults = .standard
    // The legacy minimized blob has no account or scene owner. Only a scene's
    // explicit recovery action may read, claim, or remove it.
  }

  #if DEBUG
  init(accountDID: String, modelContext: ModelContext, defaults: UserDefaults) {
    self.testingAccountDID = accountDID
    self.recoveryDefaults = defaults
    configureForTesting(modelContext: modelContext)
  }

  func configureForTesting(modelContext: ModelContext) {
    accountObservation?.cancel()
    accountObservation = nil
    draftSyncService?.cancelPendingWork()
    draftSyncService = nil
    draftSyncIssue = nil
    self.modelContext = modelContext
    draftPersistence = DraftPersistence(modelContext: modelContext)
    reloadSavedDrafts()
  }

  /// A nil legacy-drafts or quarantine folder means there is none. A nil draft photo folder
  /// keeps the App Group's, which composer writes use, for cleanup; the orphan sweep then has no
  /// folder and refuses.
  func useDraftImageStoresForTesting(
    handoffDefaults: UserDefaults,
    outboxQueueURL: URL,
    legacyDraftsDirectory: URL? = nil,
    draftImagesDirectory: URL? = nil,
    quarantineDirectory: URL? = nil,
    storeResetDate: Date? = nil
  ) {
    testingDraftImageStores = DraftImageTestingStores(
      handoff: handoffDefaults, outboxQueue: outboxQueueURL,
      legacyDrafts: legacyDraftsDirectory, draftImages: draftImagesDirectory,
      quarantine: quarantineDirectory, storeResetDate: storeResetDate
    )
  }

  /// A test's own draft sync service over this manager's store, in place of none.
  func useDraftSyncServiceForTesting(_ service: DraftSyncService) {
    draftSyncService?.cancelPendingWork()
    draftSyncService = service
  }
  #endif

  func setModelContext(_ context: ModelContext) {
    modelContext = context
    let persistence = DraftPersistence(modelContext: context)
    draftPersistence = persistence
    draftSyncService = DraftSyncService(
      persistence: persistence,
      clientProvider: { [weak self] in self?.appState?.atProtoClient },
      accountProvider: { [weak self] in
        guard let ownedDID = self?.currentAccountDID,
              AppStateManager.shared.lifecycle.userDID == ownedDID else { return nil }
        return ownedDID
      }
    )
    Task { [weak self] in
      guard let self else { return }
      await self.migrateLegacyDraftsIfNeeded()
      await self.loadSavedDrafts()
    }
  }

  func updateAppState(_ appState: AppState?) {
    self.appState = appState
    accountObservation?.cancel()
    accountObservation = nil
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("--social-actions-ui-fixture") { return }
    #endif
    guard appState != nil else { return }
    // Start from the current state: each subscription only sees later changes,
    // and at launch the account is already authenticated when this runs, so the
    // first remote draft sync would otherwise wait for the next auth change.
    let authStates = AppStateManager.shared.authentication.currentAndFutureStates
    accountObservation = Task { [weak self] in
      var lastDID: String?
      for await state in authStates {
        guard !Task.isCancelled, let self else { return }
        guard state.userDID != lastDID else { continue }
        lastDID = state.userDID
        self.draftSyncService?.cancelPendingWork()
        // Saved rows and scene recovery retain their immutable account owner.
        await self.loadSavedDrafts()
        await self.performRemoteSync()
      }
    }
    reloadSavedDrafts()
  }

  private var currentAccountDID: String? { appState?.userDID ?? testingAccountDID }

  // MARK: - Exclusive saved-row ownership

  func claimSavedDraft(id: UUID, claim: ComposerDraftClaim) throws -> PostComposerDraft {
    try validateAccount(claim.accountDID)
    guard let persistence = draftPersistence else { throw ComposerEditingError.persistenceUnavailable }
    let key = SavedDraftClaimKey(accountDID: claim.accountDID, id: id)
    if let owner = Self.savedDraftClaims[key], owner != claim {
      throw ComposerEditingError.alreadyClaimed(owner)
    }
    guard let model = try persistence.fetchDraftModel(id: id),
          model.accountDID == claim.accountDID,
          try persistence.syncState(for: model).deletedAt == nil else {
      throw ComposerEditingError.draftUnavailable
    }
    let draft = try model.decodeDraft()
    Self.savedDraftClaims[key] = claim
    return draft
  }

  func releaseSavedDraft(id: UUID?, claim: ComposerDraftClaim) {
    guard let id else { return }
    let key = SavedDraftClaimKey(accountDID: claim.accountDID, id: id)
    guard Self.savedDraftClaims[key] == claim else { return }
    Self.savedDraftClaims.removeValue(forKey: key)
  }

  /// Every local write is synchronous on the main actor, including the final
  /// owner check. No await can rotate a claim between validation and commit.
  func saveEditingSnapshot(
    _ snapshot: ComposerEditingSnapshot,
    expectedSavedDraft: PostComposerDraft? = nil
  ) throws -> UUID {
    try validateAccount(snapshot.claim.accountDID)
    guard let persistence = draftPersistence, let context = modelContext else {
      throw ComposerEditingError.persistenceUnavailable
    }
    let id: UUID
    if let savedID = snapshot.savedDraftID {
      let key = SavedDraftClaimKey(accountDID: snapshot.claim.accountDID, id: savedID)
      guard Self.savedDraftClaims[key] == snapshot.claim else { throw ComposerEditingError.staleClaim }
      guard let model = try persistence.fetchDraftModel(id: savedID),
            model.accountDID == snapshot.claim.accountDID,
            try persistence.syncState(for: model).deletedAt == nil else {
        throw ComposerEditingError.draftUnavailable
      }
      guard try model.decodeDraft() == expectedSavedDraft else {
        throw ComposerEditingError.savedDraftChanged
      }
      // Return early if content did not change, skipping redundant writes, reloads, and pushes (P178)
      if snapshot.draft == expectedSavedDraft {
        return savedID
      }
      try model.apply(snapshot.draft)
      model.touch()
      try context.save()
      id = savedID
    } else {
      id = try persistence.saveDraft(snapshot.draft, accountDID: snapshot.claim.accountDID)
      Self.savedDraftClaims[SavedDraftClaimKey(accountDID: snapshot.claim.accountDID, id: id)] = snapshot.claim
    }
    reloadSavedDrafts()
    scheduleRemotePush(draftId: id, accountDID: snapshot.claim.accountDID)
    return id
  }

  /// Recovery is visible in the existing library. Reusing a durable identical
  /// row avoids duplicates; changed/unsaved content becomes a local recovery
  /// copy and cannot overwrite or upload through the source row's identity.
  @discardableResult
  func preserveEditingRecovery(_ snapshot: ComposerEditingSnapshot) throws -> UUID? {
    try validateAccount(snapshot.claim.accountDID)
    guard let persistence = draftPersistence, let context = modelContext else {
      throw ComposerEditingError.persistenceUnavailable
    }
    if let id = snapshot.savedDraftID,
       let existing = try persistence.fetchDraftModel(id: id),
       existing.accountDID == snapshot.claim.accountDID,
       try persistence.syncState(for: existing).deletedAt == nil,
       try existing.decodeDraft() == snapshot.draft {
      return id
    }
    // An untouched empty composer has no content that needs a library copy.
    guard snapshot.draft.hasRecoverableContent else { return nil }
    let model = try DraftPost.create(from: snapshot.draft, accountDID: snapshot.claim.accountDID)
    var state = DraftSyncState()
    state.recoveryReason = "Recovered from an earlier composer session."
    model.syncMetadata = try JSONEncoder().encode(state)
    context.insert(model)
    try context.save()
    reloadSavedDrafts()
    return model.id
  }

  func deleteClaimedDraft(
    id: UUID,
    claim: ComposerDraftClaim,
    expectedSavedDraft: PostComposerDraft?
  ) throws {
    try validateAccount(claim.accountDID)
    let key = SavedDraftClaimKey(accountDID: claim.accountDID, id: id)
    guard Self.savedDraftClaims[key] == claim else { throw ComposerEditingError.staleClaim }
    guard let persistence = draftPersistence else { throw ComposerEditingError.persistenceUnavailable }
    guard let model = try persistence.fetchDraftModel(id: id),
          model.accountDID == claim.accountDID,
          try persistence.syncState(for: model).deletedAt == nil else {
      throw ComposerEditingError.draftUnavailable
    }
    guard try model.decodeDraft() == expectedSavedDraft else {
      throw ComposerEditingError.savedDraftChanged
    }
    try persistence.markDeleted(id: id, accountDID: claim.accountDID)
    Self.savedDraftClaims.removeValue(forKey: key)
    reloadSavedDrafts()
    scheduleRemoteSync(accountDID: claim.accountDID)
  }

  // MARK: - Draft photo files

  /// Deletes draft photo files that a composition wrote and no longer uses, unless a live saved
  /// draft of any account, a recovery envelope in `recoveryDefaults` (this manager's when nil),
  /// the App Group handoff slot, the outbox, a legacy JSON draft, an open editor or a pending
  /// account handoff still names them. Posting and saving a draft call this on the main actor,
  /// so the pass is signposted ("DraftPhotoCleanup").
  @discardableResult
  func removeUnreferencedDraftImageFiles(
    _ urlStrings: Set<String>,
    recoveryDefaults: UserDefaults? = nil
  ) -> DraftImageFileJanitor.Outcome {
    guard !urlStrings.isEmpty else { return DraftImageFileJanitor.Outcome() }
    let signpost = PerformanceSignposts.beginInterval("DraftPhotoCleanup")
    defer { PerformanceSignposts.endInterval("DraftPhotoCleanup", signpost) }
    return draftImageFileJanitor(recoveryDefaults: recoveryDefaults ?? self.recoveryDefaults)
      .removeUnreferenced(urlStrings)
  }

  /// A janitor over every draft store, honouring a test's stand-ins.
  private func draftImageFileJanitor(recoveryDefaults: UserDefaults) -> DraftImageFileJanitor {
    #if DEBUG
    if let stores = testingDraftImageStores {
      return DraftImageFileJanitor.standard(
        persistence: draftPersistence, recoveryDefaults: recoveryDefaults,
        handoffDefaults: stores.handoff, outboxQueueURL: stores.outboxQueue,
        legacyDraftsDirectory: stores.legacyDrafts,
        directory: stores.draftImages ?? CodableMediaItem.draftImagesDirectory
      )
    }
    #endif
    return DraftImageFileJanitor.standard(persistence: draftPersistence, recoveryDefaults: recoveryDefaults)
  }

  private func validateAccount(_ accountDID: String) throws {
    guard currentAccountDID == accountDID else { throw ComposerEditingError.wrongAccount }
  }

  // MARK: - Orphaned draft photos

  /// Runs DraftImageOrphanSweep when DraftImageOrphanSweepGate allows it, and records the start
  /// only then; every refusal is logged by name. The sync rules use this manager's service: the
  /// sweep waits for a complete sync of the current account, so another signed-in account's
  /// Bluesky drafts are protected by the 7-day threshold and the store quarantine and reset
  /// fence alone.
  func sweepOrphanedDraftImageFilesIfDue(
    now: Date = Date(),
    isInBackground: @escaping @MainActor () -> Bool = { PlatformApplication.isInBackground }
  ) async -> DraftImageOrphanSweep.Result {
    let lastStarted = (recoveryDefaults.object(forKey: DraftImageOrphanSweep.lastStartedKey) as? Double)
      .map(Date.init(timeIntervalSince1970:))
    let syncCompleted = currentAccountDID.map { draftSyncService?.syncedAccountsThisLaunch.contains($0) ?? false } ?? false
    if let refusal = DraftImageOrphanSweepGate.refusal(
      storeIsDurable: draftPersistence?.isBackedByDurableStore ?? false,
      isInBackground: isInBackground(),
      syncEnabled: draftSyncService?.isEnabled ?? false,
      syncRunning: draftSyncService?.isSyncing ?? false,
      syncCompletedThisLaunch: syncCompleted,
      lastStartedAt: lastStarted,
      now: now
    ) {
      DraftImageOrphanSweep.logRefusal(refusal)
      return .refused(refusal)
    }
    guard let folders = orphanSweepFolders() else {
      DraftImageOrphanSweep.logRefusal(.folderUnavailable)
      return .refused(.folderUnavailable)
    }
    recoveryDefaults.set(now.timeIntervalSince1970, forKey: DraftImageOrphanSweep.lastStartedKey)
    let recoveryDefaults = recoveryDefaults
    let sweep = DraftImageOrphanSweep(
      directory: folders.draftImages,
      quarantineDirectory: folders.quarantine,
      storeResetDate: folders.storeResetDate,
      janitor: { [weak self] in
        // A released manager has no stores to read, so the batch cancels.
        self?.draftImageFileJanitor(recoveryDefaults: recoveryDefaults)
          ?? .standard(persistence: nil, recoveryDefaults: recoveryDefaults, directory: folders.draftImages)
      },
      interruption: { [weak self] in
        guard let self else { return .cancelled }
        if self.draftSyncService?.isSyncing ?? false { return .draftSyncStarted }
        return isInBackground() ? nil : .returnedToForeground
      }
    )
    return .finished(await sweep.run(now: now))
  }

  private struct OrphanSweepFolders {
    let draftImages: URL
    let quarantine: URL?
    let storeResetDate: Date?
  }

  /// The app's draft photo folder, quarantine folder and last store reset, or a test's
  /// stand-ins. A manager built for tests sweeps only a folder a test handed it.
  private func orphanSweepFolders() -> OrphanSweepFolders? {
    #if DEBUG
    if let stores = testingDraftImageStores {
      return stores.draftImages.map {
        OrphanSweepFolders(draftImages: $0, quarantine: stores.quarantine, storeResetDate: stores.storeResetDate)
      }
    }
    if testingAccountDID != nil { return nil }
    #endif
    guard let directory = CodableMediaItem.draftImagesDirectory else { return nil }
    return OrphanSweepFolders(
      draftImages: directory,
      quarantine: CatbirdSwiftDataStore.quarantineDirectory,
      storeResetDate: CatbirdSwiftDataStore.lastStoreResetDate
    )
  }

  // MARK: - Saved library

  /// Creates an independent library row; never infers an active editor.
  func createSavedDraft(_ draft: PostComposerDraft) {
    guard let accountDID = currentAccountDID else { return }
    do { _ = try createSavedDraft(draft, accountDID: accountDID) }
    catch { draftSyncIssue = error.localizedDescription }
  }

  @discardableResult
  func createSavedDraft(_ draft: PostComposerDraft, accountDID: String) throws -> UUID {
    try validateAccount(accountDID)
    guard let persistence = draftPersistence else { throw ComposerEditingError.persistenceUnavailable }
    let id = try persistence.saveDraft(draft, accountDID: accountDID)
    reloadSavedDrafts()
    scheduleRemotePush(draftId: id, accountDID: accountDID)
    return id
  }

  func deleteSavedDraft(_ draftId: UUID) {
    guard let accountDID = currentAccountDID, let persistence = draftPersistence else { return }
    guard Self.savedDraftClaims[SavedDraftClaimKey(accountDID: accountDID, id: draftId)] == nil else {
      draftSyncIssue = "This draft is open in another composer. Close that editor before deleting it."
      return
    }
    do {
      try persistence.markDeleted(id: draftId, accountDID: accountDID)
      reloadSavedDrafts()
      scheduleRemoteSync(accountDID: accountDID)
    } catch { draftSyncIssue = error.localizedDescription }
  }

  func enableDraftSync() async {
    ExperimentalSettings.shared.draftSyncEnabled = true
    await performRemoteSync()
  }

  func saveRecoveryCopyToBluesky(_ draft: DraftPostViewModel) async {
    guard let account = currentAccountDID, account == draft.accountDID,
          let content = try? draft.decodeDraft() else { return }
    do {
      _ = try createSavedDraft(content, accountDID: account)
      await performRemoteSync()
    } catch { draftSyncIssue = error.localizedDescription }
  }

  var isDraftSyncEnabled: Bool { draftSyncService?.isEnabled ?? false }

  func performRemoteSync() async {
    guard let syncService = draftSyncService, syncService.isEnabled,
          let accountDID = currentAccountDID else { return }
    await syncService.syncDrafts(accountDID: accountDID)
    guard currentAccountDID == accountDID else { return }
    draftSyncIssue = syncService.lastIssue
    reloadSavedDrafts()
  }

  private func scheduleRemotePush(draftId: UUID, accountDID: String) {
    draftSyncService?.schedulePush(draftId: draftId, accountDID: accountDID)
  }

  private func scheduleRemoteSync(accountDID: String) {
    Task { [weak self] in
      guard let self, self.currentAccountDID == accountDID else { return }
      await self.performRemoteSync()
    }
  }

  func loadSavedDrafts() async { reloadSavedDrafts() }

  private func reloadSavedDrafts() {
    guard let persistence = draftPersistence else {
      savedDrafts = []
      draftsLoaded = false
      return
    }
    guard let accountDID = currentAccountDID else {
      savedDrafts = []
      draftsLoaded = true
      return
    }
    do {
      savedDrafts = try persistence.fetchDrafts(for: accountDID).map(DraftPostViewModel.init)
      draftsLoaded = true
    } catch {
      draftSyncIssue = error.localizedDescription
      draftsLoaded = true
    }
  }

  var hasDraftsForCurrentAccount: Bool { draftsLoaded && !savedDrafts.isEmpty }

  // MARK: - Legacy Migration
  
  private let fileManager = FileManager.default

  /// Where earlier versions saved drafts as JSON. A draft whose migration failed stays there, so
  /// draft photo cleanup reads the folder as a store (DraftImageFileJanitor.standard).
  nonisolated static var legacyDraftsDirectoryURL: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Catbird", isDirectory: true)
      .appendingPathComponent("Drafts", isDirectory: true)
  }
  
  /// Migrate legacy JSON drafts to SwiftData (one-time operation)
  private func migrateLegacyDraftsIfNeeded() async {
    logger.info("🔍 Checking if legacy draft migration is needed")
    
    guard !hasMigratedLegacyDrafts else {
      logger.debug("✅ Migration already completed in this session")
      return
    }
    guard let persistence = draftPersistence else {
      logger.warning("⚠️ No persistence - skipping migration")
      return
    }
    
    let migrationKey = "hasMigratedDraftsToSwiftData_v1"
    guard !UserDefaults.standard.bool(forKey: migrationKey) else {
      logger.info("✅ Migration already marked complete in UserDefaults")
      hasMigratedLegacyDrafts = true
      return
    }
    
    logger.info("🔄 Starting legacy draft migration to SwiftData")

    do {
      // Perform file I/O on background thread to avoid blocking main thread
      let legacyDir = Self.legacyDraftsDirectoryURL
      let fm = fileManager

      let jsonFiles: [URL] = try await Task.detached(priority: .utility) {
        // Check if legacy directory exists
        guard let legacyDir, fm.fileExists(atPath: legacyDir.path) else {
          return []
        }

        let fileURLs = try fm.contentsOfDirectory(
          at: legacyDir,
          includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
          options: .skipsHiddenFiles
        )

        return fileURLs.filter { $0.pathExtension == "json" }
      }.value

      guard !jsonFiles.isEmpty else {
        logger.info("ℹ️ No legacy drafts directory or files found - skipping migration")
        Task.detached(priority: .utility) {
          UserDefaults.standard.set(true, forKey: migrationKey)
        }
        hasMigratedLegacyDrafts = true
        return
      }

      logger.info("📄 Found \(jsonFiles.count) legacy JSON draft files to migrate")

      var migratedCount = 0
      var failedCount = 0

      // Use current account DID or a placeholder for orphaned drafts
      let accountDID = await currentAccountDID ?? "unknown_account"
      logger.info("🔑 Using account DID for migration: \(accountDID)")

      for fileURL in jsonFiles {
        do {
          logger.debug("📥 Migrating draft from: \(fileURL.lastPathComponent)")

          // Read file on background thread
          let savedDraft: SavedDraft = try await Task.detached(priority: .utility) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(SavedDraft.self, from: data)
          }.value

          logger.debug("  Draft ID: \(savedDraft.id.uuidString), Created: \(savedDraft.createdDate)")

          // Migrate to SwiftData using the actor
          try await persistence.migrateLegacyDraft(
            id: savedDraft.id,
            draft: savedDraft.draft,
            accountDID: accountDID,
            createdDate: savedDraft.createdDate,
            modifiedDate: savedDraft.modifiedDate
          )

          // Delete legacy JSON file on background thread
          try await Task.detached(priority: .utility) {
            try fm.removeItem(at: fileURL)
          }.value
          migratedCount += 1
          logger.debug("  ✅ Migrated and deleted: \(fileURL.lastPathComponent)")

        } catch {
          logger.error("  ❌ Failed to migrate draft from \(fileURL.lastPathComponent): \(error.localizedDescription)")
          failedCount += 1
        }
      }

      logger.info("✅ Migration complete: \(migratedCount) drafts migrated, \(failedCount) failed")

      // Mark migration as complete on background thread
      Task.detached(priority: .utility) {
        UserDefaults.standard.set(true, forKey: migrationKey)
      }
      hasMigratedLegacyDrafts = true

      // Reload drafts after migration
      logger.debug("📂 Reloading drafts after migration")
      await loadSavedDrafts()

    } catch {
      logger.error("❌ Failed to migrate legacy drafts: \(error.localizedDescription)")
    }
  }
  
}

// MARK: - DraftPostViewModel

/// View model wrapper for DraftPost SwiftData model
struct DraftPostViewModel: Identifiable {
  let id: UUID
  let accountDID: String
  let createdDate: Date
  let modifiedDate: Date
  let previewText: String
  let hasMedia: Bool
  let isReply: Bool
  let isQuote: Bool
  let isThread: Bool
  let isSynced: Bool
  let syncIssue: String?
  let recoveryReason: String?
  let remoteId: String?
  let remoteMediaDeviceName: String?
  let postCount: Int
  let thumbnailURLs: [URL]
  let mediaCount: Int
  let hasVideo: Bool
  
  private let draftData: Data
  
  init(draftPost: DraftPost) {
    self.id = draftPost.id
    self.accountDID = draftPost.accountDID
    self.createdDate = draftPost.createdDate
    self.modifiedDate = draftPost.modifiedDate
    self.previewText = draftPost.previewText
    self.hasMedia = draftPost.hasMedia
    self.isReply = draftPost.isReply
    self.isQuote = draftPost.isQuote
    self.isThread = draftPost.isThread
    let syncState = draftPost.syncMetadata.flatMap { try? JSONDecoder().decode(DraftSyncState.self, from: $0) }
    let content = try? draftPost.decodeDraft()
    self.isSynced = draftPost.remoteId != nil && syncState?.baselineLocal == content
      && syncState?.issue == nil && syncState?.recoveryReason == nil
    self.syncIssue = syncState?.issue
    self.recoveryReason = syncState?.recoveryReason
    self.remoteId = draftPost.remoteId
    self.remoteMediaDeviceName = draftPost.remoteMediaDeviceName
    self.draftData = draftPost.draftData
    if let draft = content {
      let entries = draft.threadEntries
      self.postCount = draft.isThreadMode ? max(1, entries.count) : 1

      let images = draft.mediaItems + entries.flatMap(\.mediaItems)
      let videos = ([draft.videoItem] + entries.map(\.videoItem)).compactMap { $0 }
      let gifs = ([draft.selectedGif] + entries.map(\.selectedGif)).compactMap { $0 }
      self.mediaCount = images.count + videos.count + gifs.count
      self.hasVideo = !videos.isEmpty
      self.thumbnailURLs = images
        .compactMap { $0.rawImageURLString.flatMap(URL.init(string:)) }
        .prefix(3)
        .map { $0 }
    } else {
      self.postCount = 1
      self.thumbnailURLs = []
      self.mediaCount = 0
      self.hasVideo = false
    }
  }
  
  func decodeDraft() throws -> PostComposerDraft {
    let decoder = JSONDecoder()
    return try decoder.decode(PostComposerDraft.self, from: draftData)
  }
}

// MARK: - Legacy SavedDraft Model (for migration only)

private struct SavedDraft: Codable {
  let id: UUID
  let createdDate: Date
  var modifiedDate: Date
  let draft: PostComposerDraft
}
