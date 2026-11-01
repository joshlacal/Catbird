import NukeUI
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
        Label(
          viewModel.totalCommunitiesCount > 0
            ? "\(viewModel.totalCommunitiesCount.formatted()) Live Communities"
            : "Living Network Map",
          systemImage: "sparkles"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.12), in: Capsule())

        if viewModel.boostedCount > 0 {
          Label("\(viewModel.boostedCount) Boosted 2×", systemImage: "heart.fill")
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
                Text(term)
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
                Text("\(scene.cardCount)")
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
              onTogglePick: { viewModel.toggleCommunity(community) },
              onToggleBoost: { viewModel.toggleHeartBoost(for: community) },
              onPeek: { Task { await viewModel.openPeek(for: community) } }
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
        Text("\(viewModel.displayedCommunities.count) shown")
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
              onTogglePick: { viewModel.toggleCommunity(community) },
              onToggleBoost: { viewModel.toggleHeartBoost(for: community) },
              onPeek: { Task { await viewModel.openPeek(for: community) } }
            )
          }
        }
      }
    }
  }

  private var gridSectionTitle: String {
    if !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Search Results"
    }
    if viewModel.selectedMacroCategory != .all {
      return viewModel.selectedMacroCategory.title
    }
    return "Diverse Scenes Across Bluesky"
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
          Text(
            viewModel.selectedCount == 0
              ? "Pick 1–5 scenes to start"
              : "\(viewModel.selectedCount) \(viewModel.selectedCount == 1 ? "scene" : "scenes") in your orbit"
          )
          .font(.subheadline.weight(.semibold))

          Text(
            viewModel.selectedCount == 0
              ? "Peek inside any card to preview real posts"
              : (viewModel.selectedCount < 3 ? "Add \(3 - viewModel.selectedCount) more for richer variety, or continue now" : "Great mix — ready to tune your feed rhythm")
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        }

        Spacer(minLength: 8)

        Button {
          Task { await viewModel.advanceFromExplorerToCalibration() }
        } label: {
          HStack(spacing: 6) {
            Text("Tune My Taste")
              .font(.subheadline.weight(.bold))
            Image(systemName: "arrow.right")
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

// MARK: - Narrow Value-Typed Community Card Tile

struct CommunityCardTileView: View {
  let community: BlueCatbirdIntelDefs.CommunitySummary
  let selectionWeight: Int
  let onTogglePick: () -> Void
  let onToggleBoost: () -> Void
  let onPeek: () -> Void

  private var isPicked: Bool { selectionWeight >= 1 }
  private var isBoosted: Bool { selectionWeight >= 2 }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Top bar: Scene badge + Peek + Boost
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

      // Main tappable body
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("intel.card.\(community.communityId)")
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
  }
}
