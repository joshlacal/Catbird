//
//  ThreadComposePrompt.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2026-08-24.
//

import Petrel
import SwiftUI

/// Sticky bottom quick reply prompt bar for threads ("Write your reply").
struct ThreadComposePrompt: View {
  let post: AppBskyFeedDefs.PostView?
  let appState: AppState
  var onOpenComposer: (() -> Void)?

  @State private var showingComposer = false

  private var isReplyDisabled: Bool {
    guard let post else { return true }
    return post.viewer?.replyDisabled ?? false
  }

  var body: some View {
    HStack(spacing: 12) {
      AvatarView(
        did: appState.userDID,
        client: appState.atProtoClient,
        size: 28,
        avatarURL: appState.currentUserProfile?.finalAvatarURL()
      )
      .clipShape(Circle())

      Text("Write your reply")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    #if os(iOS)
    .adaptiveGlassEffect(style: .regular, in: Capsule(), interactive: true)
    #else
    .background(.ultraThinMaterial, in: Capsule())
    #endif
    .opacity(isReplyDisabled ? 0.6 : 1.0)
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .onTapGesture {
      guard !isReplyDisabled, post != nil else { return }
      if let onOpenComposer {
        onOpenComposer()
      } else {
        showingComposer = true
      }
    }
    .disabled(isReplyDisabled || post == nil)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Compose reply")
    .accessibilityHint("Opens composer")
    .accessibilityAddTraits(.isButton)
    .sheet(isPresented: $showingComposer) {
      if let post {
        PostComposerViewUIKit(
          parentPost: post,
          appState: appState
        )
        .applyAppStateEnvironment(appState)
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator({
          if #available(iOS 26.0, *) { return .visible } else { return .hidden }
        }())
        #endif
      }
    }
  }
}
