import SwiftUI
import NukeUI
import Petrel


// MARK: - Profile Avatar View (Using NukeUI LazyImage)

struct ChatProfileAvatarView: View {
  let profile: ChatBskyActorDefs.ProfileViewBasic?
  let size: CGFloat

  // No need for @State imageLoaded, LazyImage handles its state

  var body: some View {
    let avatarURL = profile?.finalAvatarURL()
    let profileKey = "\(profile?.did.didString() ?? "nil"):\(avatarURL?.absoluteString ?? "nil")"

    Group {
      if let avatarURL {
        LazyImage(url: avatarURL) { state in
          if let image = state.image {
            image
              .resizable()
              .scaledToFill()
          } else {
            // Shown while loading and when the image fails to load
            placeholder
          }
        }
      } else {
        placeholder
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .id(profileKey)
    // Add a subtle border/overlay if desired
    .overlay(Circle().stroke(Color.gray.opacity(0.1), lineWidth: 1))
  }

  private var placeholder: some View {
    ZStack {
      Circle().fill(Color.gray.opacity(0.2))
      Text(initials)
        .appFont(size: size * 0.4)
        .foregroundColor(.secondary)
    }
  }

  // Helper to generate initials from profile display name or handle
  private var initials: String {
    guard let profile = profile else { return "?" }

    if let displayName = profile.displayName,
      !displayName.trimmingCharacters(in: .whitespaces).isEmpty {
      let components = displayName.components(separatedBy: .whitespacesAndNewlines).filter {
        !$0.isEmpty
      }
      if components.count > 1, let first = components.first?.first,
        let last = components.last?.first {
        return String(first).uppercased() + String(last).uppercased()
      } else if let first = displayName.trimmingCharacters(in: .whitespaces).first {
        return String(first).uppercased()
      }
    }

    // Fallback to the handle's first character
    return profile.handle.description.first.map { String($0).uppercased() } ?? "?"
  }
}


#Preview("ChatProfileAvatarView") {
  HStack(spacing: 16) {
    ChatProfileAvatarView(profile: nil, size: 40)
    ChatProfileAvatarView(profile: nil, size: 60)
  }
  .padding()
}
