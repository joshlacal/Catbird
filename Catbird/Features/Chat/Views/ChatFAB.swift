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

  private let circleSize: CGFloat = 62

  var body: some View {
    if #available(iOS 26.0, *) {
      newMessageButton
        .clipShape(Circle())
        .glassEffect(.regular.tint(.accentColor).interactive())
    } else {
      newMessageButton
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

#endif
