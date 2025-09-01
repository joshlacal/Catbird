//
//  TabViewBottomAccessoryWrapper.swift
//  Catbird
//
//  Created by Claude Code on 8/8/25.
//

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
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
        PostComposerViewUIKit(
          restoringFromDraft: draft,
          appState: appState
        )
      } else {
        // Create new composer
        PostComposerViewUIKit(
          appState: appState
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
  
  private func minimizedComposerButton(draft: PostComposerDraft) -> some View {
    Button(action: {
      showingFullComposer = true
    }) {
      HStack(spacing: 8) {
        // Context indicator based on thread entries
        let hasParent = draft.threadEntries.first?.parentPostURI != nil
        let hasQuoted = draft.threadEntries.first?.quotedPostURI != nil
        
        if hasParent {
          Image(systemName: "arrowshape.turn.up.left")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.accentColor)
        } else if hasQuoted {
          Image(systemName: "quote.bubble")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.accentColor)
        } else {
          Circle()
            .fill(Color.accentColor)
            .frame(width: 8, height: 8)
        }
        
        // Draft content preview
        let previewText = draft.postText.isEmpty ? "Draft in progress..." : draft.postText
        Text("Draft: \(String(previewText.prefix(30)))\(previewText.count > 30 ? "..." : "")")
          .font(.system(size: 14))
          .foregroundColor(.primary)
          .lineLimit(1)
        
        Spacer()
        
        // Media indicators
        let hasMedia = !draft.mediaItems.isEmpty
        let hasVideo = draft.videoItem != nil
        let hasGif = draft.selectedGif != nil
        
        if hasMedia || hasVideo || hasGif {
          HStack(spacing: 4) {
            if hasMedia {
              Image(systemName: "photo")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
              if draft.mediaItems.count > 1 {
                Text("\(draft.mediaItems.count)")
                  .font(.system(size: 10, weight: .semibold))
                  .foregroundColor(.secondary)
              }
            }
            if hasVideo {
              Image(systemName: "video")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            }
            if hasGif {
              Text("GIF")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            }
          }
        }
        
        // Character count
        let remaining = 300 - draft.postText.count
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
  private func getParentPost(for draft: PostComposerDraft) -> AppBskyFeedDefs.PostView? {
    // Lookup deferred: implement URI-based cache fetch via appState when available.
    return nil
  }
  
  private func getQuotedPost(for draft: PostComposerDraft) -> AppBskyFeedDefs.PostView? {
    // Lookup deferred: implement URI-based cache fetch via appState when available.
    return nil
  }
}
