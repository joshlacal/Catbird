//
//  ComposerDraftManager.swift
//  Catbird
//
//  Created by Claude Code on 8/9/25.
//

import Foundation
import SwiftUI
import Petrel
import OSLog

/// Manager for handling minimized post composer drafts across the app
@Observable
final class ComposerDraftManager {
  /// Current minimized draft with full state (if any)
  var currentDraft: PostComposerDraft?
  
  private let draftKey = "composerMinimizedDraft"
  
  init() {
    loadPersistedDraft()
  }
  
  /// Store a minimized composer draft with full state
  func storeDraft(_ draft: PostComposerDraft) {
    currentDraft = draft
    persistDraft()
  }
  
  /// Store from view model
  @MainActor
  func storeDraft(from viewModel: PostComposerViewModel) {
    let draft = viewModel.saveDraftState()
    storeDraft(draft)
  }
  
  /// Clear the current draft
  func clearDraft() {
    // Clean up any files referenced by the draft (videos/images saved by Share Extension)
    if let draft = currentDraft { cleanUpFiles(for: draft) }
    currentDraft = nil
    UserDefaults.standard.removeObject(forKey: draftKey)
  }

  // MARK: - Cleanup of Shared Draft Files
  private func appGroupContainerURL() -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.blue.catbird.shared")
  }

  private func sharedDraftsDirectory() -> URL? {
    appGroupContainerURL()?.appendingPathComponent("SharedDrafts", isDirectory: true)
  }

  private func cleanUpFiles(for draft: PostComposerDraft) {
    let fm = FileManager.default
    // Video
    if let rawVideo = draft.videoItem?.rawVideoURLString, let url = URL(string: rawVideo) {
      if isInSharedDrafts(url) { try? fm.removeItem(at: url) }
    }
    // Images
    for item in draft.mediaItems {
      if let rawImage = item.rawImageURLString, let url = URL(string: rawImage) {
        if isInSharedDrafts(url) { try? fm.removeItem(at: url) }
      }
    }
  }

  private func isInSharedDrafts(_ url: URL) -> Bool {
    guard let dir = sharedDraftsDirectory() else { return false }
    return url.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path)
  }
  
  /// Check if there's a conflicting draft for a specific context
  func hasConflictingDraft(parentPostURI: String?, quotedPostURI: String?) -> Bool {
    guard let draft = currentDraft else { return false }
    
    let draftParentURI = draft.threadEntries.first?.parentPostURI
    let draftQuotedURI = draft.threadEntries.first?.quotedPostURI
    
    // If trying to create a reply but there's a different reply draft
    if let parentURI = parentPostURI, draftParentURI != parentURI {
      return true
    }
    
    // If trying to create a quote but there's a different quote draft
    if let quotedURI = quotedPostURI, draftQuotedURI != quotedURI {
      return true
    }
    
    // If trying to create a new post but there's a reply/quote draft
    if parentPostURI == nil && quotedPostURI == nil && 
       (draftParentURI != nil || draftQuotedURI != nil) {
      return true
    }
    
    return false
  }
  
  /// Restore draft state to a view model
  @MainActor
  func restoreDraft(to viewModel: PostComposerViewModel) {
    guard let draft = currentDraft else { return }
    viewModel.restoreDraftState(draft)
  }
  
  // MARK: - Persistence
  
  private func persistDraft() {
    guard let draft = currentDraft else {
      UserDefaults.standard.removeObject(forKey: draftKey)
      return
    }
    
    do {
      let encoder = JSONEncoder()
      let data = try encoder.encode(draft)
      UserDefaults.standard.set(data, forKey: draftKey)
    } catch {
      logger.error("Failed to persist composer draft: \(error)")
    }
  }
  
  private func loadPersistedDraft() {
    guard let data = UserDefaults.standard.data(forKey: draftKey) else { return }
    
    do {
      let decoder = JSONDecoder()
      currentDraft = try decoder.decode(PostComposerDraft.self, from: data)
    } catch {
      logger.error("Failed to load persisted composer draft: \(error)")
      UserDefaults.standard.removeObject(forKey: draftKey) // Clear invalid data
    }
  }
  
  private let logger = Logger(subsystem: "blue.catbird", category: "ComposerDraftManager")
}
