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
  @Environment(\.colorScheme) private var colorScheme

  init(
    post: AppBskyFeedDefs.PostView?,
    appState: AppState,
    onOpenComposer: (() -> Void)? = nil
  ) {
    self.post = post
    self.appState = appState
    self.onOpenComposer = onOpenComposer
  }

  private var isReplyDisabled: Bool {
    guard let post else { return true }
    return post.viewer?.replyDisabled ?? false
  }

  var body: some View {
    VStack(spacing: 0) {
      Divider()

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
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(
        Capsule()
          .fill(Color(platformColor: PlatformColor.platformSecondarySystemBackground))
      )
      .opacity(isReplyDisabled ? 0.6 : 1.0)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }
    .background(
      Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme)
    )
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
        Group {
          PostComposerViewUIKit(
            parentPost: post,
            appState: appState
          )
          .applyAppStateEnvironment(appState)
          #if os(iOS)
          .presentationDetents({
            if #available(iOS 26.0, *) { return [.large] } else { return [PresentationDetent.large] }
          }())
          .presentationDragIndicator({
            if #available(iOS 26.0, *) { return .visible } else { return .hidden }
          }())
          #endif
        }
      }
    }
  }
}
