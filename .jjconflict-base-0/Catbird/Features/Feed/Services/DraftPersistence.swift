//
//  DraftPersistence.swift
//  Catbird
//
//  Account-scoped saved draft persistence and durable sync metadata.
//

import Foundation
import SwiftData
import OSLog

/// Draft editing and synchronization share one context so an in-flight save
/// cannot overwrite a newer sync baseline or deletion tombstone. Legacy import
/// and explicit physical removal retain their existing database actor path.
@MainActor
final class DraftPersistence {
    private let logger = Logger(subsystem: "blue.catbird", category: "DraftPersistence")
    private let modelContainer: ModelContainer
    
    /// Actor for database operations (lazy initialized)
    private lazy var databaseActor: DatabaseModelActor = {
        DatabaseModelActor(modelContainer: modelContainer)
    }()
    
    init(modelContext: ModelContext) {
        // Extract the container from the context to create our own actor
        self.modelContainer = modelContext.container
        logger.info("DraftPersistence initialized with the shared draft context")
    }
    
    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        logger.info("🗄️ DraftPersistence initialized with ModelContainer")
    }
    
    // MARK: - Async CRUD compatibility
    
    func saveDraftAsync(_ draft: PostComposerDraft, accountDID: String) async throws -> UUID {
        logger.info("💾 saveDraft (async) - Account: \(accountDID)")
        return try saveDraft(draft, accountDID: accountDID)
    }
    
    func updateDraft(id: UUID, draft: PostComposerDraft, accountDID: String) async throws {
        logger.info("♻️ updateDraft (async) - ID: \(id.uuidString)")
        guard let model = try fetchDraftModel(id: id), model.accountDID == accountDID,
              try syncState(for: model).deletedAt == nil else { throw DraftError.draftNotFound }
        try model.apply(draft)
        model.touch()
        try modelContainer.mainContext.save()
    }
    
    func fetchDraftsAsync(for accountDID: String) async throws -> [DraftPost] {
        logger.debug("📥 fetchDrafts (async) - Account: \(accountDID)")
        return try fetchDrafts(for: accountDID)
    }
    
    func deleteDraft(id: UUID) async throws {
        logger.info("🗑️ deleteDraft (async) - ID: \(id.uuidString)")
        let referencedVideoURLs = try await databaseActor.deleteDraft(id: id)
        await removeOwnedCapturedVideos(referencedBy: referencedVideoURLs)
    }
    
    func countDrafts(for accountDID: String) async throws -> Int {
        return try fetchDrafts(for: accountDID).count
    }
    
    func migrateLegacyDraft(
        id: UUID,
        draft: PostComposerDraft,
        accountDID: String,
        createdDate: Date,
        modifiedDate: Date
    ) async throws {
        logger.info("🔄 migrateLegacyDraft (async) - ID: \(id.uuidString)")
        try await databaseActor.migrateLegacyDraft(
            id: id,
            draft: draft,
            accountDID: accountDID,
            createdDate: createdDate,
            modifiedDate: modifiedDate
        )
    }
    
    // MARK: - Synchronous CRUD Operations (MainActor - for existing code compatibility)
    
    func saveDraft(_ draft: PostComposerDraft, accountDID: String) throws -> UUID {
        logger.info("💾 saveDraft (sync/MainActor) - Account: \(accountDID)")
        
        // Use main context for synchronous operations (backwards compatibility)
        let modelContext = modelContainer.mainContext
        let draftPost = try DraftPost.create(from: draft, accountDID: accountDID)
        modelContext.insert(draftPost)
        try modelContext.save()
        
        logger.info("✅ Saved draft \(draftPost.id.uuidString)")
        return draftPost.id
    }
    
    func fetchDrafts(for accountDID: String) throws -> [DraftPost] {
        logger.debug("📥 fetchDrafts (sync/MainActor) - Account: \(accountDID)")

        let modelContext = modelContainer.mainContext
        let predicate = #Predicate<DraftPost> { $0.accountDID == accountDID }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\.modifiedDate, order: .reverse)]

        return try modelContext.fetch(descriptor).filter { (try? syncState(for: $0))?.deletedAt == nil }
    }

    // MARK: - Remote Sync Support (MainActor, main context)

    /// Fetch a single draft model by local ID
    func fetchDraftModel(id: UUID) throws -> DraftPost? {
        let modelContext = modelContainer.mainContext
        let predicate = #Predicate<DraftPost> { $0.id == id }
        return try modelContext.fetch(FetchDescriptor(predicate: predicate)).first
    }

    func allDrafts(for accountDID: String) throws -> [DraftPost] {
        let predicate = #Predicate<DraftPost> { $0.accountDID == accountDID }
        return try modelContainer.mainContext.fetch(FetchDescriptor(predicate: predicate))
    }

    func syncState(for model: DraftPost) throws -> DraftSyncState {
        guard let data = model.syncMetadata else { return DraftSyncState() }
        return try JSONDecoder().decode(DraftSyncState.self, from: data)
    }

    func saveSyncState(_ state: DraftSyncState, for model: DraftPost) throws {
        model.syncMetadata = try JSONEncoder().encode(state)
        try modelContainer.mainContext.save()
    }

    /// Keep deletion intent in the same durable row as its remote identity. A
    /// failed request or an app restart cannot re-import a deleted draft.
    func markDeleted(id: UUID, accountDID: String) throws {
        guard let model = try fetchDraftModel(id: id), model.accountDID == accountDID else {
            throw DraftError.draftNotFound
        }
        var state = try syncState(for: model)
        state.deletedAt = Date()
        try saveSyncState(state, for: model)
    }

    @discardableResult
    func preserveRecoveryCopy(of model: DraftPost, reason: String) throws -> UUID {
        let copy = try DraftPost.create(from: model.decodeDraft(), accountDID: model.accountDID)
        copy.createdDate = model.createdDate
        copy.modifiedDate = model.modifiedDate
        copy.remoteMediaDeviceName = model.remoteMediaDeviceName
        var state = try syncState(for: model)
        state.recoveryReason = reason
        state.pendingCreate = nil
        state.deletedAt = nil
        copy.syncMetadata = try JSONEncoder().encode(state)
        modelContainer.mainContext.insert(copy)
        try modelContainer.mainContext.save()
        return copy.id
    }

    /// Materialize a remote-only draft locally with its remote identity attached
    @discardableResult
    func insertRemoteDraft(
        _ draft: PostComposerDraft,
        accountDID: String,
        remoteId: String,
        createdDate: Date,
        modifiedDate: Date,
        syncedAt: Date,
        remoteMediaDeviceName: String? = nil
    ) throws -> UUID {
        let modelContext = modelContainer.mainContext
        let model = try DraftPost.create(from: draft, accountDID: accountDID)
        model.remoteId = remoteId
        model.createdDate = createdDate
        model.modifiedDate = modifiedDate
        model.lastSyncedAt = syncedAt
        model.remoteMediaDeviceName = remoteMediaDeviceName
        modelContext.insert(model)
        try modelContext.save()
        logger.info("⬇️ Materialized remote draft \(remoteId) as local \(model.id.uuidString)")
        return model.id
    }

    /// Remove only capture files owned by Catbird, and only after the saved
    /// draft row deletion has succeeded.
    private func removeOwnedCapturedVideos(referencedBy rawURLs: [String]) async {
        guard let store = try? CapturedVideoStore.applicationStore() else {
            logger.warning("Could not open captured-video storage for post-delete cleanup")
            return
        }

        for rawURL in rawURLs {
            guard let url = URL(string: rawURL), store.owns(url) else { continue }
            do {
                try await store.removeVideoIfOwned(url)
                logger.debug("Removed captured video after saved-draft deletion: \(url.lastPathComponent)")
            } catch {
                logger.error("Failed post-delete captured-video cleanup: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Errors

enum DraftError: LocalizedError {
  case draftNotFound
  case noModelContext
  
  var errorDescription: String? {
    switch self {
    case .draftNotFound:
      return "Draft not found"
    case .noModelContext:
      return "Model context not available"
    }
  }
}
