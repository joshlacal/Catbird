//
//  PostComposerViewUIKit+AccountSwitch.swift
//  Catbird
//

import SwiftUI
import Petrel
import os

private let pcAccountLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Catbird", category: "PostComposerAccount")

extension PostComposerViewUIKit {
  
  /// Handles account switch completion - persists current draft to carry over to new account
  func handleAccountSwitchComplete(vm: PostComposerViewModel) {
    guard let currentDID = appState.currentUserDID else {
      pcAccountLogger.warning("PostComposerAccount: No current DID after account switch")
      return
    }
    
    pcAccountLogger.info("PostComposerAccount: Account switch completed - new DID: \(currentDID)")
    
    // Save current draft state to carry over to the new account
    if hasContent(vm: vm) {
      pcAccountLogger.info("PostComposerAccount: Persisting draft to carry over to new account")
      let draft = vm.saveDraftState()
      appState.composerDraftManager.storeDraft(draft)
      // Clear the restored draft ID since we're switching accounts
      appState.composerDraftManager.restoredSavedDraftId = nil
    } else {
      pcAccountLogger.debug("PostComposerAccount: No content to persist")
    }
    
    // The composer view will be recreated with the new account's DID due to .id() modifier
    // The .task block will automatically restore the current draft for the new account
    pcAccountLogger.debug("PostComposerAccount: Composer will reload with new account context and restore current draft")
  }
}
