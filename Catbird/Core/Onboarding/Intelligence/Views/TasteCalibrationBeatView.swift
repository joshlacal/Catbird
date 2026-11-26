import Petrel
import PetrelCatbird
import SwiftUI

struct TasteCalibrationBeatView: View {
  @Bindable var viewModel: SceneOnboardingViewModel
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          heroHeader
          rhythmControlsCard
          duelArenaSection
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 120)
      }

      bottomActionBar
    }
    .accessibilityIdentifier("intel.beat.calibration")
  }

  private var heroHeader: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        CatbirdBadge(Text("Tune Your Signal"), systemImage: "slider.horizontal.below.sun.max", tone: .accent)

        Spacer()

        Button {
          Task { await viewModel.skipCalibrationDuels() }
        } label: {
          HStack(spacing: 4) {
            Text("Skip to Preview", comment: "Button to skip taste duels and jump to timeline preview.")
            Image(systemName: "arrow.forward")
          }
          .appFont(AppTextRole.caption)
          .fontWeight(.semibold)
          .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("intel.calibration.skip")
      }

      Text("Shape Your Daily Rhythm")
        .appFont(AppTextRole.title2)
        .fontWeight(.bold)

      Text("Set your preferred posting pace and compare adjacent sub-scenes so we pick the right balance of makers, anchors, and conversationalists.")
        .appFont(AppTextRole.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  private var rhythmControlsCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 8) {
        Label("Daily Feed Pace", systemImage: "metronome.fill")
          .appFont(AppTextRole.subheadline)
          .fontWeight(.semibold)

        HStack(spacing: 8) {
          PaceOptionChip(
            title: LocalizedStringResource("Calm", comment: "Pace option label for a relaxed daily feed rhythm."),
            subtitle: viewModel.paceSubtitle(for: .value_calm),
            symbol: "leaf.fill",
            isSelected: viewModel.pace == .value_calm,
            action: { Task { await viewModel.updatePace(.value_calm) } }
          )
          .accessibilityIdentifier("intel.pace.calm")

          PaceOptionChip(
            title: LocalizedStringResource("Balanced", comment: "Pace option label for a balanced daily feed rhythm."),
            subtitle: viewModel.paceSubtitle(for: .value_balanced),
            symbol: "sparkles",
            isSelected: viewModel.pace == .value_balanced,
            action: { Task { await viewModel.updatePace(.value_balanced) } }
          )
          .accessibilityIdentifier("intel.pace.balanced")

          PaceOptionChip(
            title: LocalizedStringResource("Lively", comment: "Pace option label for an active daily feed rhythm."),
            subtitle: viewModel.paceSubtitle(for: .value_lively),
            symbol: "bolt.fill",
            isSelected: viewModel.pace == .value_lively,
            action: { Task { await viewModel.updatePace(.value_lively) } }
          )
          .accessibilityIdentifier("intel.pace.lively")
        }

        if let paceFootnote = viewModel.paceFootnote {
          Text(paceFootnote)
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("intel.pace.footnote")
        }
      }

      Divider()

      Toggle(
        isOn: Binding(
          get: { viewModel.originalsOnlyForHeavyReposters },
          set: { enabled in
            Task { await viewModel.setSmartRepostTamer(enabled) }
          }
        )
      ) {
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Image(systemName: "arrow.2.squarepath")
              .appFont(AppTextRole.caption)
              .fontWeight(.bold)
              .foregroundStyle(Color.accentColor)
            Text("Smart Repost Tamer")
              .appFont(AppTextRole.subheadline)
              .fontWeight(.semibold)
          }
          Text("Follow prolific curators in Originals-Only mode so one loud reposter never floods your timeline.")
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
        }
      }
      .accessibilityIdentifier("intel.calibration.repostTamer")
    }
    .padding(16)
    .adaptiveGlassEffect(
      style: .regular,
      in: RoundedRectangle(cornerRadius: 20, style: .continuous)
    )
  }

  @ViewBuilder
  private var duelArenaSection: some View {
    if viewModel.isLoadingSwipes {
      VStack(spacing: 12) {
        ProgressView()
        Text("Preparing quick taste comparisons…")
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 44)
    } else if let duel = viewModel.activeDuelCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label {
            Text(
              "Taste Duel \(viewModel.activeDuelIndex + 1) of \(viewModel.calibrationCards.count)",
              comment: "Progress label for taste calibration duel — %1$lld is current duel number, %2$lld is total duels."
            )
          } icon: {
            Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right.fill")
          }
          .appFont(AppTextRole.caption)
          .fontWeight(.bold)
          .foregroundStyle(Color.accentColor)

          Spacer()

          Text("Tap the vibe you want more of")
            .appFont(AppTextRole.caption2)
            .foregroundStyle(.secondary)
        }

        Text(duel.prompt)
          .appFont(AppTextRole.headline)

        Text(Self.duelKindSubtitle(for: duel.kind))
        .appFont(AppTextRole.caption)
        .foregroundStyle(.secondary)

        if horizontalSizeClass == .regular {
          HStack(alignment: .top, spacing: 14) {
            DuelOptionCardView(
              badge: "A",
              side: duel.optionA,
              posts: hydratedDuelPosts(for: duel.optionA),
              onPickThis: {
                Task { await viewModel.answerCurrentDuel(.value_a) }
              }
            )
            DuelOptionCardView(
              badge: "B",
              side: duel.optionB,
              posts: hydratedDuelPosts(for: duel.optionB),
              onPickThis: {
                Task { await viewModel.answerCurrentDuel(.value_b) }
              }
            )
          }
        } else {
          VStack(spacing: 12) {
            DuelOptionCardView(
              badge: "A",
              side: duel.optionA,
              posts: hydratedDuelPosts(for: duel.optionA),
              onPickThis: {
                Task { await viewModel.answerCurrentDuel(.value_a) }
              }
            )
            DuelOptionCardView(
              badge: "B",
              side: duel.optionB,
              posts: hydratedDuelPosts(for: duel.optionB),
              onPickThis: {
                Task { await viewModel.answerCurrentDuel(.value_b) }
              }
            )
          }
        }
      }
    } else {
      VStack(spacing: 12) {
        Image(systemName: "checkmark.seal.fill")
          .appFont(size: 36, weight: .regular, relativeTo: .body)
          .foregroundStyle(Color.accentColor)
        Text("Your Scene Mix Is Crisp")
          .appFont(AppTextRole.headline)
        Text("No extra disambiguation needed — jump straight into a live preview of your future feed.")
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity)
      .padding(24)
      .background(
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .fill(Color.secondary.opacity(0.07))
      )
    }
  }

  @ViewBuilder
  private var bottomActionBar: some View {
    VStack(spacing: 10) {
      if viewModel.activeDuelCard != nil {
        HStack(spacing: 8) {
          DuelChoiceButton(
            title: LocalizedStringResource("More A", comment: "Taste duel choice button preferring Option A."),
            symbol: "a.circle.fill",
            prominent: true,
            action: { Task { await viewModel.answerCurrentDuel(.value_a) } }
          )
          .accessibilityIdentifier("intel.duel.choiceA")

          DuelChoiceButton(
            title: LocalizedStringResource("More B", comment: "Taste duel choice button preferring Option B."),
            symbol: "b.circle.fill",
            prominent: true,
            action: { Task { await viewModel.answerCurrentDuel(.value_b) } }
          )
          .accessibilityIdentifier("intel.duel.choiceB")
        }

        HStack(spacing: 8) {
          DuelChoiceButton(
            title: LocalizedStringResource("Both Vibes!", comment: "Taste duel choice button selecting both Option A and Option B."),
            symbol: "plus.magnifyingglass",
            prominent: false,
            action: { Task { await viewModel.answerCurrentDuel(.value_both) } }
          )
          .accessibilityIdentifier("intel.duel.choiceBoth")

          DuelChoiceButton(
            title: LocalizedStringResource("Neither", comment: "Taste duel choice button rejecting both options."),
            symbol: "xmark.circle",
            prominent: false,
            action: { Task { await viewModel.answerCurrentDuel(.value_neither) } }
          )
          .accessibilityIdentifier("intel.duel.choiceNeither")
        }
      } else {
        Button {
          Task { await viewModel.advanceToPreview() }
        } label: {
          HStack(spacing: 8) {
            Text("Preview My Future Feed", comment: "Button to advance from taste calibration to timeline preview.")
            Image(systemName: "arrow.forward.circle.fill")
          }
        }
        .buttonStyle(.catbird(.primary, size: .lg, fullWidth: true))
        .accessibilityIdentifier("intel.calibration.previewButton")
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .adaptiveGlassEffect(
      style: .regular,
      in: RoundedRectangle(cornerRadius: 24, style: .continuous)
    )
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
  }

  private func hydratedDuelPosts(
    for side: BlueCatbirdOnboardingDefs.CalibrationOption
  ) -> [HydratedSamplePost] {
    side.samplePostUris.prefix(2).compactMap { viewModel.duelPostsByURI[$0.uriString()] }
  }

  static func duelKindSubtitle(for kind: String) -> String {
    switch kind {
    case "collision_trap", "ambiguity_split", "trap":
      String(
        localized: "Quick Clarification · Disambiguates lookalike search terms so only the real scene enters your feed.",
        comment: "Explanation shown under a lookalike-term taste duel prompt."
      )
    default:
      String(
        localized: "Tunes the relative weight between neighboring sub-communities.",
        comment: "Explanation shown under an adjacent-community taste duel prompt."
      )
    }
  }
}

private struct PaceOptionChip: View {
  let title: LocalizedStringResource
  let subtitle: String
  let symbol: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 4) {
        HStack(spacing: 4) {
          Image(systemName: symbol)
            .appFont(AppTextRole.caption)
            .fontWeight(.semibold)
          Text(title)
            .appFont(AppTextRole.subheadline)
            .fontWeight(.semibold)
        }
        Text(subtitle)
          .appFont(AppTextRole.caption2)
          .opacity(0.85)
      }
      .foregroundStyle(isSelected ? .white : .primary)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 10)
      .padding(.horizontal, 6)
      .background(
        Radius.md.shape
          .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.1))
      )
    }
    .buttonStyle(.plain)
  }
}

private struct DuelOptionCardView: View {
  let badge: String
  let side: BlueCatbirdOnboardingDefs.CalibrationOption
  let posts: [HydratedSamplePost]
  let onPickThis: () -> Void


  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 8) {
        Text(verbatim: badge)
          .appFont(AppTextRole.subheadline)
          .fontWeight(.heavy)
          .foregroundStyle(.white)
          .frame(width: 26, height: 26)
          .background(Color.accentColor, in: Circle())

        VStack(alignment: .leading, spacing: 2) {
          Text(side.title)
            .appFont(AppTextRole.subheadline)
            .fontWeight(.bold)
            .foregroundStyle(.primary)
          Text(side.subtitle)
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }

        Spacer(minLength: 4)
      }

      if !side.sceneTitle.isEmpty {
        HStack(spacing: 6) {
          CatbirdBadge(Text(verbatim: side.sceneTitle), tone: .accent)
        }
      }

      if !posts.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(posts) { post in
            CompactPostCard(
              avatarURL: post.authorAvatarURL,
              displayName: post.authorDisplayName,
              handle: post.authorHandle,
              text: post.text,
              did: post.authorDID,
              lineLimit: 3
            )
          }
        }
      }

      Button(action: onPickThis) {
        HStack(spacing: 6) {
          Text("Choose Option \(badge)", comment: "Button to select option A or B in a taste duel — variable is letter badge A or B.")
          Image(systemName: "hand.thumbsup.fill")
        }
      }
      .buttonStyle(.catbird(.tonal, size: .md, fullWidth: true))
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .catbirdCard(.panel, radius: .lg)
  }
}

private struct DuelChoiceButton: View {
  let title: LocalizedStringResource
  let symbol: String
  let prominent: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: symbol)
        Text(title)
      }
    }
    .buttonStyle(.catbird(prominent ? .primary : .tonal, size: .md, fullWidth: true))
  }
}
