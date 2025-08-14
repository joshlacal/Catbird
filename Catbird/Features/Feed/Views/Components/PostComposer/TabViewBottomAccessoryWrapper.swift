//
//  TabViewBottomAccessoryWrapper.swift
//  Catbird
//
//  Created by Claude Code on 8/8/25.
//

import SwiftUI
import UIKit
import Petrel

@available(iOS 26.0, *)
struct TabViewBottomAccessoryWrapper: View {
  @Environment(AppState.self) private var appState
  @State private var showingFullComposer = false
  @AppStorage("postComposerDraft") private var draftText = ""
  @AppStorage("postComposerDraftContext") private var draftContext = ""
  
  var body: some View {
    Group {
      if let draft = appState.composerDraftManager.currentDraft {
        // Minimized state with draft indicator
        minimizedComposerButton(draft: draft)
      } else if !draftText.isEmpty {
        // Legacy draft state
        legacyDraftButton
      } else {
        // Normal accessory button
        normalAccessoryButton
      }
    }
    .sheet(isPresented: $showingFullComposer) {
      if let draft = appState.composerDraftManager.currentDraft {
        // Restore minimized composer
        PostComposerView(
          restoringFrom: draft,
          parentPost: getParentPost(for: draft),
          quotedPost: getQuotedPost(for: draft),
          appState: appState,
          onMinimize: { composer in
            appState.composerDraftManager.storeDraft(ComposerDraft(from: composer))
            showingFullComposer = false
          }
        )
      } else {
        // Create new composer
        PostComposerView(
          appState: appState,
          onMinimize: { composer in
            appState.composerDraftManager.storeDraft(ComposerDraft(from: composer))
            showingFullComposer = false
          }
        )
      }
    }
  }
  
  private var normalAccessoryButton: some View {
    Button(action: {
      showingFullComposer = true
      appState.composerDraftManager.clearDraft()  // Clear any minimized state when starting fresh
    }) {
      HStack(spacing: 8) {
        Image(systemName: "square.and.pencil")
          .font(.system(size: 16, weight: .medium))
        
        Text(draftText.isEmpty ? "What's on your mind?" : "Continue writing...")
          .font(.system(size: 15))
          .foregroundColor(.secondary)
        
        Spacer()
        
        if !draftText.isEmpty {
          // Draft indicator
          Circle()
            .fill(Color.accentColor)
            .frame(width: 8, height: 8)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
    .buttonStyle(.plain)
  }
  
  private var legacyDraftButton: some View {
    Button(action: {
      showingFullComposer = true
      appState.composerDraftManager.clearDraft()
    }) {
      HStack(spacing: 8) {
        Circle()
          .fill(Color.accentColor)
          .frame(width: 8, height: 8)
        
        Text("Draft: \(String(draftText.prefix(30)))\(draftText.count > 30 ? "..." : "")")
          .font(.system(size: 14))
          .foregroundColor(.primary)
          .lineLimit(1)
        
        Spacer()
        
        Button(action: {
          draftText = ""
        }) {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 16))
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
    .buttonStyle(.plain)
  }
  
  private func minimizedComposerButton(draft: ComposerDraft) -> some View {
    Button(action: {
      showingFullComposer = true
    }) {
      HStack(spacing: 8) {
        // Context indicator
        if draft.parentPostURI != nil {
          Image(systemName: "arrowshape.turn.up.left")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.accentColor)
        } else if draft.quotedPostURI != nil {
          Image(systemName: "quote.bubble")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.accentColor)
        } else {
          Circle()
            .fill(Color.accentColor)
            .frame(width: 8, height: 8)
        }
        
        // Draft content preview
        let previewText = draft.text.isEmpty ? "Draft in progress..." : draft.text
        Text("Draft: \(String(previewText.prefix(30)))\(previewText.count > 30 ? "..." : "")")
          .font(.system(size: 14))
          .foregroundColor(.primary)
          .lineLimit(1)
        
        Spacer()
        
        // Media indicators
        if draft.hasMedia || draft.hasVideo || draft.hasGif {
          HStack(spacing: 4) {
            if draft.hasMedia {
              Image(systemName: "photo")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
              if draft.mediaCount > 1 {
                Text("\(draft.mediaCount)")
                  .font(.system(size: 10, weight: .semibold))
                  .foregroundColor(.secondary)
              }
            }
            if draft.hasVideo {
              Image(systemName: "video")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            }
            if draft.hasGif {
              Text("GIF")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            }
          }
        }
        
        // Character count
        let remaining = 300 - draft.characterCount
        if remaining < 20 {
          Text("\(remaining)")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(remaining < 0 ? .red : .orange)
        }
        
        // Dismiss button
        Button(action: {
          appState.composerDraftManager.clearDraft()
        }) {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 16))
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
    .buttonStyle(.plain)
  }
  
  // Helper methods to get posts from URIs (simplified - in real implementation would fetch from cache)
  private func getParentPost(for draft: ComposerDraft) -> AppBskyFeedDefs.PostView? {
    // TODO: Implement post lookup by URI from appState cache
    return nil
  }
  
  private func getQuotedPost(for draft: ComposerDraft) -> AppBskyFeedDefs.PostView? {
    // TODO: Implement post lookup by URI from appState cache  
    return nil
  }
}

