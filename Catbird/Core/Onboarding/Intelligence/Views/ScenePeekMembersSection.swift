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
          .font(.headline)
          .accessibilityAddTraits(.isHeader)
        if let caption {
          Text(caption)
            .font(.caption)
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
        size: 40,
        scale: displayScale
      )

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(displayName)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
          Text(role.badgeTitle)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
          if let tierLabel {
            Text(tierLabel)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .fixedSize()
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.secondary.opacity(0.12), in: Capsule())
          }
        }
        if let handle = profile?.handle {
          Text(verbatim: "@\(handle)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Text(member.whyPicked)
          .font(.caption2)
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
        .font(.title3)
        .foregroundStyle(Color.accentColor)
        .accessibilityLabel(Text("In your lineup", comment: "Accessibility label indicating member is already included in the starting lineup."))
    } else {
      Button(action: onTogglePin) {
        Group {
          if isPinned {
            Label {
              Text("Pinned", comment: "Button state showing creator is pinned into the starting lineup.")
            } icon: {
              Image(systemName: "pin.fill")
            }
          } else {
            Label {
              Text("Pin", comment: "Button action to pin a creator into the starting lineup.")
            } icon: {
              Image(systemName: "pin")
            }
          }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(isPinned ? .white : Color.accentColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
          isPinned ? Color.accentColor : Color.accentColor.opacity(0.12),
          in: Capsule()
        )
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        isPinned
          ? Text("Unpin \(displayName)", comment: "Accessibility action to unpin a creator — variable is display name.")
          : Text("Pin \(displayName)", comment: "Accessibility action to pin a creator — variable is display name.")
      )
    }
  }
}
