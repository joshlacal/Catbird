//
//  PostComposerViewUIKit+AccountSwitch.swift
//  Catbird
//

import SwiftUI
import Petrel
import os

private let pcAccountLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Catbird", category: "PostComposerAccount")

extension PostComposerViewUIKit {
  
  /// Handles account switch completion - saves current draft for old account and loads draft for new account
  func handleAccountSwitchComplete(vm: PostComposerViewModel) {
    guard let currentDID = appState.currentUserDID else {
      pcAccountLogger.warning("PostComposerAccount: No current DID after account switch")
      return
    }
    
    pcAccountLogger.info("PostComposerAccount: Account switch completed - new DID: \(currentDID)")
    
    // Save current draft for the old account (if any content exists)
    if hasContent(vm: vm) {
      pcAccountLogger.info("PostComposerAccount: Saving draft for previous account")
      vm.saveDraftIfNeeded()
    }
    
    // The composer view will be recreated with the new account's DID due to .id() modifier
    // This will automatically trigger restoration of any draft for the new account
    pcAccountLogger.debug("PostComposerAccount: Composer will reload with new account context")
  }
}
