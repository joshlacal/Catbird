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
              .appFont(AppTextRole.caption)
              .foregroundStyle(.primary)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Retry") {
              Task { await viewModel.reloadInitialCatalog() }
            }
            .appFont(AppTextRole.caption)
            .fontWeight(.bold)
            .accessibilityIdentifier("intel.explorer.retry")
          }
          .padding(12)
          .catbirdCard(.notice(.warning))
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
        if viewModel.totalCommunitiesCount > 0 {
          CatbirdBadge(
            Text("\(viewModel.totalCommunitiesCount) Live Communities", comment: "Badge count of live communities in scene explorer."),
            systemImage: "sparkles", tone: .accent)
        } else {
          CatbirdBadge(
            Text("Living Network Map", comment: "Badge title in scene explorer when count is loading."),
            systemImage: "sparkles", tone: .accent)
        }

        if viewModel.boostedCount > 0 {
          CatbirdBadge(
            Text("\(viewModel.boostedCount) Boosted 2×", comment: "Badge count of heart-boosted 2x scenes in explorer."),
            systemImage: "heart.fill", tone: .accent)
        }
      }

      Text("Find Your Corner of the Network")
        .appFont(AppTextRole.title2)
        .fontWeight(.bold)
        .foregroundStyle(.primary)

      Text("Pick scenes that spark your curiosity. Tap the heart to double-weight favorites, or peek inside any card to read real posts before choosing.")
        .appFont(AppTextRole.subheadline)
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
              .appFont(AppTextRole.caption)
              .foregroundStyle(.secondary)

            ForEach(Self.quickSearchSuggestions, id: \.self) { term in
              CatbirdChip(
                title: Text(verbatim: term),
                size: .sm,
                action: {
                  viewModel.searchQuery = term
                  Task { await viewModel.performSearchNow() }
                }
              )
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
          CatbirdChip(
            title: Text(category.title),
            systemImage: category.symbolName,
            isSelected: isSelected,
            size: .md,
            action: { Task { await viewModel.selectMacroCategory(category) } }
          )
          .accessibilityIdentifier("intel.category.\(category.id)")
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
            CatbirdChip(
              title: Text(verbatim: scene.sceneTitle) + Text(verbatim: " ")
                + Text(scene.cardCount, format: .number)
                  .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary),
              systemImage: scene.symbolName,
              isSelected: isSelected,
              size: .sm,
              action: { Task { await viewModel.selectSceneFilter(slug: scene.sceneSlug) } }
            )
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
          .foregroundStyle(Color.accentColor)
        Text("From Your Orbit")
          .appFont(AppTextRole.headline)
        Text("Based on accounts you already follow")
          .appFont(AppTextRole.caption)
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
          .appFont(AppTextRole.headline)
        Spacer()
        Text("\(viewModel.displayedCommunities.count) shown", comment: "Count of community cards currently displayed in explorer grid.")
          .appFont(AppTextRole.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }

      if viewModel.isLoadingCatalog {
        VStack(spacing: 14) {
          ProgressView()
          Text("Mapping live communities…")
            .appFont(AppTextRole.subheadline)
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
                      .appFont(AppTextRole.caption2)
                      .foregroundStyle(Color.accentColor)
                  }
                  Text(item.title)
                    .appFont(AppTextRole.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                  Image(systemName: "xmark.circle.fill")
                    .appFont(AppTextRole.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                  isBoosted ? Color.accentColor.opacity(0.28) : Color.accentColor.opacity(0.15),
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
          .appFont(AppTextRole.subheadline)
          .fontWeight(.semibold)

          Group {
            if viewModel.selectedCount == 0 {
              Text("Peek inside any card to preview real posts", comment: "Bottom dock hint in scene explorer when 0 scenes are picked.")
            } else if viewModel.selectedCount < 3 {
              Text("Add \(3 - viewModel.selectedCount) more for richer variety, or continue now", comment: "Bottom dock hint suggesting how many more scenes to pick.")
            } else {
              Text("Great mix — ready to tune your feed rhythm", comment: "Bottom dock hint when 3 or more scenes are picked.")
            }
          }
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        }

        Spacer(minLength: 8)

        Button {
          Task { await viewModel.advanceFromExplorerToCalibration() }
        } label: {
          HStack(spacing: 6) {
            Text("Tune My Taste", comment: "Primary button to advance from scene explorer to taste calibration.")
            Image(systemName: "arrow.forward")
          }
        }
        .buttonStyle(.catbird(.primary, size: .md))
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
