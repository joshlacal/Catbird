import NukeUI
import Petrel
import PetrelCatbird
import SwiftUI

struct ScenePeekSheet: View {
  let state: SceneOnboardingViewModel.PeekSheetState
  let selectionWeight: Int
  let isAuthorPinned: (String) -> Bool
  let onTogglePick: () -> Void
  let onToggleBoost: () -> Void
  let onTogglePinAuthor: (String) -> Void
  let onOpenNeighbor: (BlueCatbirdIntelDefs.CommunitySummary) -> Void
  let onClose: () -> Void

  @Environment(\.displayScale) private var displayScale

  private var isPicked: Bool { selectionWeight >= 1 }
  private var isBoosted: Bool { selectionWeight >= 2 }

  var body: some View {
    NavigationStack {
      ScrollView(.vertical) {
        LazyVStack(alignment: .leading, spacing: 20) {
          headerCard

          if state.isLoading {
            VStack(spacing: 12) {
              ProgressView()
              Text("Hydrating live posts & creators…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
          } else {
            samplePostsSection
            membersSection
            if !state.neighbors.isEmpty {
              neighborsSection
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
      }
      .navigationTitle("Scene Peek")
      .inlinePeekToolbarTitle()
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: onClose)
            .accessibilityIdentifier("intel.peek.done")
        }
      }
    }
  }

  private var headerCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Label(state.community.sceneTitle, systemImage: state.community.symbolName)
          .font(.caption.weight(.semibold))
          .lineLimit(1)
          .foregroundStyle(Color.accentColor)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(Color.accentColor.opacity(0.12), in: Capsule())

        Spacer()

        Text("\(state.community.eligibleCount) vetted voices")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      Text(state.community.title)
        .font(.title3.weight(.bold))

      Text(state.community.description)
        .font(.subheadline)
        .foregroundStyle(.secondary)

      HStack(spacing: 10) {
        Button(action: onTogglePick) {
          Label(
            isPicked ? "In Your Orbit" : "Add Scene",
            systemImage: isPicked ? "checkmark.circle.fill" : "plus.circle.fill"
          )
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(isPicked ? Color.accentColor : .white)
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .background(
            isPicked ? Color.accentColor.opacity(0.15) : Color.accentColor,
            in: Capsule()
          )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("intel.peek.togglePick")

        Button(action: onToggleBoost) {
          Label(
            isBoosted ? "Boosted 2×" : "Favorite 2×",
            systemImage: isBoosted ? "heart.fill" : "heart"
          )
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(isBoosted ? .white : .pink)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(
            isBoosted ? Color.pink : Color.pink.opacity(0.12),
            in: Capsule()
          )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("intel.peek.toggleBoost")
      }
    }
    .padding(16)
    .adaptiveGlassEffect(
      style: .regular,
      in: RoundedRectangle(cornerRadius: 20, style: .continuous)
    )
  }

  @ViewBuilder
  private var samplePostsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Recent Community Posts", systemImage: "text.bubble.fill")
          .font(.headline)
        Spacer()
        Text("Tap Pin to lock a creator")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if state.posts.isEmpty {
        Text("Live sample posts are refreshing right now — inspect key community voices below.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(.vertical, 8)
      } else {
        ForEach(state.posts) { post in
          HydratedPostCardView(
            post: post,
            isPinned: isAuthorPinned(post.authorDID),
            onTogglePin: { onTogglePinAuthor(post.authorDID) }
          )
        }
      }
    }
  }

  @ViewBuilder
  private var membersSection: some View {
    if !state.members.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Label("Representative Voices by Role", systemImage: "person.3.sequence.fill")
          .font(.headline)

        ForEach(state.members, id: \.did) { member in
          let didStr = member.did.didString()
          let profile = state.profilesByDID[didStr]
          let role = CommunityRole(rawRole: member.role)
          let pinned = isAuthorPinned(didStr)

          HStack(spacing: 12) {
            AvatarThumbView(
              url: profile?.avatarURL,
              fallbackText: profile?.displayName ?? didStr,
              size: 40,
              scale: displayScale
            )

            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 6) {
                Text(profile?.displayName ?? "Community Creator")
                  .font(.subheadline.weight(.semibold))
                  .lineLimit(1)
                Text(role.badgeTitle)
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(Color.accentColor)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 2)
                  .background(Color.accentColor.opacity(0.12), in: Capsule())
              }
              if let handle = profile?.handle {
                Text("@\(handle)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
              Text(member.whyPicked)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            Button {
              onTogglePinAuthor(didStr)
            } label: {
              Label(pinned ? "Pinned" : "Pin", systemImage: pinned ? "pin.fill" : "pin")
                .font(.caption.weight(.semibold))
                .foregroundStyle(pinned ? .white : Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                  pinned ? Color.accentColor : Color.accentColor.opacity(0.12),
                  in: Capsule()
                )
            }
            .buttonStyle(.plain)
          }
          .padding(10)
          .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .fill(Color.secondary.opacity(0.06))
          )
        }
      }
    }
  }

  private var neighborsSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Adjacent Scenes", systemImage: "point.3.connected.trianglepath.dotted")
        .font(.headline)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(state.neighbors, id: \.communityId) { neighbor in
            Button {
              onOpenNeighbor(neighbor)
            } label: {
              HStack(spacing: 6) {
                Image(systemName: neighbor.symbolName)
                  .font(.caption)
                Text(neighbor.title)
                  .font(.caption.weight(.semibold))
                  .lineLimit(1)
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }
}

private extension View {
  @ViewBuilder
  func inlinePeekToolbarTitle() -> some View {
    #if os(iOS)
    self.toolbarTitleDisplayMode(.inline)
    #else
    self
    #endif
  }
}

// MARK: - Shared Hydrated Post & Avatar Subviews

struct AvatarThumbView: View {
  let url: URL?
  let fallbackText: String
  let size: CGFloat
  let scale: CGFloat

  var body: some View {
    if let url {
      LazyImage(request: ImageRequestFactory.avatar(url, pointSize: size, scale: scale)) { state in
        if let image = state.image {
          image
            .resizable()
            .scaledToFill()
        } else {
          placeholderCircle
        }
      }
      .frame(width: size, height: size)
      .clipShape(Circle())
    } else {
      placeholderCircle
    }
  }

  private var placeholderCircle: some View {
    Circle()
      .fill(Color.accentColor.opacity(0.18))
      .frame(width: size, height: size)
      .overlay(
        Text(String(fallbackText.prefix(1)).uppercased())
          .font(.subheadline.weight(.bold))
          .foregroundStyle(Color.accentColor)
      )
  }
}

struct HydratedPostCardView: View {
  let post: HydratedSamplePost
  let isPinned: Bool
  let onTogglePin: () -> Void

  @Environment(\.displayScale) private var displayScale

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let commTitle = post.communityTitle {
        HStack(spacing: 6) {
          Image(systemName: "sparkles")
            .font(.caption2)
            .foregroundStyle(Color.accentColor)
          Text(commTitle)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
          if let role = post.authorRole {
            Text("· \(role.badgeTitle)")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button(action: onTogglePin) {
            HStack(spacing: 4) {
              Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.caption2.weight(.semibold))
              Text(isPinned ? "Pinned" : "Pin Voice")
                .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(isPinned ? .white : Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
              isPinned ? Color.accentColor : Color.accentColor.opacity(0.12),
              in: Capsule()
            )
          }
          .buttonStyle(.plain)
        }
      }

      HStack(spacing: 10) {
        AvatarThumbView(
          url: post.authorAvatarURL,
          fallbackText: post.authorDisplayName,
          size: 36,
          scale: displayScale
        )

        VStack(alignment: .leading, spacing: 1) {
          Text(post.authorDisplayName)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
          Text("@\(post.authorHandle)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer()

        if post.communityTitle == nil {
          Button(action: onTogglePin) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
              .font(.caption.weight(.semibold))
              .foregroundStyle(isPinned ? Color.accentColor : .secondary)
              .padding(6)
              .background(Color.secondary.opacity(0.1), in: Circle())
          }
          .buttonStyle(.plain)
        }
      }

      if !post.text.isEmpty {
        Text(post.text)
          .font(.subheadline)
          .foregroundStyle(.primary)
          .lineLimit(6)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if !post.imageThumbURLs.isEmpty {
        HStack(spacing: 8) {
          ForEach(post.imageThumbURLs, id: \.absoluteString) { imgURL in
            Color.secondary.opacity(0.12)
              .frame(maxWidth: .infinity)
              .frame(height: 130)
              .overlay {
                LazyImage(url: imgURL) { state in
                  if let image = state.image {
                    image
                      .resizable()
                      .scaledToFill()
                  }
                }
              }
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          }
        }
      }

      HStack(spacing: 16) {
        Label("\(post.replyCount)", systemImage: "bubble.left")
        Label("\(post.repostCount)", systemImage: "arrow.2.squarepath")
        Label("\(post.likeCount)", systemImage: "heart")
      }
      .font(.caption2.monospacedDigit())
      .foregroundStyle(.secondary)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color.secondary.opacity(0.07))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
    )
  }
}
