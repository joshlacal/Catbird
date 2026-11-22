import Petrel
import PetrelCatbird
import SwiftUI

// MARK: - Community Card Tile

/// One scene in the explorer: what it is, who picking it follows, and controls to pick, boost and
/// peek into it. Takes plain values so a grid of cards redraws only the cards whose values change.
struct CommunityCardTileView: View {
  let community: BlueCatbirdIntelDefs.CommunitySummary
  let selectionWeight: Int
  /// The first accounts picking this scene follows; empty for a server that does not order a
  /// scene's accounts that way.
  let faces: SceneOnboardingViewModel.SceneCardFaces
  /// "You already follow N here", or nil when there are none to report.
  let alreadyFollowingLine: String?
  let onTogglePick: () -> Void
  let onToggleBoost: () -> Void
  let onPeek: () -> Void
  /// Called when the card comes on screen, to start loading its faces.
  let onAppear: () -> Void

  private var isPicked: Bool { selectionWeight >= 1 }
  private var isBoosted: Bool { selectionWeight >= 2 }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      topBar
      pickBody
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(
          isBoosted
            ? Color.pink.opacity(0.08)
            : (isPicked ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06))
        )
    )
    .overlay(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .strokeBorder(
          isBoosted
            ? Color.pink.opacity(0.75)
            : (isPicked ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.08)),
          lineWidth: isPicked ? 2 : 1
        )
    )
    .animation(.spring(duration: 0.25), value: selectionWeight)
    .onAppear(perform: onAppear)
  }

  // MARK: - Top Bar

  private var topBar: some View {
    HStack(spacing: 6) {
      HStack(spacing: 4) {
        Image(systemName: community.symbolName)
          .font(.caption2.weight(.semibold))
        Text(community.sceneTitle)
          .font(.caption2.weight(.semibold))
          .lineLimit(1)
      }
      .foregroundStyle(isBoosted ? .pink : Color.accentColor)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        (isBoosted ? Color.pink : Color.accentColor).opacity(0.12),
        in: Capsule()
      )

      Spacer(minLength: 4)

      Button(action: onPeek) {
        HStack(spacing: 4) {
          Image(systemName: "eye")
            .font(.caption2.weight(.semibold))
          Text("Peek")
            .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12), in: Capsule())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("intel.card.peek.\(community.communityId)")
      .accessibilityLabel("Peek sample posts for \(community.title)")

      Button(action: onToggleBoost) {
        HStack(spacing: 3) {
          Image(systemName: isBoosted ? "heart.fill" : "heart")
            .font(.caption.weight(.semibold))
          if isBoosted {
            Text("2×")
              .font(.caption2.weight(.bold))
          }
        }
        .foregroundStyle(isBoosted ? .white : .pink)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
          isBoosted ? Color.pink : Color.pink.opacity(0.12),
          in: Capsule()
        )
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("intel.card.boost.\(community.communityId)")
      .accessibilityLabel(isBoosted ? "Remove 2x boost for \(community.title)" : "Boost \(community.title) 2x")
    }
  }

  // MARK: - Pick Body

  private var pickBody: some View {
    Button(action: onTogglePick) {
      VStack(alignment: .leading, spacing: 8) {
        Text(community.title)
          .font(.headline)
          .foregroundStyle(.primary)
          .multilineTextAlignment(.leading)
          .lineLimit(2)

        Text(community.description)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.leading)
          .lineLimit(3)

        if !community.curatedListTags.isEmpty {
          HStack(spacing: 6) {
            ForEach(Array(community.curatedListTags.prefix(3)), id: \.self) { tag in
              Text("#\(tag.replacingOccurrences(of: "\\'", with: "'"))")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.09), in: Capsule())
                .lineLimit(1)
            }
          }
        }

        if !faces.isEmpty {
          SceneCardFacesRow(faces: faces)
        }

        if let alreadyFollowingLine {
          Label(alreadyFollowingLine, systemImage: "person.crop.circle.badge.checkmark")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
        }

        footer
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(pickAccessibilityLabel)
    .accessibilityValue(isBoosted ? "Boosted 2×" : (isPicked ? "Picked" : "Not picked"))
    .accessibilityIdentifier("intel.card.\(community.communityId)")
  }

  private var footer: some View {
    HStack {
      Label("\(community.eligibleCount) voices", systemImage: "person.2.fill")
        .font(.caption2)
        .foregroundStyle(.secondary)

      Spacer()

      HStack(spacing: 4) {
        Image(systemName: isPicked ? "checkmark.circle.fill" : "plus.circle")
          .font(.caption.weight(.semibold))
        Text(isBoosted ? "Boosted 2×" : (isPicked ? "Picked" : "Pick"))
          .font(.caption.weight(.semibold))
      }
      .foregroundStyle(isBoosted ? .pink : (isPicked ? Color.accentColor : .secondary))
    }
    .padding(.top, 2)
  }

  /// What VoiceOver reads for the card: the scene, the accounts a pick follows by name, and how
  /// many of its accounts the viewer already follows.
  private var pickAccessibilityLabel: String {
    var parts = [community.title, community.description]
    if let followLine = SceneCardFacesRow.accessibilitySummary(for: faces) {
      parts.append(followLine)
    }
    if let alreadyFollowingLine {
      parts.append(alreadyFollowingLine)
    }
    parts.append("\(community.eligibleCount) voices")
    return parts.joined(separator: ". ")
  }
}

// MARK: - Faces Row

/// The first accounts picking a scene follows, as a row of overlapping avatars under the caption
/// "You'll follow". Accounts still loading hold their place as plain circles.
struct SceneCardFacesRow: View {
  let faces: SceneOnboardingViewModel.SceneCardFaces

  private static let faceSize: CGFloat = 26
  private static let overlap: CGFloat = 8

  @Environment(\.displayScale) private var displayScale

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("You'll follow")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        HStack(spacing: -Self.overlap) {
          ForEach(faces.profiles) { profile in
            AvatarThumbView(
              url: profile.avatarURL,
              fallbackText: profile.displayName,
              size: Self.faceSize,
              scale: displayScale
            )
            .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5))
          }
          ForEach(0..<faces.loadingCount, id: \.self) { _ in
            Circle()
              .fill(Color.secondary.opacity(0.16))
              .frame(width: Self.faceSize, height: Self.faceSize)
              .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5))
          }
        }

        if let lead = faces.profiles.first {
          Text(leadNames(startingWith: lead))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
  }

  private func leadNames(startingWith lead: HydratedRecommendedProfile) -> String {
    let others = faces.profiles.count - 1
    return others > 0 ? "\(lead.displayName) and \(others) more" : lead.displayName
  }

  /// "You'll follow A, B and C" for VoiceOver, naming every face that has loaded; nil when none
  /// has.
  nonisolated static func accessibilitySummary(for faces: SceneOnboardingViewModel.SceneCardFaces) -> String? {
    let names = faces.profiles.map(\.displayName)
    guard let last = names.last else { return nil }
    guard names.count > 1 else { return "You'll follow \(last)" }
    return "You'll follow \(names.dropLast().joined(separator: ", ")) and \(last)"
  }
}
