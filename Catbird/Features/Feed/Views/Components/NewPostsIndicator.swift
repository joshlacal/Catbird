//
//  NewPostsIndicator.swift
//  Catbird
//
//  Shows a floating indicator when new posts are available after refresh
//

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct NewPostsIndicator: View {
  // Public API
  let newPostsCount: Int
  let authorAvatars: [String]  // URLs for author avatars
  let onActivate: () -> Void
  var accentColor: Color = .accentColor
  var autoDismissAfter: TimeInterval = 10 // Increased from 5 to 10 seconds
  var reappearCooldown: TimeInterval = 3 // Reduced from 8 to 3 seconds
  var maxAvatarCount: Int = 3
  var allowSilentDismiss: Bool = true
  var accessibilityLabelPrefix: String = "New posts available"

  // Internal state
  @State private var isVisible = false
  @State private var pulse = false
  @State private var lastCount: Int = 0
  @State private var lastDismissDate: Date = .distantPast
  @State private var dismissWorkItem: DispatchWorkItem?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Group {
      if shouldRender {
        content
          .transition(
            .asymmetric(
              insertion: .scale(scale: 0.85).combined(with: .opacity),
              removal: .opacity
            )
          )
          .onAppear { 
            logger.debug("🟢 NEW_POSTS_INDICATOR: NewPostsIndicator content appeared - count=\(newPostsCount), isVisible=\(isVisible)")
            handleAppear() 
          }
          .onDisappear { 
            logger.debug("🔴 NEW_POSTS_INDICATOR: NewPostsIndicator content disappeared")
            cancelAutoDismiss() 
          }
      } else {
        // Add debug for why it's not rendering
        Color.clear
          .onAppear {
            logger.debug("🔴 NEW_POSTS_INDICATOR: shouldRender=false - count=\(newPostsCount), lastCount=\(lastCount), isVisible=\(isVisible), lastDismissDate=\(lastDismissDate)")
          }
      }
    }
    .animation(.spring(response: 0.5, dampingFraction: 0.78), value: shouldRender)
    .onChange(of: newPostsCount) { newValue in
      logger.debug("🔄 NEW_POSTS_INDICATOR: newPostsCount changed from \(lastCount) to \(newValue)")
      guard newValue != lastCount else { return }
      if newValue > lastCount {  // Got more
        logger.debug("🟢 NEW_POSTS_INDICATOR: Showing new batch")
        showNewBatch()
      } else if newValue == 0 {
        logger.debug("🔴 NEW_POSTS_INDICATOR: Dismissing indicator")
        dismiss(animated: true)
      }
      lastCount = newValue
    }
  }

  private var shouldRender: Bool {
    guard newPostsCount > 0 else { return false }
    
    // If this is first appearance or count changed, we should render
    if lastCount == 0 || newPostsCount != lastCount {
      return true
    }
    
    // Cooldown: only suppress if same batch resurfaces too soon
    if Date().timeIntervalSince(lastDismissDate) < reappearCooldown && !isVisible {
      return false
    }
    
    return isVisible
  }

  private var content: some View {
    HStack(spacing: 8) {
      NewPostsAvatarStack(avatarURLs: Array(authorAvatars.prefix(maxAvatarCount)))
      Text(labelText)
        .font(.subheadline.weight(.medium))
        .foregroundColor(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityHidden(true)
      Image(systemName: "arrow.up")
        .font(.subheadline.weight(.semibold))
        .foregroundColor(.white)
        .accessibilityHidden(true)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .background(
      Capsule()
        .fill(accentColor.gradient)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.18), radius: 10, y: 4)
    )
    .contentShape(Rectangle())
    .scaleEffect(isVisible ? 1.0 : 0.85)
    .opacity(isVisible ? 1.0 : 0.0)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabelPrefix + ", " + accessibilityCountLabel)
    .accessibilityAddTraits([.isButton])
    .accessibilityHint(
      "Tap to jump to newest posts" + (allowSilentDismiss ? ", long press to dismiss" : "")
    )
    .onTapGesture { activate() }
    .onLongPressGesture(minimumDuration: 0.35) {
      guard allowSilentDismiss else { return }
      dismiss(animated: true)
    }
  }

  private var labelText: String {
    newPostsCount == 1 ? "1 New Post" : "\(newPostsCount) New Posts"
  }

  private var accessibilityCountLabel: String {
    newPostsCount == 1 ? "1 new post" : "\(newPostsCount) new posts"
  }

  // MARK: - Actions / Lifecycle

  private func handleAppear() {
    // Always show when appearing with posts
    if newPostsCount > 0 {
      lastCount = newPostsCount
      // Delay visibility to allow animation
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) {
          self.isVisible = true
        }
      }
      
      schedulePulse()
      scheduleAutoDismiss()
      PlatformHaptics.impact(.soft)
    }
  }

  private func showNewBatch() {
    isVisible = true
    schedulePulse()
    scheduleAutoDismiss()
    PlatformHaptics.impact(.rigid)
  }

  private func activate() {
    onActivate()
    PlatformHaptics.impact(.medium)
    dismiss(animated: true)
  }

  private func dismiss(animated: Bool) {
    cancelAutoDismiss()
    pulse = false
    if animated {
      withAnimation(.easeOut(duration: 0.18)) {
        isVisible = false
      }
    } else {
      isVisible = false
    }
    lastDismissDate = Date()
  }

  // MARK: - Animations / Timers

  private func schedulePulse() {
    guard !reduceMotion else { return }
    pulse = true
  }

  private func scheduleAutoDismiss() {
    cancelAutoDismiss()
    guard autoDismissAfter > 0 else { return }
    let work = DispatchWorkItem { dismiss(animated: true) }
    dismissWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + autoDismissAfter, execute: work)
  }

  private func cancelAutoDismiss() {
    dismissWorkItem?.cancel()
    dismissWorkItem = nil
  }

  // MARK: - Haptics

  // Haptics now handled by PlatformHaptics utility
}

struct NewPostsAvatarStack: View {
  let avatarURLs: [String]

  var body: some View {
    HStack(spacing: -8) {
      ForEach(Array(avatarURLs.enumerated()), id: \.offset) { index, avatarURL in
        AsyncImage(url: URL(string: avatarURL)) { image in
          image
            .resizable()
            .aspectRatio(contentMode: .fill)
        } placeholder: {
          Circle()
            .fill(Color.gray.opacity(0.3))
            .overlay(
              Image(systemName: "person.fill")
                .font(.caption2)
                .foregroundColor(.gray)
            )
        }
        .frame(width: 24, height: 24)
        .clipShape(Circle())
        .overlay(
          Circle()
            .stroke(Color.white, lineWidth: 2)
        )
        .zIndex(Double(avatarURLs.count - index))
        .accessibilityHidden(true)
      }
    }
    .accessibilityHidden(true)
  }
}

// MARK: - Preview

// MARK: - Preview

#Preview("Responsive New Posts Indicator") {
  VStack(spacing: 24) {
    NewPostsIndicator(
      newPostsCount: 1,
      authorAvatars: ["https://example.com/avatar1.jpg"],
      onActivate: {}
    )
    NewPostsIndicator(
      newPostsCount: 5,
      authorAvatars: [
        "https://example.com/avatar1.jpg",
        "https://example.com/avatar2.jpg",
        "https://example.com/avatar3.jpg",
      ],
      onActivate: {}
    )
    NewPostsIndicator(
      newPostsCount: 12,
      authorAvatars: [
        "https://example.com/avatar1.jpg",
        "https://example.com/avatar2.jpg",
      ],
      onActivate: {}
    )
  }
  .padding()
  .background(Color.gray.opacity(0.1))
}
