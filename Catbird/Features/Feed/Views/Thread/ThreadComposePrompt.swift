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
    Button(action: openComposer) {
      HStack(spacing: 12) {
        AvatarView(
          did: appState.userDID,
          client: appState.atProtoClient,
          size: 28,
          avatarURL: appState.currentUserProfile?.finalAvatarURL()
        )
        .clipShape(Circle())
        .fixedSize()
        .accessibilityHidden(true)

        Text("Write your reply")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .frame(minHeight: 44)
      .frame(maxWidth: 520, alignment: .leading)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .modifier(ReplyPromptGlass())
    .opacity(isReplyDisabled ? 0.6 : 1.0)
    // Keep the glass inside the tab bar's outside margins, including at wider sizes.
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
    .disabled(isReplyDisabled)
    .accessibilityLabel("Compose reply")
    .accessibilityHint("Opens composer")
    .accessibilityIdentifier("thread.composeReply")
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

  private func openComposer() {
    guard !isReplyDisabled else { return }
    if let onOpenComposer {
      onOpenComposer()
    } else {
      showingComposer = true
    }
  }
}

private struct ReplyPromptGlass: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
    content.adaptiveGlassEffect(style: .regular, in: Capsule(), interactive: true)
    #else
    content.background(.ultraThinMaterial, in: Capsule())
    #endif
  }
}
