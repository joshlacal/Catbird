import SwiftUI

struct VoiceRecordingOverlay: View {
  let duration: TimeInterval
  let onCancel: () -> Void
  let onSend: () -> Void

  @State private var pulseScale: CGFloat = 1.0

  var body: some View {
    HStack(spacing: 16) {
      // Cancel button
      Button(action: onCancel) {
        Image(systemName: "xmark.circle.fill")
          .appFont(AppTextRole.title2)
          .foregroundStyle(.secondary)
      }
      .accessibilityLabel("Cancel recording")

      // Recording indicator + duration
      HStack(spacing: 8) {
        Circle()
          .fill(Color.red)
          .frame(width: 10, height: 10)
          .scaleEffect(pulseScale)
          .animation(
            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
            value: pulseScale
          )

        Text(formattedDuration)
          .appFont(AppTextRole.body).monospacedDigit()
          .foregroundStyle(.primary)
      }

      Spacer()

      // Send button
      Button(action: onSend) {
        Image(systemName: "arrow.up.circle.fill")
          .appFont(AppTextRole.title2)
          .foregroundStyle(Color.accentColor)
      }
      .accessibilityLabel("Send voice message")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(
      Capsule()
        .fill(Color.red.opacity(0.08))
        .overlay(
          Capsule()
            .stroke(Color.red.opacity(0.3), lineWidth: 1)
        )
    )
    .onAppear {
      pulseScale = 1.3
    }
  }

  private var formattedDuration: String {
    Duration.seconds(max(0, Int(duration))).formatted(.time(pattern: .minuteSecond))
  }
}

#Preview {
  VStack {
    Spacer()
    VoiceRecordingOverlay(
      duration: 12.5,
      onCancel: {},
      onSend: {}
    )
    .padding()
  }
}
