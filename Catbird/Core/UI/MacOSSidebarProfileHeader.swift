#if os(macOS)
import NukeUI
import Petrel
import SwiftUI

/// Pinned masthead at the top of the macOS sidebar showing the signed-in user's
/// banner, avatar (half-overlapping the banner), display name, and handle.
/// Acts as a single button that selects the `.profile` sidebar item.
struct MacOSSidebarProfileHeader: View {
  let profile: AppBskyActorDefs.ProfileViewDetailed?
  let isSelected: Bool
  let onTap: () -> Void

  private let bannerHeight: CGFloat = 68
  private let avatarSize: CGFloat = 52
  private let cornerRadius: CGFloat = 14
  private let horizontalInset: CGFloat = 12

  var body: some View {
    Button(action: onTap) {
      VStack(spacing: 0) {
        bannerView
          .frame(height: bannerHeight)
          .frame(maxWidth: .infinity)
          .clipped()

        VStack(alignment: .leading, spacing: 1) {
          // Reserve space for the avatar's lower half (26pt) plus breathing room.
          Color.clear.frame(height: 34)

          Text(displayName)
            .font(.headline)
            .fontWeight(.bold)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)

          Text("@\(handle)")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, horizontalInset)
        .padding(.bottom, 12)
      }
      .background(Color(.windowBackgroundColor))
      .overlay(alignment: .topLeading) { avatarView }
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(
            Color.accentColor.opacity(isSelected ? 0.6 : 0),
            lineWidth: 1.5
          )
      )
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("My profile")
    .accessibilityHint("Shows your profile")
    .accessibilityAddTraits(.isButton)
  }

  // MARK: - Banner

  @ViewBuilder
  private var bannerView: some View {
    if let bannerURL = profile?.banner?.url {
      LazyImage(url: bannerURL) { state in
        if let image = state.image {
          image
            .resizable()
            .aspectRatio(contentMode: .fill)
        } else {
          fallbackGradient
        }
      }
    } else {
      fallbackGradient
    }
  }

  private var fallbackGradient: some View {
    LinearGradient(
      gradient: Gradient(colors: [
        Color.accentColor.opacity(0.35),
        Color.accentColor.opacity(0.1)
      ]),
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  // MARK: - Avatar

  @ViewBuilder
  private var avatarView: some View {
    AsyncProfileImage(url: profile?.finalAvatarURL(), size: avatarSize)
      .frame(width: avatarSize, height: avatarSize)
      .overlay(
        Circle().stroke(Color(.windowBackgroundColor), lineWidth: 2)
      )
      .padding(.leading, horizontalInset)
      .padding(.top, bannerHeight - avatarSize / 2)
  }

  // MARK: - Text helpers

  private var displayName: String {
    if let name = profile?.displayName, !name.isEmpty { return name }
    return profile?.handle.description ?? ""
  }

  private var handle: String {
    profile?.handle.description ?? ""
  }
}
#endif
