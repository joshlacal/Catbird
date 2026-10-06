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
  @ObservationIgnored @Environment(AppState.self) private var appState
  @Environment(SceneNavigationContext.self) private var sceneContext
  @State private var showingFullComposer = false
  @State private var composerInitialClaim: ComposerDraftClaim?
  @State private var showingLegacyRecovery = false
  private var editingSession: SceneComposerEditingSession { sceneContext.composerEditingSession }
  
  var body: some View {
    Group {
      if let draft = editingSession.currentDraft, editingSession.isMinimized {
        minimizedComposerButton(draft: draft)
      } else {
        VStack(spacing: 0) {
          normalAccessoryButton
          if editingSession.hasLegacyRecovery {
            Button("Recover Earlier Draft") { showingLegacyRecovery = true }
              .font(.footnote)
              .padding(.bottom, 8)
          }
        }
      }
    }
    .sheet(isPresented: $showingFullComposer) {
      PostComposerViewUIKit(
        appState: appState,
        editingSession: editingSession,
        editingClaim: composerInitialClaim
      )
      .toastContainer(using: appState.toastManager)
    }
    .confirmationDialog("Recover Earlier Draft?", isPresented: $showingLegacyRecovery, titleVisibility: .visible) {
      Button("Recover for Current Account") {
        do {
          composerInitialClaim = try editingSession.recoverLegacyDraft()
          showingFullComposer = true
        } catch {
          appState.toastManager.show(ToastItem(
            message: error.localizedDescription, icon: "exclamationmark.triangle.fill"
          ))
        }
      }
      Button("Cancel", role: .cancel) { }
    } message: {
      Text("This earlier draft has no verified account. Recovering it opens a copy for your current account in this window.")
    }
  }

  private var normalAccessoryButton: some View {
    Button(action: {
      composerInitialClaim = nil
      showingFullComposer = true
    }) {
      HStack(spacing: 8) {
        Image(systemName: "square.and.pencil")
          .font(.system(size: 16, weight: .medium))
        Text("What’s on your mind?")
          .font(.system(size: 15))
          .foregroundColor(.secondary)
        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
    .buttonStyle(.plain)
  }

  private func minimizedComposerButton(draft: PostComposerDraft) -> some View {
    Button(action: {
      guard let snapshot = editingSession.snapshot() else { return }
      composerInitialClaim = snapshot.claim
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
        let previewText = draft.postText.isEmpty ? "Draft in progress…" : draft.postText
        Text("Draft: \(String(previewText.prefix(30)))\(previewText.count > 30 ? "…" : "")")
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
          if let claim = editingSession.activeClaim {
            _ = editingSession.discard(claim: claim)
          }
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
  

}

@available(iOS 26.0, macOS 26.0, *)
#Preview("Tab Accessory Wrapper") {
  TabViewBottomAccessoryWrapper()
    .previewWithAuthenticatedState()
}
