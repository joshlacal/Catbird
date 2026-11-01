import NukeUI
import Petrel
import PetrelCatbird
import SwiftUI

struct StartingLineupBeatView: View {
  @Bindable var viewModel: SceneOnboardingViewModel
  let onSkipAll: (() -> Void)?

  @Environment(\.displayScale) private var displayScale
  @State private var inspectedStarterPack: InspectedStarterPackItem?
  @State private var starterPackNavigationPath = NavigationPath()

  private struct InspectedStarterPackItem: Identifiable {
    let id: String
    let uri: ATProtocolURI
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          summaryHeroCard

          if let errorMsg = viewModel.errorBannerMessage {
            HStack(spacing: 8) {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
              Text(errorMsg)
                .font(.caption)
                .foregroundStyle(.primary)
              Spacer()
              Button("Retry") {
                Task { await viewModel.solveStartingLineup() }
              }
              .font(.caption.weight(.bold))
            }
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
          }

          if viewModel.isSolvingBundle {
            VStack(spacing: 12) {
              ProgressView()
              Text("Solving role-balanced lineup across your scenes…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
          } else {
            roleSectionsList
            harmoniousNeighborsSection
            pinnableFeedsSection
            starterPacksReferenceSection
          }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 130)
      }

      commitBottomDock
    }
    .accessibilityIdentifier("intel.beat.lineup")
    .sheet(item: $inspectedStarterPack) { item in
      NavigationStack(path: $starterPackNavigationPath) {
        StarterPackView(uri: item.uri, path: $starterPackNavigationPath)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Done") {
                inspectedStarterPack = nil
              }
            }
          }
      }
      .presentationDragIndicator(.visible)
    }
  }

  private var summaryHeroCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Label("Your Starting Lineup", systemImage: "person.3.sequence.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
          Text("\(viewModel.activeFollowCount) Vetted Voices")
            .font(.title2.weight(.bold))
        }

        Spacer()

        VStack(alignment: .trailing, spacing: 4) {
          Label("~\(viewModel.activeEstimatedDailyPosts) posts/day", systemImage: "metronome.fill")
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.12), in: Capsule())

          if viewModel.activeOriginalsOnlyCount > 0 {
            Text("\(viewModel.activeOriginalsOnlyCount) in Originals Only")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
          }
        }
      }

      Text("Balanced across anchors, original makers, warm conversationalists, and curators — with zero hostile cluster collisions and repost floods automatically tamed.")
        .font(.caption)
        .foregroundStyle(.secondary)

      if let summary = viewModel.solvedBundle?.summary {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            SummaryMetricPill(
              label: "\(summary.coveredCommunities) scenes",
              symbol: "globe.desk"
            )
            if summary.anchorCount > 0 {
              SummaryMetricPill(label: "\(summary.anchorCount) anchors", symbol: "shield.checkered")
            }
            if summary.makerCount > 0 {
              SummaryMetricPill(label: "\(summary.makerCount) makers", symbol: "hammer.fill")
            }
            if summary.conversationalCount > 0 {
              SummaryMetricPill(
                label: "\(summary.conversationalCount) conversational",
                symbol: "bubble.left.and.bubble.right.fill"
              )
            }
            if summary.curatorCount > 0 {
              SummaryMetricPill(label: "\(summary.curatorCount) curators", symbol: "safari.fill")
            }
          }
        }
      }
    }
    .padding(16)
    .adaptiveGlassEffect(
      style: .regular,
      in: RoundedRectangle(cornerRadius: 20, style: .continuous)
    )
  }

  private var roleSectionsList: some View {
    VStack(alignment: .leading, spacing: 22) {
      ForEach(viewModel.lineupRoleSections) { section in
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 8) {
            Image(systemName: section.role.symbolName)
              .font(.subheadline.weight(.bold))
              .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
              Text(section.role.displayTitle)
                .font(.headline)
              Text(section.role.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(section.items.count)")
              .font(.caption.weight(.bold).monospacedDigit())
              .foregroundStyle(.secondary)
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(Color.secondary.opacity(0.12), in: Capsule())
          }

          VStack(spacing: 10) {
            ForEach(section.items, id: \.did) { rec in
              let didStr = rec.did.didString()
              LineupAccountRowView(
                recommendation: rec,
                profile: viewModel.lineupProfilesByDID[didStr],
                isEnabled: viewModel.enabledFollowDIDs.contains(didStr),
                isOriginalsOnly: viewModel.originalsOnlyDIDs.contains(didStr),
                displayScale: displayScale,
                onToggleFollow: { viewModel.toggleFollowAccount(didStr) },
                onToggleOriginalsOnly: { viewModel.toggleOriginalsOnly(for: didStr) },
                onSwap: { Task { await viewModel.excludeAndSwapAccount(didStr) } }
              )
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private var harmoniousNeighborsSection: some View {
    if let neighbors = viewModel.solvedBundle?.harmoniousNeighbors, !neighbors.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Label("Harmonious Adjacent Scenes", systemImage: "point.3.connected.trianglepath.dotted")
          .font(.headline)
        Text("Low-friction neighboring communities that pair naturally with your picks.")
          .font(.caption)
          .foregroundStyle(.secondary)

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 10) {
            ForEach(neighbors, id: \.communityId) { neighbor in
              Button {
                Task { await viewModel.addHarmoniousNeighborAndResolve(neighbor) }
              } label: {
                HStack(spacing: 6) {
                  Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Color.accentColor)
                  Text(neighbor.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                  Capsule()
                    .fill(Color.secondary.opacity(0.1))
                )
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private var pinnableFeedsSection: some View {
    if !viewModel.hydratedFeeds.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Label("Pin Community Feeds", systemImage: "pin.circle.fill")
          .font(.headline)
        Text("Save dedicated topic feeds right onto your home feed bar.")
          .font(.caption)
          .foregroundStyle(.secondary)

        ForEach(viewModel.hydratedFeeds) { feed in
          let isSelected = viewModel.selectedFeedURIs.contains(feed.uri)
          Button {
            viewModel.togglePinnedFeed(feed.uri)
          } label: {
            HStack(spacing: 12) {
              AvatarThumbView(
                url: feed.avatarURL,
                fallbackText: feed.displayName,
                size: 38,
                scale: displayScale
              )

              VStack(alignment: .leading, spacing: 2) {
                Text(feed.displayName)
                  .font(.subheadline.weight(.semibold))
                  .foregroundStyle(.primary)
                Text("by @\(feed.creatorHandle) · \(feed.communityTitle)")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                if !feed.description.isEmpty {
                  Text(feed.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
              }

              Spacer()

              Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .padding(12)
            .background(
              RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.secondary.opacity(0.07))
            )
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  @ViewBuilder
  private var starterPacksReferenceSection: some View {
    if !viewModel.hydratedStarterPacks.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Label("Inspectable Starter Packs", systemImage: "shippingbox.fill")
          .font(.subheadline.weight(.semibold))
        Text("Tap to inspect members — never bulk-followed automatically, so your feed stays crisp.")
          .font(.caption2)
          .foregroundStyle(.secondary)

        ForEach(viewModel.hydratedStarterPacks) { pack in
          Button {
            guard let parsedURI = try? ATProtocolURI(uriString: pack.uri) else { return }
            starterPackNavigationPath = NavigationPath()
            inspectedStarterPack = InspectedStarterPackItem(id: pack.id, uri: parsedURI)
          } label: {
            HStack(spacing: 10) {
              Image(systemName: "sparkles.rectangle.stack")
                .foregroundStyle(Color.accentColor)
              VStack(alignment: .leading, spacing: 2) {
                Text(pack.name)
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.primary)
                Text("Curated by @\(pack.creatorHandle) · \(pack.joinedAllTimeCount) joined")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              HStack(spacing: 4) {
                Text("Inspect")
                  .font(.caption2.weight(.semibold))
                Image(systemName: "chevron.right")
                  .font(.caption2.weight(.bold))
              }
              .foregroundStyle(Color.accentColor)
            }
            .padding(10)
            .background(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
            )
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("intel.lineup.starterPack.\(pack.id)")
        }
      }
    }
  }

  private var commitBottomDock: some View {
    let canCommit = !viewModel.isCommitting
      && (viewModel.activeFollowCount > 0 || !viewModel.selectedFeedURIs.isEmpty)

    return VStack(spacing: 8) {
      Button {
        Task { await viewModel.commitStartingLineup() }
      } label: {
        HStack(spacing: 10) {
          if viewModel.isCommitting {
            ProgressView()
              .tint(.white)
          } else {
            Image(systemName: "paperplane.fill")
              .font(.subheadline.weight(.bold))
          }
          Text(commitButtonTitle)
            .font(.headline)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(
          Capsule()
            .fill(canCommit ? Color.accentColor : Color.secondary.opacity(0.35))
        )
      }
      .buttonStyle(.plain)
      .disabled(!canCommit)
      .accessibilityIdentifier("intel.lineup.commitButton")

      if let onSkipAll, viewModel.mode == .newAccountOnboarding {
        Button("Skip for Now", action: onSkipAll)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .disabled(viewModel.isCommitting)
          .accessibilityIdentifier("intel.lineup.skipAll")
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .adaptiveGlassEffect(
      style: .regular,
      in: RoundedRectangle(cornerRadius: 26, style: .continuous)
    )
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
  }

  private var commitButtonTitle: String {
    if viewModel.isCommitting {
      return "Setting Up Your Feed…"
    }
    if viewModel.mode == .tuneExistingFeed {
      return "Add \(viewModel.activeFollowCount) Voices to My Feed"
    }
    return "Follow \(viewModel.activeFollowCount) Voices & Launch"
  }
}

private struct SummaryMetricPill: View {
  let label: String
  let symbol: String

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: symbol)
        .font(.caption2)
      Text(label)
        .font(.caption2.weight(.semibold))
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(Color.secondary.opacity(0.1), in: Capsule())
  }
}

private struct LineupAccountRowView: View {
  let recommendation: BlueCatbirdOnboardingDefs.RecommendedFollow
  let profile: HydratedRecommendedProfile?
  let isEnabled: Bool
  let isOriginalsOnly: Bool
  let displayScale: CGFloat
  let onToggleFollow: () -> Void
  let onToggleOriginalsOnly: () -> Void
  let onSwap: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 12) {
        AvatarThumbView(
          url: profile?.avatarURL,
          fallbackText: profile?.displayName ?? recommendation.did.didString(),
          size: 44,
          scale: displayScale
        )

        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(profile?.displayName ?? "Community Voice")
              .font(.subheadline.weight(.bold))
              .lineLimit(1)

            if profile?.alreadyFollowing == true {
              Text("Following")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.12), in: Capsule())
            }
          }

          if let handle = profile?.handle {
            Text("@\(handle)")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }

          Text(recommendation.whyPicked)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)

          if let bio = profile?.bio, !bio.isEmpty {
            Text(bio)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }

        Spacer(minLength: 4)

        Button(action: onToggleFollow) {
          Image(systemName: isEnabled ? "checkmark.circle.fill" : "plus.circle")
            .font(.title2)
            .foregroundStyle(isEnabled ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isEnabled ? "Included in lineup" : "Excluded from lineup")
      }

      HStack(spacing: 8) {
        Text(recommendation.communityTitle)
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.secondary.opacity(0.1), in: Capsule())

        Spacer()

        if isEnabled {
          Button(action: onToggleOriginalsOnly) {
            HStack(spacing: 4) {
              Image(systemName: isOriginalsOnly ? "sparkles" : "arrow.2.squarepath")
                .font(.caption2)
              Text(isOriginalsOnly ? "Originals Only" : "All Posts")
                .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(isOriginalsOnly ? Color.accentColor : .secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
              Capsule()
                .fill(isOriginalsOnly ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.1))
            )
          }
          .buttonStyle(.plain)
          .accessibilityLabel(isOriginalsOnly ? "Originals Only enabled" : "All Posts including reposts")
        }

        Button(action: onSwap) {
          HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.2.circlepath")
              .font(.caption2)
            Text("Swap")
              .font(.caption2.weight(.semibold))
          }
          .foregroundStyle(.secondary)
          .padding(.horizontal, 9)
          .padding(.vertical, 5)
          .background(Color.secondary.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Swap for another voice")
      }
    }
    .padding(13)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color.secondary.opacity(isEnabled ? 0.08 : 0.03))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(
          isEnabled ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06),
          lineWidth: 1
        )
    )
  }
}
