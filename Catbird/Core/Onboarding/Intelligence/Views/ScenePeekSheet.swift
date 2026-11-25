import NukeUI
import Petrel
import PetrelCatbird
import SwiftUI

struct ScenePeekSheet: View {
  let state: SceneOnboardingViewModel.PeekSheetState
  let selectionWeight: Int
  /// The scene's members split where the lineup stops; nil while the sheet has no scene open.
  let memberSections: SceneOnboardingViewModel.PeekMemberSections?
  /// The heading over the members a pick follows, given how many there are.
  let lineupHeading: (Int) -> String
  let profilesByDID: [String: HydratedRecommendedProfile]
  let isAuthorPinned: (String) -> Bool
  let onTogglePick: () -> Void
  let onToggleBoost: () -> Void
  let onTogglePinAuthor: (String) -> Void
  let onOpenNeighbor: (BlueCatbirdIntelDefs.CommunitySummary) -> Void
  let onMemberAppear: (String) -> Void
  let onClose: () -> Void

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
                .appFont(AppTextRole.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
          } else {
            membersSection
            samplePostsSection
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
        CatbirdBadge(
          Text(verbatim: state.community.sceneTitle), systemImage: state.community.symbolName,
          tone: .accent)

        Spacer()

        Text("\(state.community.eligibleCount) vetted voices", comment: "Count of vetted accounts in scene peek header.")
          .appFont(AppTextRole.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }

      Text(state.community.title)
        .appFont(AppTextRole.title3)
        .fontWeight(.bold)

      Text(state.community.description)
        .appFont(AppTextRole.subheadline)
        .foregroundStyle(.secondary)

      if let alreadyFollowing = SceneOnboardingViewModel.alreadyFollowingLine(
        count: state.community.alreadyFollowingCount
      ) {
        Label(alreadyFollowing, systemImage: "person.crop.circle.badge.checkmark")
          .appFont(AppTextRole.footnote)
          .fontWeight(.medium)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("intel.peek.alreadyFollowing")
      }

      HStack(spacing: 10) {
        Button(action: onTogglePick) {
          Group {
            if isPicked {
              Label {
                Text("In Your Orbit", comment: "Button state showing scene is selected in onboarding.")
              } icon: {
                Image(systemName: "checkmark.circle.fill")
              }
            } else {
              Label {
                Text("Add Scene", comment: "Button action to add scene in onboarding.")
              } icon: {
                Image(systemName: "plus.circle.fill")
              }
            }
          }
        }
        .buttonStyle(.catbird(isPicked ? .tonal : .primary, size: .md))
        .accessibilityIdentifier("intel.peek.togglePick")

        Button(action: onToggleBoost) {
          Group {
            if isBoosted {
              Label {
                Text("Boosted 2×", comment: "Button state showing scene is heart-boosted 2x.")
              } icon: {
                Image(systemName: "heart.fill")
              }
            } else {
              Label {
                Text("Favorite 2×", comment: "Button action to heart-boost scene 2x.")
              } icon: {
                Image(systemName: "heart")
              }
            }
          }
        }
        .buttonStyle(.catbird(isBoosted ? .tonal : .outline, size: .md))
        .accessibilityIdentifier("intel.peek.toggleBoost")
      }
    }
    .padding(16)
    .adaptiveGlassEffect(
      style: .regular,
      in: Radius.xl.shape
    )
  }

  @ViewBuilder
  private var samplePostsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Recent Community Posts", systemImage: "text.bubble.fill")
          .appFont(AppTextRole.headline)
        Spacer()
        Text("Tap Pin to lock a creator")
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
      }

      if state.posts.isEmpty {
        Text("Live sample posts are refreshing right now — inspect key community voices below.")
          .appFont(AppTextRole.footnote)
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
    if let memberSections {
      ScenePeekMembersSection(
        sections: memberSections,
        isScenePicked: isPicked,
        lineupHeading: lineupHeading(memberSections.lineup.count),
        profilesByDID: profilesByDID,
        isAuthorPinned: isAuthorPinned,
        onTogglePinAuthor: onTogglePinAuthor,
        onMemberAppear: onMemberAppear
      )
    }
  }

  private var neighborsSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Adjacent Scenes", systemImage: "point.3.connected.trianglepath.dotted")
        .appFont(AppTextRole.headline)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(state.neighbors, id: \.communityId) { neighbor in
            CatbirdChip(
              title: Text(verbatim: neighbor.title), systemImage: neighbor.symbolName, size: .sm,
              action: { onOpenNeighbor(neighbor) })
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

/// Thin wrapper over the canonical avatar (`AsyncProfileImage`). Kept as its own type because
/// `CommunityCardTileView` and the lineup rows call it. Pass an `AvatarSize` token for `size`.
/// With no URL it keeps the initial-letter placeholder the onboarding rows rely on.
struct AvatarThumbView: View {
  let url: URL?
  let fallbackText: String
  let size: CGFloat
  /// Unused: `AsyncProfileImage` reads the display scale from the environment. Kept so call sites compile.
  let scale: CGFloat

  var body: some View {
    if url != nil {
      AsyncProfileImage(url: url, size: size)
    } else {
      placeholderCircle
    }
  }

  private var placeholderCircle: some View {
    Circle()
      .fill(Color.accentColor.opacity(0.18))
      .frame(width: size, height: size)
      .overlay(
        Text(verbatim: String(fallbackText.prefix(1)).uppercased())
          .appFont(AppTextRole.subheadline)
          .fontWeight(.bold)
          .foregroundStyle(Color.accentColor)
      )
  }
}

struct HydratedPostCardView: View {
  let post: HydratedSamplePost
  let isPinned: Bool
  let onTogglePin: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      if let commTitle = post.communityTitle {
        HStack(spacing: Space.sm) {
          Image(systemName: "sparkles")
            .appFont(AppTextRole.caption2)
            .foregroundStyle(Color.accentColor)
          Text(commTitle)
            .appFont(AppTextRole.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
          if let role = post.authorRole {
            Text(verbatim: "· \(role.badgeTitle)")
              .appFont(AppTextRole.caption2)
              .foregroundStyle(.secondary)
          }
          Spacer()
          if isPinned {
            CatbirdChip(
              title: Text("Pinned", comment: "Button state showing post author is pinned into starting lineup."),
              systemImage: "pin.fill", isSelected: true, size: .sm, action: onTogglePin)
          } else {
            CatbirdChip(
              title: Text("Pin Voice", comment: "Button action to pin post author into starting lineup."),
              systemImage: "pin", size: .sm, action: onTogglePin)
          }
        }.padding(.horizontal, Space.md)
      }

      CompactPostCard(
        avatarURL: post.authorAvatarURL, displayName: post.authorDisplayName,
        handle: post.authorHandle, text: post.text, imageURL: post.imageThumbURLs.first,
        did: post.authorDID, lineLimit: 6, showsChrome: false,
        footer: {
          HStack(spacing: Space.lg) {
            Label {
              Text(post.replyCount, format: .number)
            } icon: {
              Image(systemName: "bubble.left")
            }
            Label {
              Text(post.repostCount, format: .number)
            } icon: {
              Image(systemName: "arrow.2.squarepath")
            }
            Label {
              Text(post.likeCount, format: .number)
            } icon: {
              Image(systemName: "heart")
            }
          }
          .appFont(AppTextRole.caption2)
          .monospacedDigit()
          .foregroundStyle(.secondary)
        }
      )
      .overlay(alignment: .topTrailing) {
        if post.communityTitle == nil {
          CatbirdIconButton(
            systemImage: isPinned ? "pin.fill" : "pin",
            label: isPinned
              ? Text("Unpin \(post.authorDisplayName)", comment: "Accessibility action to unpin post author.")
              : Text("Pin \(post.authorDisplayName)", comment: "Accessibility action to pin post author."),
            size: .sm, style: isPinned ? .tonal : .quiet, action: onTogglePin)
        }
      }
    }
    .padding(.top, Space.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .catbirdCard(.embed, radius: .lg)
  }
}
