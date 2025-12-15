//
//  MLSMessageReactionDelegate.swift
//  Catbird
//
//  DEPRECATED: This file previously implemented ExyteChat's ReactionDelegate for MLS conversations.
//  MLS chat now uses the UnifiedChat system with MLSConversationDataSource.
//  Reactions are handled through MLSConversationDataSource.toggleReaction().
//
//  This file is kept for reference but can be removed in a future cleanup.
//

import Foundation

// The MLSMessageReactionDelegate class has been removed as part of the migration
// from ExyteChat to the UnifiedChat system.
//
// For MLS reactions, use:
// - MLSConversationDataSource.toggleReaction(messageID:emoji:) for adding/removing reactions
// - UnifiedMessageReactions view for displaying reactions
// - UnifiedReaction model for reaction data
