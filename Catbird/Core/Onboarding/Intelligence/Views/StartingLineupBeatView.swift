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
                .appFont(AppTextRole.caption)
                .foregroundStyle(.primary)
              Spacer()
              Button("Retry") {
                Task { await viewModel.solveStartingLineup() }
              }
              .appFont(AppTextRole.caption)
              .fontWeight(.bold)
            }
            .padding(12)
            .catbirdCard(.notice(.warning))
          }

          if viewModel.isSolvingBundle {
            VStack(spacing: 12) {
              ProgressView()
              Text("Picking voices from each of your scenes…")
                .appFont(AppTextRole.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
          } else {
            sceneSectionsList
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
            .appFont(AppTextRole.caption)
            .fontWeight(.semibold)
            .foregroundStyle(Color.accentColor)
          Text(viewModel.lineupHeadline)
            .appFont(AppTextRole.title2)
            .fontWeight(.bold)
        }

        Spacer()

        VStack(alignment: .trailing, spacing: 4) {
          CatbirdBadge(
            Text("~\(viewModel.activeEstimatedDailyPosts) posts/day", comment: "Estimated daily post volume badge."),
            systemImage: "metronome.fill",
            tone: .accent
          )
          .monospacedDigit()

          if viewModel.activeOriginalsOnlyCount > 0 {
            Text("\(viewModel.activeOriginalsOnlyCount) in Originals Only", comment: "Count of lineup accounts set to Originals Only mode.")
              .appFont(AppTextRole.caption2)
              .fontWeight(.semibold)
              .foregroundStyle(.secondary)
          }
        }
      }

      Text(viewModel.lineupSummaryLine)
        .appFont(AppTextRole.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("intel.lineup.summaryLine")

      let tally = viewModel.activeLineupTally
      if tally.sceneCount > 0 {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            SummaryMetricPill(
              label: String(localized: "\(tally.sceneCount) scenes", comment: "Count of chosen scenes represented in starting lineup."),
              symbol: "globe.desk"
            )
            ForEach(CommunityRole.allCases) { role in
              let count = tally.count(for: role)
              if count > 0 {
                SummaryMetricPill(label: rolePillLabel(role, count: count), symbol: role.symbolName)
              }
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

  private var sceneSectionsList: some View {
    VStack(alignment: .leading, spacing: 22) {
      ForEach(viewModel.lineupSceneSections) { section in
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 8) {
            Image(systemName: "person.3.fill")
              .appFont(AppTextRole.subheadline)
              .fontWeight(.bold)
              .foregroundStyle(Color.accentColor)
            Text(section.title)
              .appFont(AppTextRole.headline)
              .lineLimit(2)
            Spacer()
            CatbirdBadge(Text(section.items.count, format: .number), tone: .neutral)
              .monospacedDigit()
          }
          .accessibilityElement(children: .combine)

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
          .appFont(AppTextRole.headline)
        Text("Low-friction neighboring communities that pair naturally with your picks.")
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 10) {
            ForEach(neighbors, id: \.communityId) { neighbor in
              CatbirdChip(
                title: Text(verbatim: neighbor.title),
                systemImage: "plus.circle.fill",
                size: .md,
                action: { Task { await viewModel.addHarmoniousNeighborAndResolve(neighbor) } }
              )
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
          .appFont(AppTextRole.headline)
        Text("Save dedicated topic feeds right onto your home feed bar.")
          .appFont(AppTextRole.caption)
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
                size: AvatarSize.md,
                scale: displayScale
              )

              VStack(alignment: .leading, spacing: 2) {
                Text(feed.displayName)
                  .appFont(AppTextRole.subheadline)
                  .fontWeight(.semibold)
                  .foregroundStyle(.primary)
                Text("by @\(feed.creatorHandle) · \(feed.communityTitle)", comment: "Feed attribution line — %1$@ is creator handle, %2$@ is community title.")
                  .appFont(AppTextRole.caption2)
                  .foregroundStyle(.secondary)
                if !feed.description.isEmpty {
                  Text(feed.description)
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
              }

              Spacer()

              Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .appFont(AppTextRole.title3)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .padding(12)
            .background(
              Radius.lg.shape
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
          .appFont(AppTextRole.subheadline)
          .fontWeight(.semibold)
        Text("Tap to inspect members — never bulk-followed automatically, so your feed stays crisp.")
          .appFont(AppTextRole.caption2)
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
                  .appFont(AppTextRole.caption)
                  .fontWeight(.semibold)
                  .foregroundStyle(.primary)
                Text(
                  "Curated by @\(pack.creatorHandle) · \(pack.joinedAllTimeCount) joined",
                  comment: "Starter pack attribution and join count — %1$@ is creator handle, %2$lld is number of users who joined."
                )
                .appFont(AppTextRole.caption2)
                .foregroundStyle(.secondary)
              }
              Spacer()
              HStack(spacing: 4) {
                Text("Inspect", comment: "Button label to inspect starter pack members.")
                  .appFont(AppTextRole.caption2)
                  .fontWeight(.semibold)
                Image(systemName: "chevron.forward")
                  .appFont(AppTextRole.caption2)
                  .fontWeight(.bold)
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
          }
          Text(commitButtonTitle)
        }
      }
      .buttonStyle(.catbird(.primary, size: .lg, fullWidth: true))
      .disabled(!canCommit)
      .accessibilityIdentifier("intel.lineup.commitButton")

      if let onSkipAll, viewModel.mode == .newAccountOnboarding {
        Button("Skip for Now", action: onSkipAll)
          .appFont(AppTextRole.caption)
          .fontWeight(.semibold)
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
      return String(localized: "Setting Up Your Feed…", comment: "Progress button title while committing onboarding starting lineup.")
    }
    let count = viewModel.activeFollowCount
    if count == 0 {
      return viewModel.mode == .tuneExistingFeed
        ? String(localized: "Add Feeds to My Feed", comment: "Commit button title when adding feeds without new follows in tuning mode.")
        : String(localized: "Launch with These Feeds", comment: "Commit button title when launching onboarding with feeds only.")
    }
    if viewModel.mode == .tuneExistingFeed {
      return String(
        localized: "Add \(count) Voices to My Feed",
        comment: "Commit button title to follow selected voices in tuning mode — variable is account count."
      )
    }
    return String(
      localized: "Follow \(count) Voices & Launch",
      comment: "Commit button title to follow selected voices and launch onboarding — variable is account count."
    )
  }

  private func rolePillLabel(_ role: CommunityRole, count: Int) -> String {
    switch role {
    case .anchorCreator:
      String(localized: "\(count) anchors", comment: "Count pill of community anchors in starting lineup.")
    case .visualMaker:
      String(localized: "\(count) makers", comment: "Count pill of original makers in starting lineup.")
    case .conversationalist:
      String(localized: "\(count) conversational", comment: "Count pill of conversationalists in starting lineup.")
    case .sceneCurator:
      String(localized: "\(count) curators", comment: "Count pill of curators in starting lineup.")
    case .projectOrStudio:
      String(localized: "\(count) projects", comment: "Count pill of projects or studios in starting lineup.")
    }
  }
}

private struct SummaryMetricPill: View {
  let label: String
  let symbol: String

  var body: some View {
    CatbirdBadge(Text(verbatim: label), systemImage: symbol, tone: .neutral)
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

  private var role: CommunityRole {
    CommunityRole(rawRole: recommendation.role)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 12) {
        AvatarThumbView(
          url: profile?.avatarURL,
          fallbackText: profile?.displayName ?? recommendation.did.didString(),
          size: AvatarSize.lg,
          scale: displayScale
        )

        VStack(alignment: .leading, spacing: 3) {
          Text(profile?.displayName ?? String(localized: "Community Voice", comment: "Fallback display name for a lineup creator whose profile is loading."))
            .appFont(AppTextRole.subheadline)
            .fontWeight(.bold)
            .lineLimit(1)

          if let handle = profile?.handle {
            Text(verbatim: "@\(handle)")
              .appFont(AppTextRole.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }

          Text(recommendation.whyPicked)
            .appFont(AppTextRole.caption2)
            .fontWeight(.medium)
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)

          if let bio = profile?.bio, !bio.isEmpty {
            Text(bio)
              .appFont(AppTextRole.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }

        Spacer(minLength: 4)

        CatbirdIconButton(
          systemImage: isEnabled ? "checkmark.circle.fill" : "plus.circle",
          label: isEnabled
            ? Text("Included in lineup", comment: "Accessibility label when account is switched on in starting lineup.")
            : Text("Excluded from lineup", comment: "Accessibility label when account is switched off in starting lineup."),
          style: .quiet,
          action: onToggleFollow
        )
      }

      HStack(spacing: 8) {
        CatbirdBadge(Text(role.badgeTitle), systemImage: role.symbolName, tone: .neutral)
          .accessibilityElement(children: .combine)

        Spacer()

        if isEnabled {
          CatbirdChip(
            title: isOriginalsOnly
              ? Text("Originals Only", comment: "Delivery mode chip hiding reposts from this creator.")
              : Text("All Posts", comment: "Delivery mode chip showing both posts and reposts from this creator."),
            systemImage: isOriginalsOnly ? "sparkles" : "arrow.2.squarepath",
            isSelected: isOriginalsOnly,
            size: .sm,
            action: onToggleOriginalsOnly
          )
          .accessibilityLabel(
            isOriginalsOnly
              ? Text("Originals Only enabled", comment: "Accessibility label when reposts are hidden for this creator.")
              : Text("All Posts including reposts", comment: "Accessibility label when reposts are shown for this creator.")
          )
        }

        CatbirdChip(
          title: Text("Swap"),
          systemImage: "arrow.triangle.2.circlepath",
          size: .sm,
          action: onSwap
        )
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
