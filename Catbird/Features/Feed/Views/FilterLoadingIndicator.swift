import SwiftUI

struct FilterLoadingIndicator: View {
  var body: some View {
    HStack(spacing: 8) {
      ProgressView()
        .scaleEffect(0.8)

      Text("Applying filters...")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity)
    .background(.ultraThinMaterial)
  }
}
