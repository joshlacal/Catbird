//
//  ChatFAB.swift
//  Catbird
//
//  Created by Claude on 5/10/25.
//

import SwiftUI

#if os(iOS)

struct ChatFAB: View {
  let newMessageAction: () -> Void
  @Environment(\.composerTransitionNamespace) private var composerNamespace
  // Swap the translucent glass for an opaque accent fill when Reduce
  // Transparency is on, keeping the white glyph legible over the list.
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  private let circleSize: CGFloat = 62

  var body: some View {
    if #available(iOS 26.0, *) {
      newMessageButton
        .clipShape(Circle())
        .chatComposeGlass(reduceTransparency: reduceTransparency)
        .accessibilityLabel("New message")
        .accessibilityHint("Starts a new conversation")
    } else {
      newMessageButton
        .accessibilityLabel("New message")
        .accessibilityHint("Starts a new conversation")
    }
  }

  private var newMessageButton: some View {
    Button(action: newMessageAction) {
      ZStack {
        Image(systemName: "plus")
          .resizable()
          .scaledToFit()
          .frame(width: 30, height: 30)
          .foregroundStyle(.white)
      }
      .frame(width: circleSize, height: circleSize)
      .contentShape(Circle())
    }
    .composerMatchedSource(namespace: composerNamespace)
  }
}

@available(iOS 26.0, *)
private extension View {
  /// Mirrors the home compose FAB's glass styling so the two primary action
  /// buttons stay visually consistent, including the Reduce Transparency fallback.
  @ViewBuilder
  func chatComposeGlass(reduceTransparency: Bool) -> some View {
    if reduceTransparency {
      self.glassEffect(.regular.tint(.accentColor).interactive())
    } else {
      self.glassEffect(.clear.tint(.accentColor).interactive())
    }
  }
}


#Preview("ChatFAB") {
  ZStack {
    Color(.systemGroupedBackground).ignoresSafeArea()
    ChatFAB(newMessageAction: {})
  }
}

#endif
