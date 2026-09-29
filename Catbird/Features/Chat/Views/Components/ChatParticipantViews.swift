import SwiftUI

// MARK: - Participant Picker Components

/// Selectable row for a candidate group-chat participant.
struct ParticipantRow: View {
  let participant: ChatParticipant
  let isSelected: Bool
  var isAvailable: Bool = true
  var unavailableLabel: String = "Chat restricted"
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: DesignTokens.Spacing.base) {
        AsyncProfileImage(
          url: participant.avatarURL,
          size: DesignTokens.Size.avatarMD
        )

        VStack(alignment: .leading, spacing: 4) {
          if let displayName = participant.displayName {
            Text(displayName)
              .designCallout()
              .foregroundColor(.primary)
              .lineLimit(1)
          }

          HStack(spacing: 4) {
            Text("@\(participant.handle)")
              .designCaption()
              .foregroundColor(.secondary)
              .lineLimit(1)

            if !isAvailable {
              Text("• \(unavailableLabel)")
                .designCaption()
                .foregroundColor(.orange)
            }
          }
        }

        Spacer()

        if isAvailable {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 24))
            .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.3))
            .animation(.spring(response: 0.3), value: isSelected)
        } else {
          Image(systemName: "xmark.circle")
            .font(.system(size: 24))
            .foregroundColor(.secondary.opacity(0.3))
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// Removable chip for a selected participant.
struct ParticipantChip: View {
  let participant: ChatParticipant
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.xs) {
      AsyncProfileImage(
        url: participant.avatarURL,
        size: 28
      )

      Text(participant.displayName ?? participant.handle)
        .designCaption()
        .lineLimit(1)

      Button(action: onRemove) {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 16))
          .foregroundColor(.secondary)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(Color.secondary.opacity(0.15))
    .cornerRadius(20)
  }
}

/// Read-only summary of the participants selected for a new group.
struct SelectedParticipantsSummaryList: View {
  let participants: [ChatParticipant]

  var body: some View {
    if participants.isEmpty {
      Text("No participants selected")
        .designCaption()
        .foregroundColor(.secondary)
    } else {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
        ForEach(participants, id: \.id) { participant in
          HStack(spacing: DesignTokens.Spacing.base) {
            AsyncProfileImage(
              url: participant.avatarURL,
              size: DesignTokens.Size.avatarSM
            )

            VStack(alignment: .leading, spacing: 2) {
              Text(participant.displayName ?? participant.handle)
                .designCallout()
                .foregroundColor(.primary)
                .lineLimit(1)
              Text("@\(participant.handle)")
                .designCaption()
                .foregroundColor(.secondary)
                .lineLimit(1)
            }
            Spacer()
          }
        }
      }
    }
  }
}

/// Centered icon + message used for empty search results.
struct EmptyStateRow: View {
  let icon: String
  let message: String

  var body: some View {
    HStack {
      Spacer()
      VStack(spacing: DesignTokens.Spacing.sm) {
        Image(systemName: icon)
          .font(.system(size: 32))
          .foregroundColor(.secondary.opacity(0.5))
        Text(message)
          .designCallout()
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
      }
      .padding(.vertical, 32)
      Spacer()
    }
  }
}
