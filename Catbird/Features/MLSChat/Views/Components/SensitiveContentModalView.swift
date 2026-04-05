import SwiftUI

struct SensitiveContentModalView: View {
  let image: PlatformImage
  let canReveal: Bool
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

        if canReveal {
          Text("Someone sent you an image that may not be appropriate. You can choose to view it or go back.")
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        } else {
          Text("This image has been hidden because it may contain nudity or adult content.")
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }

        Spacer()

        VStack(spacing: 12) {
          Button("Go Back", role: .cancel, action: onDismiss)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

          if canReveal {
            Button("Show Image", action: onReveal)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
      }
      .padding(32)
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
    }
  }
}
