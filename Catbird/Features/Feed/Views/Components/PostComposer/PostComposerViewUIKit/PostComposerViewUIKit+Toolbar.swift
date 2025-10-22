//
//  PostComposerViewUIKit+Toolbar.swift
//  Catbird
//

import SwiftUI
import Petrel
import os

private let pcToolbarLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Catbird", category: "PostComposerToolbar")

extension PostComposerViewUIKit {
  
  @ViewBuilder
  func topToolbar(vm: PostComposerViewModel) -> some View {
    HStack(spacing: 12) {
      Button(action: { cancelAction(vm: vm) }) {
        Text("Cancel")
          .appFont(AppTextRole.subheadline)
          .foregroundColor(.primary)
      }
      .buttonStyle(PlainButtonStyle())
      Spacer()
      if isSubmitting {
        ProgressView().progressViewStyle(.circular)
      } else {
        Button(action: { submitAction(vm: vm) }) {
          Text(vm.isThreadMode ? "Post All" : "Post")
            .appFont(AppTextRole.subheadline)
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(canSubmit(vm: vm) ? Color.accentColor : Color.systemGray4)
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .disabled(!canSubmit(vm: vm))
        .buttonStyle(PlainButtonStyle())
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(Color.systemBackground)
  }
}
