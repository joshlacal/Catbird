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

  @Environment(SceneNavigationContext.self) private var sceneContext

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
        // The UIKit-backed avatar has no intrinsic size, so `.fixedSize()` would
        // collapse it to zero width.
        .frame(width: 28, height: 28)
        .clipShape(Circle())
        .accessibilityHidden(true)

        if isReplyDisabled {
          Image(systemName: "lock.fill")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }

        Text(isReplyDisabled ? "Replies to this post are limited" : "Write your reply")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.leading, 8)
      .padding(.trailing, 14)
      .padding(.vertical, 8)
      .frame(minHeight: 44)
      .frame(maxWidth: 400, alignment: .leading)
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
    .accessibilityLabel(isReplyDisabled ? "Replies to this post are limited" : "Compose reply")
    .accessibilityHint(isReplyDisabled ? "" : "Opens composer")
    .accessibilityIdentifier("thread.composeReply")

  }

  private func openComposer() {
    guard !isReplyDisabled else { return }
    if let onOpenComposer {
      onOpenComposer()
    } else {
      sceneContext.presentPostComposer(initialText: nil, parentPost: post, quotedPost: nil)
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
