//
//  PostComposerViewUIKit+AccountSwitch.swift
//  Catbird
//

import SwiftUI
import Petrel
import os

private let pcAccountLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Catbird", category: "PostComposerAccount")

extension PostComposerViewUIKit {
  
  /// Handles account switch completion - persists current draft and dismisses composer.
  /// The composer MUST be dismissed after account switch because the UIHostingController's
  /// environment still references the OLD AppState. If the composer stays alive, child views
  /// using @Environment(AppState.self) crash with EXC_BREAKPOINT in EnvironmentValues.subscript.getter
  /// during sheet presentation transitions. The new account will re-present the composer
  /// via pendingComposerDraft if a draft was transferred.
  func handleAccountSwitchComplete(vm: PostComposerViewModel) {
    let currentDID = appState.userDID
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

    // Dismiss the composer to prevent @Environment crash.
    // Suppress auto-save since we just saved the draft above.
    suppressAutoSaveOnDismiss = true
    dismiss()
    pcAccountLogger.debug("PostComposerAccount: Composer dismissed after account switch")
  }
}
