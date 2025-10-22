//
//  DraftPost.swift
//  Catbird
//
//  SwiftData model for storing post composer drafts with account scoping
//

import Foundation
import SwiftData
import OSLog


/// SwiftData model for persisting post composer drafts
@Model
final class DraftPost {
    private static let logger = Logger(subsystem: "blue.catbird", category: "DraftPost")

  /// Unique identifier for the draft
  var id: UUID
  
  /// Account DID that owns this draft (for account scoping)
  var accountDID: String
  
  /// Creation timestamp
  var createdDate: Date
  
  /// Last modification timestamp
  var modifiedDate: Date
  
  /// Encoded PostComposerDraft data
  @Attribute(.externalStorage)
  var draftData: Data
  
  /// Cached preview text for list display
  var previewText: String
  
  /// Whether draft contains media
  var hasMedia: Bool
  
  /// Whether draft is a reply
  var isReply: Bool
  
  /// Whether draft is a quote post
  var isQuote: Bool
  
  /// Whether draft is a thread
  var isThread: Bool
  
  init(
    id: UUID = UUID(),
    accountDID: String,
    draftData: Data,
    previewText: String,
    hasMedia: Bool,
    isReply: Bool,
    isQuote: Bool,
    isThread: Bool
  ) {
    self.id = id
    self.accountDID = accountDID
    self.createdDate = Date()
    self.modifiedDate = Date()
    self.draftData = draftData
    self.previewText = previewText
    self.hasMedia = hasMedia
    self.isReply = isReply
    self.isQuote = isQuote
    self.isThread = isThread
    
      DraftPost.logger.info("📝 DraftPost initialized - ID: \(id.uuidString), Account: \(accountDID), Preview: '\(previewText.prefix(50))...', HasMedia: \(hasMedia), IsReply: \(isReply), IsQuote: \(isQuote), IsThread: \(isThread)")
  }
  
  /// Update the modified date (call when draft is edited)
  func touch() {
    let oldDate = modifiedDate
    modifiedDate = Date()
      DraftPost.logger.debug("🔄 DraftPost touched - ID: \(self.id.uuidString), Old modified date: \(oldDate), New modified date: \(self.modifiedDate)")
  }
  
  /// Decode the stored draft data
  func decodeDraft() throws -> PostComposerDraft {
      DraftPost.logger.debug("🔓 Decoding draft - ID: \(self.id.uuidString), Data size: \(self.draftData.count) bytes")
    let decoder = JSONDecoder()
    do {
      let draft = try decoder.decode(PostComposerDraft.self, from: draftData)
        DraftPost.logger.info("✅ Successfully decoded draft - ID: \(self.id.uuidString), Post text length: \(draft.postText.count), Media items: \(draft.mediaItems.count), Has video: \(draft.videoItem != nil)")
      return draft
    } catch {
        DraftPost.logger.error("❌ Failed to decode draft - ID: \(self.id.uuidString), Error: \(error.localizedDescription)")
      throw error
    }
  }
  
  /// Create a DraftPost from a PostComposerDraft
  static func create(
    from draft: PostComposerDraft,
    accountDID: String,
    id: UUID = UUID()
  ) throws -> DraftPost {
    logger.info("🏗️ Creating DraftPost - ID: \(id.uuidString), Account: \(accountDID), Post text length: \(draft.postText.count), Media items: \(draft.mediaItems.count), Thread mode: \(draft.isThreadMode)")
    
    let encoder = JSONEncoder()
    let data: Data
    do {
      data = try encoder.encode(draft)
      logger.debug("📦 Encoded draft data - Size: \(data.count) bytes")
    } catch {
      logger.error("❌ Failed to encode draft - ID: \(id.uuidString), Error: \(error.localizedDescription)")
      throw error
    }
    
    // Generate preview text
    let previewText: String
    if !draft.postText.isEmpty {
      previewText = draft.postText
    } else if !draft.threadEntries.isEmpty, let firstEntry = draft.threadEntries.first {
      previewText = firstEntry.text
    } else if draft.mediaItems.count > 0 {
      previewText = "Draft with \(draft.mediaItems.count) image(s)"
    } else if draft.videoItem != nil {
      previewText = "Draft with video"
    } else if draft.selectedGif != nil {
      previewText = "Draft with GIF"
    } else {
      previewText = "Empty draft"
    }
    
    // Compute metadata flags
    let hasMedia = !draft.mediaItems.isEmpty || draft.videoItem != nil || draft.selectedGif != nil
    let isReply = draft.parentPostURI != nil || draft.threadEntries.first?.parentPostURI != nil
    let isQuote = draft.quotedPostURI != nil || draft.threadEntries.first?.quotedPostURI != nil
    let isThread = draft.isThreadMode && draft.threadEntries.count > 1
    
    logger.debug("📊 Draft metadata computed - Preview: '\(previewText.prefix(30))...', HasMedia: \(hasMedia), IsReply: \(isReply), IsQuote: \(isQuote), IsThread: \(isThread)")
    
    let draftPost = DraftPost(
      id: id,
      accountDID: accountDID,
      draftData: data,
      previewText: previewText,
      hasMedia: hasMedia,
      isReply: isReply,
      isQuote: isQuote,
      isThread: isThread
    )
    
    logger.info("✅ DraftPost created successfully - ID: \(id.uuidString)")
    return draftPost
  }
}
