//
//  DraftPersistence.swift
//  Catbird
//
//  MainActor class for thread-safe SwiftData draft operations
//

import Foundation
import SwiftData
import OSLog

/// MainActor class for draft persistence operations
/// Uses the shared ModelContext on MainActor
@MainActor
final class DraftPersistence {
  private let logger = Logger(subsystem: "blue.catbird", category: "DraftPersistence")
  private let modelContext: ModelContext
  
  init(modelContext: ModelContext) {
    self.modelContext = modelContext
    logger.info("🗄️ DraftPersistence initialized with shared ModelContext")
  }
  
  // MARK: - CRUD Operations
  
  func saveDraft(_ draft: PostComposerDraft, accountDID: String) throws -> UUID {
    logger.info("💾 saveDraft called - Account: \(accountDID), Post text length: \(draft.postText.count), Media items: \(draft.mediaItems.count)")
    
    let draftPost: DraftPost
    do {
      draftPost = try DraftPost.create(from: draft, accountDID: accountDID)
      logger.debug("  Created DraftPost model - ID: \(draftPost.id.uuidString)")
    } catch {
      logger.error("  ❌ Failed to create DraftPost: \(error.localizedDescription)")
      throw error
    }
    
    modelContext.insert(draftPost)
    logger.debug("  Inserted into model context")
    
    do {
      try modelContext.save()
      modelContext.processPendingChanges()
      logger.info("✅ Saved draft \(draftPost.id.uuidString) for account \(accountDID)")
    } catch {
      logger.error("❌ Failed to save model context: \(error.localizedDescription)")
      throw error
    }
    
    return draftPost.id
  }
  
  func updateDraft(id: UUID, draft: PostComposerDraft, accountDID: String) throws {
    logger.info("♻️ updateDraft called - ID: \(id.uuidString), Account: \(accountDID), Post text length: \(draft.postText.count)")
    
    let predicate = #Predicate<DraftPost> { $0.id == id }
    let descriptor = FetchDescriptor(predicate: predicate)
    
    logger.debug("  Fetching existing draft to update")
    let drafts: [DraftPost]
    do {
      drafts = try modelContext.fetch(descriptor)
    } catch {
      logger.error("❌ Failed to fetch draft for update: \(error.localizedDescription)")
      throw error
    }
    
    guard let existingDraft = drafts.first else {
      logger.error("❌ Draft not found for update - ID: \(id.uuidString)")
      throw DraftError.draftNotFound
    }
    
    logger.debug("  Found existing draft - Preview: '\(existingDraft.previewText.prefix(30))...'")
    
    do {
      let encoder = JSONEncoder()
      let draftData = try encoder.encode(draft)
      
      existingDraft.draftData = draftData
      existingDraft.modifiedDate = Date()
      existingDraft.previewText = String(draft.postText.prefix(200))
      existingDraft.hasMedia = !draft.mediaItems.isEmpty || draft.videoItem != nil
      existingDraft.isReply = draft.threadEntries.first?.parentPostURI != nil
      existingDraft.isQuote = draft.threadEntries.first?.quotedPostURI != nil
      existingDraft.isThread = draft.isThreadMode
      
      logger.debug("  Updated draft properties")
    } catch {
      logger.error("❌ Failed to encode draft data: \(error.localizedDescription)")
      throw error
    }
    
    do {
      try modelContext.save()
      modelContext.processPendingChanges()
      logger.info("✅ Updated draft \(id.uuidString) for account \(accountDID)")
    } catch {
      logger.error("❌ Failed to save updated draft: \(error.localizedDescription)")
      throw error
    }
  }
  
  func fetchDrafts(for accountDID: String) throws -> [DraftPost] {
    logger.info("📥 fetchDrafts called - Account: \(accountDID)")
    
    let predicate = #Predicate<DraftPost> { $0.accountDID == accountDID }
    var descriptor = FetchDescriptor(predicate: predicate)
    descriptor.sortBy = [SortDescriptor(\.modifiedDate, order: .reverse)]
    
    logger.debug("  Executing fetch with predicate (account: \(accountDID), sorted by modifiedDate desc)")
    
    do {
      let drafts = try modelContext.fetch(descriptor)
      logger.info("✅ Fetched \(drafts.count) drafts for account \(accountDID)")
      
      if !drafts.isEmpty {
        logger.debug("  Draft IDs: \(drafts.map { $0.id.uuidString }.joined(separator: ", "))")
      }
      
      return drafts
    } catch {
      logger.error("❌ Failed to fetch drafts: \(error.localizedDescription)")
      throw error
    }
  }
  
  func deleteDraft(id: UUID) throws {
    logger.info("🗑️ deleteDraft called - ID: \(id.uuidString)")
    
    let predicate = #Predicate<DraftPost> { $0.id == id }
    let descriptor = FetchDescriptor(predicate: predicate)
    
    logger.debug("  Fetching draft to delete")
    let drafts: [DraftPost]
    do {
      drafts = try modelContext.fetch(descriptor)
    } catch {
      logger.error("❌ Failed to fetch draft for deletion: \(error.localizedDescription)")
      throw error
    }
    
    guard let draft = drafts.first else {
      logger.error("❌ Draft not found - ID: \(id.uuidString)")
      throw DraftError.draftNotFound
    }
    
    logger.debug("  Found draft - Preview: '\(draft.previewText.prefix(30))...', Account: \(draft.accountDID)")
    
    modelContext.delete(draft)
    logger.debug("  Deleted from context")
    
    do {
      try modelContext.save()
      logger.info("✅ Deleted draft \(id.uuidString)")
    } catch {
      logger.error("❌ Failed to save after deletion: \(error.localizedDescription)")
      throw error
    }
  }
  
  func countDrafts(for accountDID: String) throws -> Int {
    logger.debug("📊 countDrafts called - Account: \(accountDID)")
    
    let predicate = #Predicate<DraftPost> { $0.accountDID == accountDID }
    let descriptor = FetchDescriptor(predicate: predicate)
    
    do {
      let count = try modelContext.fetchCount(descriptor)
      logger.debug("  Count: \(count) drafts for account \(accountDID)")
      return count
    } catch {
      logger.error("❌ Failed to count drafts: \(error.localizedDescription)")
      throw error
    }
  }
  
  // MARK: - Migration
  
  func migrateLegacyDraft(
    id: UUID,
    draft: PostComposerDraft,
    accountDID: String,
    createdDate: Date,
    modifiedDate: Date
  ) throws {
    logger.info("🔄 migrateLegacyDraft called - ID: \(id.uuidString), Account: \(accountDID)")
    logger.debug("  Created: \(createdDate), Modified: \(modifiedDate), Post text length: \(draft.postText.count)")
    
    let draftPost: DraftPost
    do {
      draftPost = try DraftPost.create(from: draft, accountDID: accountDID, id: id)
    } catch {
      logger.error("❌ Failed to create DraftPost during migration: \(error.localizedDescription)")
      throw error
    }
    
    draftPost.createdDate = createdDate
    draftPost.modifiedDate = modifiedDate
    logger.debug("  Set legacy timestamps")
    
    modelContext.insert(draftPost)
    logger.debug("  Inserted into model context")
    
    do {
      try modelContext.save()
      logger.info("✅ Migrated legacy draft \(id.uuidString) for account \(accountDID)")
    } catch {
      logger.error("❌ Failed to save migrated draft: \(error.localizedDescription)")
      throw error
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
