import SwiftUI
import NukeUI
import CatbirdMLSCore

#if os(iOS)

/// Displays a group avatar for MLS group chats.
/// Shows a custom group avatar image (from encrypted metadata) when available,
/// otherwise falls back to a diamond layout of participant avatars.
struct MLSGroupAvatarView: View {
  let participants: [MLSParticipantViewModel]
  let size: CGFloat
  var groupAvatarData: Data? = nil
  var currentUserDID: String? = nil

  // MARK: - Computed Properties

  private var filteredParticipants: [MLSParticipantViewModel] {
    if let did = currentUserDID {
      return participants.filter { $0.id != did }
    }
    return participants
  }

  private var bubbleSize: CGFloat { size * 0.42 }

  // MARK: - Body

  var body: some View {
    Group {
      if let avatarData = groupAvatarData,
        let uiImage = UIImage(data: avatarData)
      {
        Image(uiImage: uiImage)
          .resizable()
          .scaledToFill()
      } else if filteredParticipants.count <= 1 {
        singleAvatar
      } else if filteredParticipants.count == 2 {
        twoParticipantDiagonal
      } else if filteredParticipants.count == 3 {
        threeParticipantLayout
      } else {
        diamondLayout
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .overlay(Circle().stroke(Color.gray.opacity(0.1), lineWidth: 1))
  }

  // MARK: - Single Avatar

  @ViewBuilder
  private var singleAvatar: some View {
    if let participant = filteredParticipants.first {
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

  // MARK: - Two Participant Diagonal

  @ViewBuilder
  private var twoParticipantDiagonal: some View {
    ZStack {
      avatarBubble(filteredParticipants[0])
        .offset(x: size * 0.16, y: -size * 0.16)
      avatarBubble(filteredParticipants[1])
        .offset(x: -size * 0.16, y: size * 0.16)
    }
    .rotationEffect(.degrees(12))
  }

  // MARK: - Three Participant Layout

  @ViewBuilder
  private var threeParticipantLayout: some View {
    ZStack {
      avatarBubble(filteredParticipants[0])
        .offset(x: 0, y: -size * 0.2)
      avatarBubble(filteredParticipants[1])
        .offset(x: -size * 0.18, y: size * 0.14)
      avatarBubble(filteredParticipants[2])
        .offset(x: size * 0.18, y: size * 0.14)
    }
    .rotationEffect(.degrees(12))
  }

  // MARK: - Diamond Layout

  @ViewBuilder
  private var diamondLayout: some View {
    let display = Array(filteredParticipants.prefix(4))
    let overflow = filteredParticipants.count - 3

    ZStack {
      // Top
      avatarBubble(display[0])
        .offset(x: 0, y: -size * 0.22)
      // Right
      avatarBubble(display[1])
        .offset(x: size * 0.22, y: 0)
      // Bottom
      avatarBubble(display[2])
        .offset(x: 0, y: size * 0.22)
      // Left: 4th participant or overflow counter
      if overflow > 1, display.count > 3 {
        overflowBubble(count: overflow)
          .offset(x: -size * 0.22, y: 0)
      } else if display.count > 3 {
        avatarBubble(display[3])
          .offset(x: -size * 0.22, y: 0)
      }
    }
    .rotationEffect(.degrees(12))
  }

  // MARK: - Avatar Bubble

  @ViewBuilder
  private func avatarBubble(_ participant: MLSParticipantViewModel) -> some View {
    LazyImage(url: participant.avatarURL) { state in
      if let image = state.image {
        image
          .resizable()
          .scaledToFill()
      } else {
        ZStack {
          Circle().fill(Color.gray.opacity(0.2))
          Text(initials(for: participant))
            .font(.system(size: bubbleSize * 0.45))
            .foregroundColor(.secondary)
            .rotationEffect(.degrees(-12))
        }
      }
    }
    .frame(width: bubbleSize, height: bubbleSize)
    .clipShape(Circle())
  }

  // MARK: - Overflow Bubble

  @ViewBuilder
  private func overflowBubble(count: Int) -> some View {
    ZStack {
      Circle().fill(Color.gray.opacity(0.25))
      Text("+\(count)")
        .font(.system(size: bubbleSize * 0.4, weight: .semibold))
        .foregroundColor(.secondary)
        .rotationEffect(.degrees(-12))
    }
    .frame(width: bubbleSize, height: bubbleSize)
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

    let handle = participant.handle.replacingOccurrences(of: "@", with: "")
    return String(handle.prefix(2)).uppercased()
  }
}

// MARK: - Preview

#Preview {
  AsyncPreviewContent { appState in
    VStack(spacing: 20) {
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
          )
        ],
        size: 50,
        currentUserDID: "did:plc:me"
      )

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
          ),
          MLSParticipantViewModel(
            id: "did:plc:5",
            handle: "eve.bsky.social",
            displayName: "Eve",
            avatarURL: nil
          ),
          MLSParticipantViewModel(
            id: "did:plc:6",
            handle: "frank.bsky.social",
            displayName: "Frank",
            avatarURL: nil
          )
        ],
        size: 60,
        currentUserDID: "did:plc:me"
      )
    }
    .padding()
  }
}


#endif
