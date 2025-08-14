//
//  ComposerDraftManager.swift
//  Catbird
//
//  Created by Claude Code on 8/9/25.
//

import Foundation
import SwiftUI
import Petrel

/// Manager for handling minimized post composer drafts across the app
@Observable
final class ComposerDraftManager {
  /// Current minimized draft (if any)
  var currentDraft: ComposerDraft?
  
  /// Store a minimized composer draft
  func storeDraft(_ draft: ComposerDraft) {
    currentDraft = draft
  }
  
  /// Clear the current draft
  func clearDraft() {
    currentDraft = nil
  }
  
  /// Check if there's a conflicting draft for a specific context
  func hasConflictingDraft(parentPostURI: String?, quotedPostURI: String?) -> Bool {
    guard let draft = currentDraft else { return false }
    
    // If trying to create a reply but there's a different reply draft
    if let parentURI = parentPostURI, draft.parentPostURI != parentURI {
      return true
    }
    
    // If trying to create a quote but there's a different quote draft
    if let quotedURI = quotedPostURI, draft.quotedPostURI != quotedURI {
      return true
    }
    
    // If trying to create a new post but there's a reply/quote draft
    if parentPostURI == nil && quotedPostURI == nil && 
       (draft.parentPostURI != nil || draft.quotedPostURI != nil) {
      return true
    }
    
    return false
  }
}

/// Draft structure to persist composer state (moved from TabViewBottomAccessoryWrapper)
@MainActor struct ComposerDraft: Codable {
  let text: String
  let parentPostURI: String?
  let quotedPostURI: String?
  let hasMedia: Bool
  let mediaCount: Int
  let hasVideo: Bool
  let hasGif: Bool
  let characterCount: Int
  
  init(from viewModel: PostComposerViewModel) {
    self.text = viewModel.postText
    self.parentPostURI = viewModel.parentPost?.uri.uriString()
    self.quotedPostURI = viewModel.quotedPost?.uri.uriString()
    self.hasMedia = !viewModel.mediaItems.isEmpty
    self.mediaCount = viewModel.mediaItems.count
    self.hasVideo = viewModel.videoItem != nil
    self.hasGif = viewModel.selectedGif != nil
    self.characterCount = viewModel.characterCount
  }
}
