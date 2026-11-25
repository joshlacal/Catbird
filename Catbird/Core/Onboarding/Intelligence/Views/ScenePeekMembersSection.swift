import Petrel
import PetrelCatbird
import SwiftUI

/// The scene sheet's member list. With a server that sizes lineups per scene it reads as two
/// groups: the accounts picking the scene follows, then the rest of the scene. Otherwise it is one
/// list of the scene's members.
struct ScenePeekMembersSection: View {
  let sections: SceneOnboardingViewModel.PeekMemberSections
  /// Whether the viewer has picked this scene. Until they have, its lineup is only what picking
  /// would follow, so those accounts keep their pin control.
  let isScenePicked: Bool
  let lineupHeading: String
  let profilesByDID: [String: HydratedRecommendedProfile]
  let isAuthorPinned: (String) -> Bool
  let onTogglePinAuthor: (String) -> Void
  let onMemberAppear: (String) -> Void

  var body: some View {
    if sections.lineupCount != nil {
      if !sections.lineup.isEmpty {
        memberGroup(
          title: lineupHeading,
          systemImage: "person.crop.circle.badge.checkmark",
          caption: String(
            localized: "Picking this scene follows these accounts, in this order.",
            comment: "Caption under the lineup accounts section inside the scene peek sheet."
          ),
          members: sections.lineup,
          inLineup: isScenePicked,
          identifier: "intel.peek.lineupMembers"
        )
      }
      if !sections.more.isEmpty {
        memberGroup(
          title: String(
            localized: "More from this scene",
            comment: "Section heading for additional community members beyond the default lineup."
          ),
          systemImage: "person.3.sequence.fill",
          caption: String(
            localized: "Pin anyone here to add them too.",
            comment: "Caption explaining how to pin additional scene members."
          ),
          members: sections.more,
          inLineup: false,
          identifier: "intel.peek.moreMembers"
        )
      }
    } else if !sections.more.isEmpty {
      memberGroup(
        title: String(
          localized: "Representative Voices by Role",
          comment: "Section heading for scene members when no fixed lineup count is reported."
        ),
        systemImage: "person.3.sequence.fill",
        caption: nil,
        members: sections.more,
        inLineup: false,
        identifier: "intel.peek.members"
      )
    }
  }

  private func memberGroup(
    title: String,
    systemImage: String,
    caption: String?,
    members: [BlueCatbirdIntelDefs.CommunityMemberRef],
    inLineup: Bool,
    identifier: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Label(title, systemImage: systemImage)
          .appFont(AppTextRole.headline)
          .accessibilityAddTraits(.isHeader)
        if let caption {
          Text(caption)
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
        }
      }

      ForEach(members, id: \.did) { member in
        let didString = member.did.didString()
        ScenePeekMemberRow(
          member: member,
          profile: profilesByDID[didString],
          inLineup: inLineup,
          isPinned: isAuthorPinned(didString),
          onTogglePin: { onTogglePinAuthor(didString) }
        )
        .onAppear { onMemberAppear(didString) }
      }
    }
    .accessibilityIdentifier(identifier)
  }
}

/// One member of a scene: who they are, their role and size in the scene, and either a mark that
/// they are in the lineup or a control to pin them.
struct ScenePeekMemberRow: View {
  let member: BlueCatbirdIntelDefs.CommunityMemberRef
  let profile: HydratedRecommendedProfile?
  let inLineup: Bool
  let isPinned: Bool
  let onTogglePin: () -> Void

  @Environment(\.displayScale) private var displayScale

  private var role: CommunityRole { CommunityRole(rawRole: member.role) }
  private var tierLabel: String? { SceneOnboardingViewModel.tierLabel(member.tier) }
  private var displayName: String {
    profile?.displayName ?? String(localized: "Community Creator", comment: "Fallback display name for a community member whose profile is loading.")
  }

  var body: some View {
    HStack(spacing: 12) {
      AvatarThumbView(
        url: profile?.avatarURL,
        fallbackText: profile?.displayName ?? member.did.didString(),
        size: AvatarSize.md,
        scale: displayScale
      )

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(displayName)
            .appFont(AppTextRole.subheadline)
            .fontWeight(.semibold)
            .lineLimit(1)
          CatbirdBadge(Text(role.badgeTitle), tone: .accent)
            .fixedSize()
          if let tierLabel {
            CatbirdBadge(Text(tierLabel), tone: .neutral)
              .fixedSize()
          }
        }
        if let handle = profile?.handle {
          Text(verbatim: "@\(handle)")
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Text(member.whyPicked)
          .appFont(AppTextRole.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .accessibilityElement(children: .combine)

      Spacer()

      trailingAccessory
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color.secondary.opacity(0.06))
    )
  }

  @ViewBuilder
  private var trailingAccessory: some View {
    if inLineup {
      Image(systemName: "checkmark.circle.fill")
        .appFont(AppTextRole.title3)
        .foregroundStyle(Color.accentColor)
        .accessibilityLabel(Text("In your lineup", comment: "Accessibility label indicating member is already included in the starting lineup."))
    } else {
      CatbirdChip(
        title: isPinned
          ? Text("Pinned", comment: "Button state showing creator is pinned into the starting lineup.")
          : Text("Pin", comment: "Button action to pin a creator into the starting lineup."),
        systemImage: isPinned ? "pin.fill" : "pin",
        isSelected: isPinned,
        size: .sm,
        action: onTogglePin
      )
      .accessibilityLabel(
        isPinned
          ? Text("Unpin \(displayName)", comment: "Accessibility action to unpin a creator — variable is display name.")
          : Text("Pin \(displayName)", comment: "Accessibility action to pin a creator — variable is display name.")
      )
    }
  }
}
