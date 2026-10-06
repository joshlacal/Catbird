import SwiftUI

/// Shown in place of the reply source while a restored reply draft's original post is loading,
/// or when it can't be loaded, with a way to retry or post the text as a new post.
struct ReplySourceUnavailableView: View {
  let vm: PostComposerViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if vm.parentRestoreFailed {
        Label("The post you’re replying to is unavailable.", systemImage: "exclamationmark.bubble")
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(Color.secondary)
        HStack(spacing: 12) {
          Button("Try Again") { vm.retryParentRestore() }
            .buttonStyle(.bordered)
          Button("Post as New Post") { vm.detachUnavailableParent() }
            .buttonStyle(.bordered)
        }
        .appFont(AppTextRole.subheadline)
      } else {
        HStack(spacing: 8) {
          ProgressView()
          Text("Loading the original post…")
            .appFont(AppTextRole.caption)
            .foregroundStyle(Color.secondary)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("reply-source-loading")
  }
}
