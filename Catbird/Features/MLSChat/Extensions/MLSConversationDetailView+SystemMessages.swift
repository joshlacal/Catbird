import CatbirdMLSService
//
//  MLSConversationDetailView+SystemMessages.swift
//  Catbird
//
//  DEPRECATED: This extension was used with the legacy ExyteChat system for system messages.
//  MLS chat now uses the unified chat system with MLSConversationDataSource.
//  System messages are handled through the unified message system.
//
//  This file is kept for historical reference but can be removed in a future cleanup.
//

import Foundation

// MARK: - Deprecated Extension

// This extension previously provided system message functionality for the ExyteChat-based
// MLS conversation view. The functionality has been migrated to:
//
// - MLSConversationDataSource for message handling
// - UnifiedChat system for message display
// - MLSSystemMessage models for system events
//
// Usage patterns have changed from:
// - systemMessageToMessage() -> Direct MLSSystemMessage handling
// - messages.append() -> MLSConversationDataSource management
// - ExyteChat Message types -> UnifiedMessage types

#if false // Disabled - legacy ExyteChat extension

extension MLSConversationDetailView {
  // Legacy system message handling code removed
  // See MLSConversationDataSource for current implementation
}

#endif
