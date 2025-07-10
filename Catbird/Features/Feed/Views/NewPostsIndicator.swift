//
//  NewPostsIndicator.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/4/25.
//

import SwiftUI
import Petrel

struct NewPostsIndicator: View {
  let authors: [AppBskyActorDefs.ProfileViewBasic]
  let onTap: () -> Void
  @Environment(AppState.self) private var appState: AppState
  
  @State private var dismissTimer: Timer?
  @State private var isVisible = true

  private var avatarStack: some View {
    HStack(spacing: -8) {
      ForEach(Array(authors.prefix(3).enumerated()), id: \.element.did) { index, author in
        authorAvatar(author: author, index: index)
      }
    }
  }

  private func authorAvatar(author: AppBskyActorDefs.ProfileViewBasic, index: Int) -> some View {
    AsyncImage(url: author.finalAvatarURL()) { image in
      image
        .resizable()
        .aspectRatio(contentMode: .fill)
    } placeholder: {
      Circle()
        .fill(Color.gray.opacity(0.3))
    }
    .frame(width: 24, height: 24)
    .clipShape(Circle())
    .overlay(
      Circle()
        .stroke(Color.white, lineWidth: 1.5)
    )
    .zIndex(Double(authors.count - index))
  }

  private var textContent: some View {
    HStack(spacing: 4) {
      Text(authors.count == 1 ? "New post" : "\(authors.count) new posts")
        .font(.system(size: 14, weight: .medium))
        .foregroundColor(.white)

      Image(systemName: "arrow.up")
        .font(.system(size: 12, weight: .bold))
        .foregroundColor(.white)
    }
  }

  private var buttonBackground: some View {
    Capsule()
      .fill(Color.blue)
      .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
  }

  var body: some View {
    if isVisible {
      Button(action: {
        onTap()
        dismissIndicator()
      }) {
        HStack(spacing: 8) {
          avatarStack
          textContent
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(buttonBackground)
      }
      .buttonStyle(PlainButtonStyle())
      .transition(.asymmetric(
        insertion: .scale.combined(with: .opacity),
        removal: .scale.combined(with: .opacity)
      ))
      .animation(.easeInOut(duration: 0.3), value: isVisible)
      .onAppear {
        startAutoDismissTimer()
      }
      .onDisappear {
        dismissTimer?.invalidate()
        dismissTimer = nil
      }
    }
  }
  
  private func startAutoDismissTimer() {
    dismissTimer?.invalidate()
    dismissTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { _ in
      dismissIndicator()
    }
  }
  
  private func dismissIndicator() {
    dismissTimer?.invalidate()
    dismissTimer = nil
    withAnimation(.easeInOut(duration: 0.3)) {
      isVisible = false
    }
  }
}
