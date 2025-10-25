//
//  ComposerDraftManager.swift
//  Catbird
//
//  Created by Claude Code on 8/9/25.
//

import Foundation
import SwiftUI
import SwiftData
import Petrel
import OSLog

/// Manager for handling post composer drafts across the app
/// 
/// Two types of drafts:
/// - currentDraft: Temporary in-memory draft when user is actively working on a post
/// - savedDrafts: Persistent drafts saved to SwiftData for later retrieval
@Observable
final class ComposerDraftManager {
  /// Current working draft with full state (persisted in UserDefaults while composing)
  var currentDraft: PostComposerDraft?
  
  /// ID of the saved draft that was restored (if any)
  /// This tracks which saved draft should be deleted when discarding or posting
  var restoredSavedDraftId: UUID?
  
  /// Saved drafts for current account (loaded from SwiftData)
  var savedDrafts: [DraftPostViewModel] = []
  
  /// Whether drafts have been loaded (to distinguish from "no drafts" vs "not loaded yet")
  private(set) var draftsLoaded = false
  
  /// AppState reference for getting current account
  private weak var appState: AppState?
  
  /// DraftPersistence actor for SwiftData operations
  private var draftPersistence: DraftPersistence?
  
  private let draftKey = "composerMinimizedDraft"
  private var hasMigratedLegacyDrafts = false
  
  @ObservationIgnored
  private var accountObservation: Task<Void, Never>?
  
  init(appState: AppState? = nil) {
    logger.info("🚀 ComposerDraftManager initializing - Has appState: \(appState != nil)")
    self.appState = appState
    loadPersistedDraft()
    logger.debug("✅ ComposerDraftManager initialized - Current draft loaded: \(self.currentDraft != nil)")
  }
  
  /// Set the model context (called after SwiftData is initialized)
  @MainActor
  func setModelContext(_ context: ModelContext) {
    logger.info("🗄️ Setting model context for draft persistence")
    self.draftPersistence = DraftPersistence(modelContext: context)
    
    // Now that we have persistence, perform migration and load drafts
    Task {
      logger.debug("📂 Starting migration and draft loading tasks")
      await migrateLegacyDraftsIfNeeded()
      await loadSavedDrafts()
    }
  }
  
  /// Update the appState reference (called after AppState initialization)
  func updateAppState(_ appState: AppState?) {
    logger.info("🔄 Updating appState reference - Has appState: \(appState != nil)")
    self.appState = appState
    
    // Cancel previous account observation
    if accountObservation != nil {
      logger.debug("🚫 Cancelling previous account observation")
      accountObservation?.cancel()
    }
    
    // Set up account change observation using AuthenticationManager.stateChanges
    if let appState = appState {
      logger.debug("👀 Setting up account change observation")
      accountObservation = Task { [weak self] in
        guard let self = self else { return }
        var lastDID: String? = nil
        for await state in appState.authManager.stateChanges {
          let currentDID = state.userDID
          // Reload drafts whenever the active DID changes, including logout/login
          if currentDID != lastDID {
            logger.info("🔄 Account DID changed - Old: \(lastDID ?? "nil"), New: \(currentDID ?? "nil")")
            lastDID = currentDID
            await self.loadSavedDrafts()
          }
        }
      }
    }
    
    // If we already have persistence, reload drafts with new account context
    if draftPersistence != nil {
      logger.debug("📂 Reloading drafts with new account context")
      Task {
        await loadSavedDrafts()
      }
    }
  }
  
  // MARK: - Saved Drafts (SwiftData)
  
  /// Save current draft to SwiftData for later retrieval
  func saveCurrentDraftToDisk() {
      logger.info("💾 saveCurrentDraftToDisk called - Has current draft: \(self.currentDraft != nil), Restored draft ID: \(self.restoredSavedDraftId?.uuidString ?? "nil")")
    
    guard let draft = currentDraft else {
      logger.debug("⚠️ No current draft to save")
      return
    }
    guard let accountDID = currentAccountDID else {
      logger.warning("❌ Cannot save draft - no account DID available")
      return
    }
    guard let persistence = draftPersistence else {
      logger.warning("❌ Cannot save draft - persistence not initialized")
      return
    }
    
    logger.info("💾 Saving current draft to disk - Account: \(accountDID), Post text length: \(draft.postText.count)")
    
    Task {
      do {
        // If this draft was restored from a saved draft, update it instead of creating a new one
        if let restoredId = restoredSavedDraftId {
          logger.info("♻️ Updating existing saved draft: \(restoredId.uuidString)")
          try await persistence.updateDraft(id: restoredId, draft: draft, accountDID: accountDID)
          logger.info("✅ Successfully updated draft in SwiftData - ID: \(restoredId.uuidString)")
        } else {
          let draftId = try await persistence.saveDraft(draft, accountDID: accountDID)
          logger.info("✅ Successfully saved new draft to SwiftData - ID: \(draftId.uuidString)")
        }
        
        await MainActor.run {
          currentDraft = nil
          restoredSavedDraftId = nil
          UserDefaults.standard.removeObject(forKey: draftKey)
          logger.debug("🧹 Cleared current draft and UserDefaults entry")
        }
        await loadSavedDrafts()
      } catch {
        logger.error("❌ Failed to save draft to SwiftData: \(error.localizedDescription)")
      }
    }
  }
  
  /// Save a new draft directly to SwiftData
  func createSavedDraft(_ draft: PostComposerDraft) {
    logger.info("📝 createSavedDraft called - Post text length: \(draft.postText.count), Media items: \(draft.mediaItems.count)")
    
    guard let accountDID = currentAccountDID else {
      logger.warning("❌ Cannot create draft - no account DID available")
      return
    }
    guard let persistence = draftPersistence else {
      logger.warning("❌ Cannot create draft - persistence not initialized")
      return
    }
    
    logger.info("💾 Creating new saved draft - Account: \(accountDID)")
    
    Task { @MainActor in
      do {
        let draftId = try persistence.saveDraft(draft, accountDID: accountDID)
        logger.info("✅ Successfully created saved draft - ID: \(draftId.uuidString)")
        await loadSavedDrafts()
      } catch {
        logger.error("❌ Failed to create saved draft: \(error.localizedDescription)")
      }
    }
  }
  
  /// Save a new draft directly to SwiftData and wait for completion
  func createSavedDraftAndWait(_ draft: PostComposerDraft) async {
    logger.info("📝 createSavedDraftAndWait called - Post text length: \(draft.postText.count), Media items: \(draft.mediaItems.count)")
    
    guard let accountDID = currentAccountDID else {
      logger.warning("❌ Cannot create draft - no account DID available")
      return
    }
    guard let persistence = draftPersistence else {
      logger.warning("❌ Cannot create draft - persistence not initialized")
      return
    }
    
    logger.info("💾 Creating new saved draft - Account: \(accountDID)")
    
    do {
      let draftId = try await persistence.saveDraft(draft, accountDID: accountDID)
      logger.info("✅ Successfully created saved draft - ID: \(draftId.uuidString)")
      await loadSavedDrafts()
        logger.info("✅ Draft saved and drafts reloaded - Total drafts: \(self.savedDrafts.count)")
    } catch {
      logger.error("❌ Failed to create saved draft: \(error.localizedDescription)")
    }
  }
  
  /// Load a saved draft (returns the draft for restoration)
  func loadSavedDraft(_ draftViewModel: DraftPostViewModel) -> PostComposerDraft? {
    logger.info("📖 Loading saved draft - ID: \(draftViewModel.id.uuidString), Preview: '\(draftViewModel.previewText.prefix(30))...'")
    
    do {
      let draft = try draftViewModel.decodeDraft()
      logger.info("✅ Successfully loaded draft - ID: \(draftViewModel.id.uuidString), Post text length: \(draft.postText.count), Media items: \(draft.mediaItems.count)")
      
      // Track which saved draft was restored
      restoredSavedDraftId = draftViewModel.id
      logger.debug("  Tracking restored draft ID: \(draftViewModel.id.uuidString)")
      
      return draft
    } catch {
      logger.error("❌ Failed to decode draft - ID: \(draftViewModel.id.uuidString), Error: \(error.localizedDescription)")
      return nil
    }
  }
  
  /// Delete a saved draft
  func deleteSavedDraft(_ draftId: UUID) {
    logger.info("🗑️ Deleting saved draft - ID: \(draftId.uuidString)")
    
    guard let persistence = draftPersistence else {
      logger.warning("❌ Cannot delete draft - persistence not initialized")
      return
    }
    
    Task {
      do {
        try await persistence.deleteDraft(id: draftId)
        logger.info("✅ Successfully deleted draft - ID: \(draftId.uuidString)")
        await loadSavedDrafts()
      } catch {
        logger.error("❌ Failed to delete saved draft - ID: \(draftId.uuidString), Error: \(error.localizedDescription)")
      }
    }
  }
  
  /// Reload all saved drafts for current account from SwiftData
  func loadSavedDrafts() async {
      logger.info("📂 loadSavedDrafts called - Has persistence: \(self.draftPersistence != nil), Account DID: \(self.currentAccountDID ?? "nil")")
    
    guard let persistence = draftPersistence else {
      logger.warning("⚠️ No persistence available - cannot load drafts")
      await MainActor.run { 
        savedDrafts = []
        draftsLoaded = false
      }
      return
    }
    
    guard let accountDID = currentAccountDID else {
      logger.info("ℹ️ No account DID - clearing drafts list")
      await MainActor.run { 
        savedDrafts = []
        draftsLoaded = true
      }
      return
    }
    
    do {
      logger.debug("🔍 Fetching drafts for account: \(accountDID)")
      
      let drafts = try await MainActor.run {
        try persistence.fetchDrafts(for: accountDID)
      }
      logger.info("📥 Fetched \(drafts.count) drafts from persistence")
      
      let viewModels = drafts.map { DraftPostViewModel(draftPost: $0) }
      await MainActor.run {
        savedDrafts = viewModels
        draftsLoaded = true
        logger.info("✅ Loaded \(self.savedDrafts.count) saved drafts for account \(accountDID)")
        
        if !savedDrafts.isEmpty {
          logger.debug("📋 Draft summaries:")
          for vm in savedDrafts.prefix(5) {
            logger.debug("  - ID: \(vm.id.uuidString), Preview: '\(vm.previewText.prefix(30))...', Modified: \(vm.modifiedDate)")
          }
          if savedDrafts.count > 5 {
              logger.debug("  ... and \(self.savedDrafts.count - 5) more")
          }
        }
      }
    } catch {
      logger.error("❌ Failed to load saved drafts for account \(accountDID): \(error.localizedDescription)")
      await MainActor.run { 
        savedDrafts = []
        draftsLoaded = true
      }
    }
  }
  
  /// Check if there are any drafts for the current account
  var hasDraftsForCurrentAccount: Bool {
    draftsLoaded && !savedDrafts.isEmpty
  }
  
  // MARK: - Current Account DID
  
  private var currentAccountDID: String? {
    appState?.authManager.state.userDID
  }
  
  // MARK: - Legacy Migration
  
  private let fileManager = FileManager.default
  private var legacyDraftsDirectory: URL {
    let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let catbirdDir = appSupport.appendingPathComponent("Catbird", isDirectory: true)
    return catbirdDir.appendingPathComponent("Drafts", isDirectory: true)
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
      // Check if legacy directory exists
        logger.debug("📂 Checking legacy drafts directory: \(self.legacyDraftsDirectory.path)")
      
      guard fileManager.fileExists(atPath: legacyDraftsDirectory.path) else {
        logger.info("ℹ️ No legacy drafts directory found - skipping migration")
        UserDefaults.standard.set(true, forKey: migrationKey)
        hasMigratedLegacyDrafts = true
        return
      }
      
      logger.debug("📂 Legacy directory exists - scanning for JSON files")
      let fileURLs = try fileManager.contentsOfDirectory(
        at: legacyDraftsDirectory,
        includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
        options: .skipsHiddenFiles
      )
      
      let jsonFiles = fileURLs.filter { $0.pathExtension == "json" }
      logger.info("📄 Found \(jsonFiles.count) legacy JSON draft files to migrate")
      
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      
      var migratedCount = 0
      var failedCount = 0
      
      // Use current account DID or a placeholder for orphaned drafts
      let accountDID = currentAccountDID ?? "unknown_account"
      logger.info("🔑 Using account DID for migration: \(accountDID)")
      
      for fileURL in jsonFiles {
        do {
          logger.debug("📥 Migrating draft from: \(fileURL.lastPathComponent)")
          let data = try Data(contentsOf: fileURL)
          let savedDraft = try decoder.decode(SavedDraft.self, from: data)
          
          logger.debug("  Draft ID: \(savedDraft.id.uuidString), Created: \(savedDraft.createdDate)")
          
          // Migrate to SwiftData using the actor
          try await persistence.migrateLegacyDraft(
            id: savedDraft.id,
            draft: savedDraft.draft,
            accountDID: accountDID,
            createdDate: savedDraft.createdDate,
            modifiedDate: savedDraft.modifiedDate
          )
          
          // Delete legacy JSON file
          try fileManager.removeItem(at: fileURL)
          migratedCount += 1
          logger.debug("  ✅ Migrated and deleted: \(fileURL.lastPathComponent)")
          
        } catch {
          logger.error("  ❌ Failed to migrate draft from \(fileURL.lastPathComponent): \(error.localizedDescription)")
          failedCount += 1
        }
      }
      
      logger.info("✅ Migration complete: \(migratedCount) drafts migrated, \(failedCount) failed")
      
      // Mark migration as complete
      UserDefaults.standard.set(true, forKey: migrationKey)
      hasMigratedLegacyDrafts = true
      
      // Reload drafts after migration
      logger.debug("📂 Reloading drafts after migration")
      await loadSavedDrafts()
      
    } catch {
      logger.error("❌ Failed to migrate legacy drafts: \(error.localizedDescription)")
    }
  }
  
  // MARK: - Current Draft (In-Memory)
  
  /// Store a minimized composer draft with full state
  func storeDraft(_ draft: PostComposerDraft) {
    logger.info("💾 Storing draft - Post text length: \(draft.postText.count), Media items: \(draft.mediaItems.count), Is thread: \(draft.isThreadMode)")
    currentDraft = draft
    persistDraft()
    logger.debug("✅ Draft stored and persisted to UserDefaults")
  }
  
  /// Store from view model
  @MainActor
  func storeDraft(from viewModel: PostComposerViewModel) {
    logger.info("💾 Storing draft from view model")
    let draft = viewModel.saveDraftState()
    storeDraft(draft)
  }
  
  /// Clear the current draft and delete associated saved draft if applicable
  func clearDraft() {
      logger.info("🧹 Clearing current draft - Has draft: \(self.currentDraft != nil), Restored draft ID: \(self.restoredSavedDraftId?.uuidString ?? "nil")")
    
    // Clean up any files referenced by the draft (videos/images saved by Share Extension)
    if let draft = currentDraft {
      logger.debug("🗑️ Cleaning up files for draft")
      cleanUpFiles(for: draft)
    }
    
    // Delete the saved draft that was restored (if any)
    if let restoredId = restoredSavedDraftId {
      logger.info("🗑️ Deleting restored saved draft: \(restoredId.uuidString)")
      deleteSavedDraft(restoredId)
      restoredSavedDraftId = nil
    }
    
    currentDraft = nil
    UserDefaults.standard.removeObject(forKey: draftKey)
    logger.info("✅ Current draft cleared")
  }

  // MARK: - Cleanup of Shared Draft Files
  private func appGroupContainerURL() -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.blue.catbird.shared")
  }

  private func sharedDraftsDirectory() -> URL? {
    appGroupContainerURL()?.appendingPathComponent("SharedDrafts", isDirectory: true)
  }

  private func cleanUpFiles(for draft: PostComposerDraft) {
    logger.debug("🗑️ Cleaning up draft files")
    let fm = FileManager.default
    var cleanedCount = 0
    
    // Video
    if let rawVideo = draft.videoItem?.rawVideoURLString, let url = URL(string: rawVideo) {
      if isInSharedDrafts(url) {
        logger.debug("  Deleting video: \(url.lastPathComponent)")
        try? fm.removeItem(at: url)
        cleanedCount += 1
      }
    }
    
    // Images
    for item in draft.mediaItems {
      if let rawImage = item.rawImageURLString, let url = URL(string: rawImage) {
        if isInSharedDrafts(url) {
          logger.debug("  Deleting image: \(url.lastPathComponent)")
          try? fm.removeItem(at: url)
          cleanedCount += 1
        }
      }
    }
    
    logger.info("🧹 Cleaned up \(cleanedCount) draft file(s)")
  }

  private func isInSharedDrafts(_ url: URL) -> Bool {
    guard let dir = sharedDraftsDirectory() else { return false }
    return url.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path)
  }
  
  /// Check if there's a conflicting draft for a specific context
  func hasConflictingDraft(parentPostURI: String?, quotedPostURI: String?) -> Bool {
    logger.debug("🔍 Checking for conflicting draft - Parent URI: \(parentPostURI ?? "nil"), Quoted URI: \(quotedPostURI ?? "nil")")
    
    guard let draft = currentDraft else {
      logger.debug("  No current draft - no conflict")
      return false
    }
    
    let draftParentURI = draft.threadEntries.first?.parentPostURI
    let draftQuotedURI = draft.threadEntries.first?.quotedPostURI
    
    logger.debug("  Draft Parent URI: \(draftParentURI ?? "nil"), Draft Quoted URI: \(draftQuotedURI ?? "nil")")
    
    // If trying to create a reply but there's a different reply draft
    if let parentURI = parentPostURI, draftParentURI != parentURI {
      logger.info("⚠️ Conflict detected: Different reply context")
      return true
    }
    
    // If trying to create a quote but there's a different quote draft
    if let quotedURI = quotedPostURI, draftQuotedURI != quotedURI {
      logger.info("⚠️ Conflict detected: Different quote context")
      return true
    }
    
    // If trying to create a new post but there's a reply/quote draft
    if parentPostURI == nil && quotedPostURI == nil && 
       (draftParentURI != nil || draftQuotedURI != nil) {
      logger.info("⚠️ Conflict detected: New post vs reply/quote draft")
      return true
    }
    
    logger.debug("  ✅ No conflict detected")
    return false
  }
  
  /// Check if current draft matches the given context (for auto-restoration)
  func currentDraftMatchesContext(parentPostURI: String?, quotedPostURI: String?) -> Bool {
    logger.debug("🔍 Checking if draft matches context - Parent URI: \(parentPostURI ?? "nil"), Quoted URI: \(quotedPostURI ?? "nil")")
    
    guard let draft = currentDraft else {
      logger.debug("  No current draft")
      return false
    }
    
    let draftParentURI = draft.threadEntries.first?.parentPostURI
    let draftQuotedURI = draft.threadEntries.first?.quotedPostURI
    
    let matches = draftParentURI == parentPostURI && draftQuotedURI == quotedPostURI
    logger.info("  Draft context match: \(matches) - Draft Parent: \(draftParentURI ?? "nil"), Draft Quoted: \(draftQuotedURI ?? "nil")")
    
    return matches
  }
  
  /// Restore draft state to a view model
  @MainActor
  func restoreDraft(to viewModel: PostComposerViewModel) {
    logger.info("🔄 Restoring draft to view model")
    
    guard let draft = currentDraft else {
      logger.warning("⚠️ No current draft to restore")
      return
    }
    
    logger.debug("📥 Restoring draft - Post text length: \(draft.postText.count), Media items: \(draft.mediaItems.count)")
    viewModel.restoreDraftState(draft)
    logger.info("✅ Draft restored to view model")
  }
  
  // MARK: - Persistence
  
  private func persistDraft() {
    logger.debug("💾 Persisting draft to UserDefaults")
    
    guard let draft = currentDraft else {
      logger.debug("  No draft - removing UserDefaults entry")
      UserDefaults.standard.removeObject(forKey: draftKey)
      return
    }
    
    do {
      let encoder = JSONEncoder()
      let data = try encoder.encode(draft)
      UserDefaults.standard.set(data, forKey: draftKey)
      logger.debug("  ✅ Draft persisted - Size: \(data.count) bytes")
    } catch {
      logger.error("  ❌ Failed to persist composer draft: \(error.localizedDescription)")
    }
  }
  
  private func loadPersistedDraft() {
    logger.debug("📖 Loading persisted draft from UserDefaults")
    
    guard let data = UserDefaults.standard.data(forKey: draftKey) else {
      logger.debug("  No persisted draft found in UserDefaults")
      return
    }
    
    logger.debug("  Found persisted draft data - Size: \(data.count) bytes")
    
    do {
      let decoder = JSONDecoder()
      currentDraft = try decoder.decode(PostComposerDraft.self, from: data)
        logger.info("✅ Loaded persisted draft - Post text length: \(self.currentDraft?.postText.count ?? 0), Media items: \(self.currentDraft?.mediaItems.count ?? 0)")
    } catch {
      logger.error("❌ Failed to load persisted composer draft: \(error.localizedDescription)")
      UserDefaults.standard.removeObject(forKey: draftKey) // Clear invalid data
      logger.debug("  Cleared invalid draft data from UserDefaults")
    }
  }
  
  private let logger = Logger(subsystem: "blue.catbird", category: "ComposerDraftManager")
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
    self.draftData = draftPost.draftData
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
