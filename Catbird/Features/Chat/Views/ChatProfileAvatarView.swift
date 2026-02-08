import SwiftUI
import NukeUI
import Petrel
#if os(iOS)


// MARK: - Profile Avatar View (Using NukeUI LazyImage)

struct ChatProfileAvatarView: View {
  let profile: ChatBskyActorDefs.ProfileViewBasic?
  let size: CGFloat

  // No need for @State imageLoaded, LazyImage handles its state

  var body: some View {
    let avatarURL = profile?.finalAvatarURL()

    LazyImage(url: avatarURL) { state in
      if let image = state.image {
        image
          .resizable()
          .scaledToFill()
      } else {
        // Placeholder view
        ZStack {
          Circle().fill(Color.gray.opacity(0.2))
          if state.error != nil {
            Image(systemName: "exclamationmark.circle")  // Error indicator
              .foregroundColor(.red)
          } else {
            Text(initials)
              .appFont(size: size * 0.4)
              .foregroundColor(.secondary)
          }
          // NukeUI doesn't expose isLoading directly in the builder like this,
          // but the placeholder is shown during loading.
        }
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    // Add a subtle border/overlay if desired
    .overlay(Circle().stroke(Color.gray.opacity(0.1), lineWidth: 1))
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

    // Fallback to handle
    return String(profile.handle.description).uppercased()

  }
}#endif
