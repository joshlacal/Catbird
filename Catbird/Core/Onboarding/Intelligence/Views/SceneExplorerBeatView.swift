import Petrel
import PetrelCatbird
import SwiftUI

struct SceneExplorerBeatView: View {
  @Bindable var viewModel: SceneOnboardingViewModel

  private static let quickSearchSuggestions = [
    "swiftui",
    "indie games",
    "urbanism",
    "film photography",
    "sci-fi books",
    "astronomy",
  ]

  private let gridColumns = [
    GridItem(.adaptive(minimum: 290, maximum: 440), spacing: 14, alignment: .top)
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        heroHeader
        if let errorMsg = viewModel.errorBannerMessage {
          HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
            Text(errorMsg)
              .font(.caption)
              .foregroundStyle(.primary)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Retry") {
              Task { await viewModel.reloadInitialCatalog() }
            }
            .font(.caption.weight(.bold))
            .accessibilityIdentifier("intel.explorer.retry")
          }
          .padding(12)
          .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        searchAndSuggestionsSection
        macroCategoryStrip
        sceneSubfilterStrip

        if !viewModel.warmStartCommunities.isEmpty && viewModel.searchQuery.isEmpty && viewModel.selectedMacroCategory == .all {
          warmStartOrbitSection
        }

        communitiesGridSection
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .padding(.bottom, 128)
      .frame(maxWidth: 1040)
      .frame(maxWidth: .infinity)
    }
    .scrollDismissesKeyboard(.interactively)
    .safeAreaInset(edge: .bottom) {
      orbitSelectionDock
    }
  }

  // MARK: - Hero Header

  private var heroHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Group {
          if viewModel.totalCommunitiesCount > 0 {
            Label {
              Text("\(viewModel.totalCommunitiesCount) Live Communities", comment: "Badge count of live communities in scene explorer.")
            } icon: {
              Image(systemName: "sparkles")
            }
          } else {
            Label {
              Text("Living Network Map", comment: "Badge title in scene explorer when count is loading.")
            } icon: {
              Image(systemName: "sparkles")
            }
          }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.12), in: Capsule())

        if viewModel.boostedCount > 0 {
          Label {
            Text("\(viewModel.boostedCount) Boosted 2×", comment: "Badge count of heart-boosted 2x scenes in explorer.")
          } icon: {
            Image(systemName: "heart.fill")
          }
          .font(.caption.weight(.semibold))
          .foregroundStyle(.pink)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(Color.pink.opacity(0.12), in: Capsule())
        }
      }

      Text("Find Your Corner of the Network")
        .font(.title2.weight(.bold))
        .foregroundStyle(.primary)

      Text("Pick scenes that spark your curiosity. Tap the heart to double-weight favorites, or peek inside any card to read real posts before choosing.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Search & Quick Chips

  private var searchAndSuggestionsSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)

        TextField(
          "Search subcultures, tools, genres, cities…",
          text: Binding(
            get: { viewModel.searchQuery },
            set: { viewModel.updateSearchQuery($0) }
          )
        )
        .textFieldStyle(.plain)
        .autocorrectionDisabled()
        .submitLabel(.search)
        .onSubmit {
          Task { await viewModel.performSearchNow() }
        }
        .accessibilityIdentifier("intel.search.field")

        if viewModel.isSearching {
          ProgressView()
            .controlSize(.small)
        } else if !viewModel.searchQuery.isEmpty {
          Button {
            viewModel.updateSearchQuery("")
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Clear search")
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 11)
      .adaptiveGlassEffect(
        style: .regular,
        in: RoundedRectangle(cornerRadius: 16, style: .continuous),
        interactive: true
      )

      if viewModel.searchQuery.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            Text("Try:")
              .font(.caption)
              .foregroundStyle(.secondary)

            ForEach(Self.quickSearchSuggestions, id: \.self) { term in
              Button {
                viewModel.searchQuery = term
                Task { await viewModel.performSearchNow() }
              } label: {
                Text(verbatim: term)
                  .font(.caption.weight(.medium))
                  .foregroundStyle(.primary)
                  .padding(.horizontal, 10)
                  .padding(.vertical, 5)
                  .background(Color.secondary.opacity(0.12), in: Capsule())
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("intel.search.suggestion.\(term)")
            }
          }
        }
      }
    }
  }

  // MARK: - Macro-Category Filter Strip

  private var macroCategoryStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(OnboardingMacroCategory.allCases) { category in
          let isSelected = viewModel.selectedMacroCategory == category
          Button {
            Task { await viewModel.selectMacroCategory(category) }
          } label: {
            HStack(spacing: 6) {
              Image(systemName: category.symbolName)
                .font(.caption.weight(.semibold))
              Text(category.title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? .white : .primary)
            .background(
              isSelected ? Color.accentColor : Color.secondary.opacity(0.12),
              in: Capsule()
            )
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("intel.category.\(category.id)")
          .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
      }
    }
  }

  // MARK: - Scene Sub-Filter Strip

  @ViewBuilder
  private var sceneSubfilterStrip: some View {
    let scenes = viewModel.filteredScenes
    if viewModel.selectedMacroCategory != .all && !scenes.isEmpty {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(scenes, id: \.sceneSlug) { scene in
            let isSelected = viewModel.selectedSceneSlug == scene.sceneSlug
            Button {
              Task { await viewModel.selectSceneFilter(slug: scene.sceneSlug) }
            } label: {
              HStack(spacing: 5) {
                Image(systemName: scene.symbolName)
                  .font(.caption2)
                Text(scene.sceneTitle)
                  .font(.caption.weight(.medium))
                Text(scene.cardCount, format: .number)
                  .font(.caption2.monospacedDigit())
                  .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
              }
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .foregroundStyle(isSelected ? .white : .primary)
              .background(
                isSelected ? Color.indigo : Color.secondary.opacity(0.09),
                in: Capsule()
              )
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }

  // MARK: - Warm-Start Orbit Strip

  private var warmStartOrbitSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Image(systemName: "sparkles.rectangle.stack.fill")
          .foregroundStyle(.indigo)
        Text("From Your Orbit")
          .font(.headline)
        Text("Based on accounts you already follow")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
          ForEach(viewModel.warmStartCommunities, id: \.communityId) { community in
            CommunityCardTileView(
              community: community,
              selectionWeight: viewModel.selectionWeight(for: community.communityId),
              faces: viewModel.sampleFaces(for: community),
              alreadyFollowingLine: SceneOnboardingViewModel.alreadyFollowingLine(
                count: community.alreadyFollowingCount
              ),
              onTogglePick: { viewModel.toggleCommunity(community) },
              onToggleBoost: { viewModel.toggleHeartBoost(for: community) },
              onPeek: { Task { await viewModel.openPeek(for: community) } },
              onAppear: { viewModel.requestSampleProfiles(for: community) }
            )
            .frame(width: 300)
          }
        }
      }
    }
  }

  // MARK: - Main Grid

  @ViewBuilder
  private var communitiesGridSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(gridSectionTitle)
          .font(.headline)
        Spacer()
        Text("\(viewModel.displayedCommunities.count) shown", comment: "Count of community cards currently displayed in explorer grid.")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      if viewModel.isLoadingCatalog {
        VStack(spacing: 14) {
          ProgressView()
          Text("Mapping live communities…")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
      } else if viewModel.displayedCommunities.isEmpty {
        ContentUnavailableView(
          "No Matching Scenes",
          systemImage: "sparkle.magnifyingglass",
          description: Text("Try a broader term like “design”, “linux”, “anime”, or clear filters.")
        )
        .padding(.vertical, 28)
      } else {
        LazyVGrid(columns: gridColumns, spacing: 14) {
          ForEach(viewModel.displayedCommunities, id: \.communityId) { community in
            CommunityCardTileView(
              community: community,
              selectionWeight: viewModel.selectionWeight(for: community.communityId),
              faces: viewModel.sampleFaces(for: community),
              alreadyFollowingLine: SceneOnboardingViewModel.alreadyFollowingLine(
                count: community.alreadyFollowingCount
              ),
              onTogglePick: { viewModel.toggleCommunity(community) },
              onToggleBoost: { viewModel.toggleHeartBoost(for: community) },
              onPeek: { Task { await viewModel.openPeek(for: community) } },
              onAppear: { viewModel.requestSampleProfiles(for: community) }
            )
          }
        }
      }
    }
  }

  private var gridSectionTitle: String {
    if !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return String(localized: "Search Results", comment: "Section header in scene explorer when showing search results.")
    }
    if viewModel.selectedMacroCategory != .all {
      return viewModel.selectedMacroCategory.title
    }
    return String(localized: "Diverse Scenes Across Bluesky", comment: "Default section header for featured scenes in scene explorer.")
  }

  // MARK: - Floating Liquid Glass Orbit Dock

  private var orbitSelectionDock: some View {
    VStack(spacing: 10) {
      if !viewModel.selectedCommunities.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(viewModel.selectedCommunities, id: \.communityId) { item in
              let isBoosted = viewModel.selectionWeight(for: item.communityId) >= 2
              Button {
                viewModel.removeSelection(communityId: item.communityId)
              } label: {
                HStack(spacing: 5) {
                  if isBoosted {
                    Image(systemName: "heart.fill")
                      .font(.caption2)
                      .foregroundStyle(.pink)
                  }
                  Text(item.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                  Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                  isBoosted ? Color.pink.opacity(0.16) : Color.accentColor.opacity(0.15),
                  in: Capsule()
                )
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.horizontal, 4)
        }
      }

      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Group {
            if viewModel.selectedCount == 0 {
              Text("Pick 1–5 scenes to start", comment: "Bottom dock prompt in scene explorer before any scenes are picked.")
            } else {
              Text("\(viewModel.selectedCount) scenes in your orbit", comment: "Bottom dock status showing how many scenes the user picked.")
            }
          }
          .font(.subheadline.weight(.semibold))

          Group {
            if viewModel.selectedCount == 0 {
              Text("Peek inside any card to preview real posts", comment: "Bottom dock hint in scene explorer when 0 scenes are picked.")
            } else if viewModel.selectedCount < 3 {
              Text("Add \(3 - viewModel.selectedCount) more for richer variety, or continue now", comment: "Bottom dock hint suggesting how many more scenes to pick.")
            } else {
              Text("Great mix — ready to tune your feed rhythm", comment: "Bottom dock hint when 3 or more scenes are picked.")
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        }

        Spacer(minLength: 8)

        Button {
          Task { await viewModel.advanceFromExplorerToCalibration() }
        } label: {
          HStack(spacing: 6) {
            Text("Tune My Taste", comment: "Primary button to advance from scene explorer to taste calibration.")
              .font(.subheadline.weight(.bold))
            Image(systemName: "arrow.forward")
              .font(.caption.weight(.bold))
          }
          .foregroundStyle(.white)
          .padding(.horizontal, 18)
          .padding(.vertical, 12)
          .background(
            viewModel.canAdvanceFromExplorer ? Color.accentColor : Color.secondary.opacity(0.35),
            in: Capsule()
          )
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canAdvanceFromExplorer)
        .accessibilityIdentifier("intel.orbit.continue")
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .adaptiveGlassEffect(
      style: .regular,
      in: RoundedRectangle(cornerRadius: 24, style: .continuous),
      interactive: true
    )
    .padding(.horizontal, 12)
    .padding(.bottom, 6)
  }
}
