import SwiftUI
import NukeUI
import CatbirdMLSService

#if os(iOS)

/// Displays a composite avatar for MLS group chats
struct MLSGroupAvatarView: View {
  let participants: [MLSParticipantViewModel]
  let size: CGFloat

  var body: some View {
    Group {
      if participants.count <= 1 {
        // Single participant - show regular avatar
        singleAvatar
      } else if participants.count == 2 {
        // Two participants - side by side
        twoParticipantGrid
      } else {
        // Three or more - 2x2 grid
        multiParticipantGrid
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .overlay(Circle().stroke(Color.gray.opacity(0.1), lineWidth: 1))
  }

  // MARK: - Single Avatar

  @ViewBuilder
  private var singleAvatar: some View {
    if let participant = participants.first {
      LazyImage(url: participant.avatarURL) { state in
        if let image = state.image {
          image
            .resizable()
            .scaledToFill()
        } else {
          placeholderCircle(for: participant)
        }
      }
      .frame(width: size, height: size)
    } else {
      placeholderCircle(for: nil)
    }
  }

  // MARK: - Two Participant Grid

  @ViewBuilder
  private var twoParticipantGrid: some View {
    HStack(spacing: 0) {
      participantAvatar(participants[0], size: size / 2)
      participantAvatar(participants[1], size: size / 2)
    }
  }

  // MARK: - Multi Participant Grid

  @ViewBuilder
  private var multiParticipantGrid: some View {
    let gridSize = size / 2
    let displayParticipants = Array(participants.prefix(4))

    VStack(spacing: 0) {
      HStack(spacing: 0) {
        participantAvatar(displayParticipants[0], size: gridSize)
        if displayParticipants.count > 1 {
          participantAvatar(displayParticipants[1], size: gridSize)
        }
      }

      if displayParticipants.count > 2 {
        HStack(spacing: 0) {
          participantAvatar(displayParticipants[2], size: gridSize)
          if displayParticipants.count > 3 {
            participantAvatar(displayParticipants[3], size: gridSize)
          }
        }
      }
    }
  }

  // MARK: - Participant Avatar

  @ViewBuilder
  private func participantAvatar(_ participant: MLSParticipantViewModel, size: CGFloat) -> some View {
    LazyImage(url: participant.avatarURL) { state in
      if let image = state.image {
        image
          .resizable()
          .scaledToFill()
      } else {
        placeholderSquare(for: participant, size: size)
      }
    }
    .frame(width: size, height: size)
  }

  // MARK: - Placeholders

  @ViewBuilder
  private func placeholderCircle(for participant: MLSParticipantViewModel?) -> some View {
    ZStack {
      Circle().fill(Color.gray.opacity(0.2))
      Text(initials(for: participant))
        .font(.system(size: size * 0.4))
        .foregroundColor(.secondary)
    }
  }

  @ViewBuilder
  private func placeholderSquare(for participant: MLSParticipantViewModel, size: CGFloat) -> some View {
    ZStack {
      Rectangle().fill(Color.gray.opacity(0.2))
      Text(initials(for: participant))
        .font(.system(size: size * 0.5))
        .foregroundColor(.secondary)
    }
  }

  // MARK: - Helpers

  private func initials(for participant: MLSParticipantViewModel?) -> String {
    guard let participant = participant else { return "?" }

    if let displayName = participant.displayName, !displayName.isEmpty {
      let components = displayName.split(separator: " ")
      if components.count >= 2 {
        let first = components[0].prefix(1)
        let last = components[1].prefix(1)
        return "\(first)\(last)".uppercased()
      } else {
        return String(displayName.prefix(2)).uppercased()
      }
    }

    // Fallback to handle
    let handle = participant.handle.replacingOccurrences(of: "@", with: "")
    return String(handle.prefix(2)).uppercased()
  }
}

// MARK: - Preview

#Preview {
    @Previewable @Environment(AppState.self) var appState
  VStack(spacing: 20) {
    // Single participant
    MLSGroupAvatarView(
      participants: [
        MLSParticipantViewModel(
          id: "did:plc:1",
          handle: "alice.bsky.social",
          displayName: "Alice",
          avatarURL: nil
        )
      ],
      size: 50
    )

    // Two participants
    MLSGroupAvatarView(
      participants: [
        MLSParticipantViewModel(
          id: "did:plc:1",
          handle: "alice.bsky.social",
          displayName: "Alice",
          avatarURL: nil
        ),
        MLSParticipantViewModel(
          id: "did:plc:2",
          handle: "bob.bsky.social",
          displayName: "Bob",
          avatarURL: nil
        )
      ],
      size: 50
    )

    // Four participants
    MLSGroupAvatarView(
      participants: [
        MLSParticipantViewModel(
          id: "did:plc:1",
          handle: "alice.bsky.social",
          displayName: "Alice",
          avatarURL: nil
        ),
        MLSParticipantViewModel(
          id: "did:plc:2",
          handle: "bob.bsky.social",
          displayName: "Bob",
          avatarURL: nil
        ),
        MLSParticipantViewModel(
          id: "did:plc:3",
          handle: "charlie.bsky.social",
          displayName: "Charlie",
          avatarURL: nil
        ),
        MLSParticipantViewModel(
          id: "did:plc:4",
          handle: "diana.bsky.social",
          displayName: "Diana",
          avatarURL: nil
        )
      ],
      size: 50
    )
  }
  .padding()
}

#endif
