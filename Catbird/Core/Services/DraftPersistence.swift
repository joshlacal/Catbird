//
//  DraftPersistence.swift
//  Catbird
//
//  Thin wrapper for draft persistence operations using DatabaseModelActor.
//  Operations are delegated to the actor to run off the main thread.
//

import Foundation
import SwiftData
import OSLog

/// Wrapper for draft persistence operations that delegates to DatabaseModelActor.
/// This class provides async methods that run database operations off the main thread.
/// Note: Requires @MainActor for initialization due to ModelContainer.mainContext access.
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
        logger.info("🗄️ DraftPersistence initialized with ModelActor (off main thread)")
    }
    
    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        logger.info("🗄️ DraftPersistence initialized with ModelContainer")
    }
    
    // MARK: - Async CRUD Operations (preferred - run off main thread)
    
    func saveDraftAsync(_ draft: PostComposerDraft, accountDID: String) async throws -> UUID {
        logger.info("💾 saveDraft (async) - Account: \(accountDID)")
        return try await databaseActor.saveDraft(draft, accountDID: accountDID)
    }
    
    func updateDraft(id: UUID, draft: PostComposerDraft, accountDID: String) async throws {
        logger.info("♻️ updateDraft (async) - ID: \(id.uuidString)")
        try await databaseActor.updateDraft(id: id, draft: draft, accountDID: accountDID)
    }
    
    func fetchDraftsAsync(for accountDID: String) async throws -> [DraftPost] {
        logger.debug("📥 fetchDrafts (async) - Account: \(accountDID)")
        return try await databaseActor.fetchDrafts(for: accountDID)
    }
    
    func deleteDraft(id: UUID) async throws {
        logger.info("🗑️ deleteDraft (async) - ID: \(id.uuidString)")
        try await databaseActor.deleteDraft(id: id)
    }
    
    func countDrafts(for accountDID: String) async throws -> Int {
        return try await databaseActor.countDrafts(for: accountDID)
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
        
        return try modelContext.fetch(descriptor)
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
