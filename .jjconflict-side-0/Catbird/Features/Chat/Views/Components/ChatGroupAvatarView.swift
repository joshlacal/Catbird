import NukeUI
import SwiftUI

/// Lightweight identity used to render chat participants (group avatars,
/// recipient pickers, selection chips).
struct ChatParticipant: Identifiable, Hashable, Sendable {
  let id: String
  let handle: String
  let displayName: String?
  let avatarURL: URL?
}

/// Composite avatar for a group conversation: a single avatar for one other
/// member, otherwise a rotated cluster of up to four member avatars.
struct ChatGroupAvatarView: View {
  let participants: [ChatParticipant]
  let size: CGFloat
  var currentUserDID: String? = nil

  // MARK: - Computed Properties

  private var filteredParticipants: [ChatParticipant] {
    if let did = currentUserDID {
      return participants.filter { $0.id != did }
    }
    return participants
  }

  private var bubbleSize: CGFloat { size * 0.42 }

  // MARK: - Body

  var body: some View {
    Group {
      if filteredParticipants.count <= 1 {
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
  private func avatarBubble(_ participant: ChatParticipant) -> some View {
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
  private func placeholderCircle(for participant: ChatParticipant?) -> some View {
    ZStack {
      Circle().fill(Color.gray.opacity(0.2))
      Text(initials(for: participant))
        .font(.system(size: size * 0.4))
        .foregroundColor(.secondary)
    }
  }

  // MARK: - Helpers

  private func initials(for participant: ChatParticipant?) -> String {
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
