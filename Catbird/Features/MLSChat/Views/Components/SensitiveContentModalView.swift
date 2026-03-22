import SwiftUI

struct SensitiveContentModalView: View {
  let image: UIImage
  let onReveal: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 48))
          .foregroundStyle(.yellow)

        Text("This image may contain sensitive content")
          .font(.headline)
          .multilineTextAlignment(.center)

        Text("Someone sent you an image that may not be appropriate. You can choose to view it or go back.")
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)

        Spacer()

        VStack(spacing: 12) {
          Button("Go Back", role: .cancel, action: onDismiss)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

          Button("Show Image", action: onReveal)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .padding(32)
      .navigationBarTitleDisplayMode(.inline)
    }
  }
}
