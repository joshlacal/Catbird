//
//  ThreadPostEditorView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 12/18/23.
//

import SwiftUI
import Petrel

struct ThreadPostEditorView: View {
  let entry: ThreadEntry
  let entryIndex: Int
  let isCurrentPost: Bool
  let isEditing: Bool
  @Bindable var viewModel: PostComposerViewModel
  let onTap: () -> Void
  let onDelete: () -> Void
  @Environment(AppState.self) private var appState

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      // Avatar
      AvatarView(
        did: appState.currentUserDID,
        client: appState.atProtoClient,
        size: 60
      )
      .id("avatar:\(appState.currentUserDID ?? "unknown"):\(appState.currentUserProfile?.avatar?.description ?? "")")
      .frame(width: 60, height: 60)

      // Text preview (no gray background)
      VStack(alignment: .leading, spacing: 8) {
        if !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text(entry.text)
            .appFont(AppTextRole.body)
            .foregroundColor(.primary)
            .multilineTextAlignment(.leading)
            .lineLimit(6)
        } else {
          Text("Write post \(entryIndex + 1)…")
            .appFont(AppTextRole.body)
            .foregroundStyle(Color.secondary)
            .multilineTextAlignment(.leading)
        }
      }
      .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)

      // Delete (only when multiple)
      if !isEditing && viewModel.threadEntries.count > 1 {
        Button(action: onDelete) {
          Image(systemName: "xmark.circle.fill")
            .appFont(size: 20)
            .foregroundStyle(.white, Color.systemGray3)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .onTapGesture { onTap() }
    .opacity(isCurrentPost ? 1.0 : 0.55)
  }
}
