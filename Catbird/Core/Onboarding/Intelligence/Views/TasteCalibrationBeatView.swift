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
        Label("Tune Your Signal", systemImage: "slider.horizontal.below.sun.max")
          .font(.caption.weight(.semibold))
          .foregroundStyle(Color.accentColor)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(Color.accentColor.opacity(0.12), in: Capsule())

        Spacer()

        Button {
          Task { await viewModel.skipCalibrationDuels() }
        } label: {
          HStack(spacing: 4) {
            Text("Skip to Preview")
            Image(systemName: "arrow.right")
          }
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("intel.calibration.skip")
      }

      Text("Shape Your Daily Rhythm")
        .font(.title2.weight(.bold))

      Text("Set your preferred posting pace and compare adjacent sub-scenes so we pick the right balance of makers, anchors, and conversationalists.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  private var rhythmControlsCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 8) {
        Label("Daily Feed Pace", systemImage: "metronome.fill")
          .font(.subheadline.weight(.semibold))

        HStack(spacing: 8) {
          PaceOptionChip(
            title: "Calm",
            subtitle: "~18 voices",
            symbol: "leaf.fill",
            isSelected: viewModel.pace == .value_calm,
            action: { Task { await viewModel.updatePace(.value_calm) } }
          )
          .accessibilityIdentifier("intel.pace.calm")

          PaceOptionChip(
            title: "Balanced",
            subtitle: "~25 voices",
            symbol: "sparkles",
            isSelected: viewModel.pace == .value_balanced,
            action: { Task { await viewModel.updatePace(.value_balanced) } }
          )
          .accessibilityIdentifier("intel.pace.balanced")

          PaceOptionChip(
            title: "Lively",
            subtitle: "~34 voices",
            symbol: "bolt.fill",
            isSelected: viewModel.pace == .value_lively,
            action: { Task { await viewModel.updatePace(.value_lively) } }
          )
          .accessibilityIdentifier("intel.pace.lively")
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
              .font(.caption.weight(.bold))
              .foregroundStyle(Color.accentColor)
            Text("Smart Repost Tamer")
              .font(.subheadline.weight(.semibold))
          }
          Text("Follow prolific curators in Originals-Only mode so one loud reposter never floods your timeline.")
            .font(.caption)
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
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 44)
    } else if let duel = viewModel.activeDuelCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label(
            "Taste Duel \(viewModel.activeDuelIndex + 1) of \(viewModel.calibrationCards.count)",
            systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right.fill"
          )
          .font(.caption.weight(.bold))
          .foregroundStyle(Color.accentColor)

          Spacer()

          Text("Tap the vibe you want more of")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        Text(duel.prompt)
          .font(.headline)

        Text(
          duel.kind == "trap"
            ? "Disambiguates lookalike search terms so only the real scene enters your feed."
            : "Tunes the relative weight between neighboring sub-communities."
        )
        .font(.caption)
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
          .font(.system(size: 36))
          .foregroundStyle(Color.accentColor)
        Text("Your Scene Mix Is Crisp")
          .font(.headline)
        Text("No extra disambiguation needed — jump straight into a live preview of your future feed.")
          .font(.subheadline)
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
            title: "More A",
            symbol: "a.circle.fill",
            prominent: true,
            action: { Task { await viewModel.answerCurrentDuel(.value_a) } }
          )
          .accessibilityIdentifier("intel.duel.choiceA")

          DuelChoiceButton(
            title: "More B",
            symbol: "b.circle.fill",
            prominent: true,
            action: { Task { await viewModel.answerCurrentDuel(.value_b) } }
          )
          .accessibilityIdentifier("intel.duel.choiceB")
        }

        HStack(spacing: 8) {
          DuelChoiceButton(
            title: "Both Vibes!",
            symbol: "plus.magnifyingglass",
            prominent: false,
            action: { Task { await viewModel.answerCurrentDuel(.value_both) } }
          )
          .accessibilityIdentifier("intel.duel.choiceBoth")

          DuelChoiceButton(
            title: "Neither",
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
            Text("Preview My Future Feed")
              .font(.headline)
            Image(systemName: "arrow.right.circle.fill")
              .font(.headline)
          }
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)
          .frame(height: 50)
          .background(Color.accentColor, in: Capsule())
        }
        .buttonStyle(.plain)
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
}

private struct PaceOptionChip: View {
  let title: String
  let subtitle: String
  let symbol: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 4) {
        HStack(spacing: 4) {
          Image(systemName: symbol)
            .font(.caption.weight(.semibold))
          Text(title)
            .font(.subheadline.weight(.semibold))
        }
        Text(subtitle)
          .font(.caption2)
          .opacity(0.85)
      }
      .foregroundStyle(isSelected ? .white : .primary)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 10)
      .padding(.horizontal, 6)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
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

  @Environment(\.displayScale) private var displayScale

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 8) {
        Text(badge)
          .font(.subheadline.weight(.heavy))
          .foregroundStyle(.white)
          .frame(width: 26, height: 26)
          .background(Color.accentColor, in: Circle())

        VStack(alignment: .leading, spacing: 2) {
          Text(side.title)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.primary)
          Text(side.subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }

        Spacer(minLength: 4)
      }

      if !side.sceneTitle.isEmpty {
        HStack(spacing: 6) {
          Text(side.sceneTitle)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.1), in: Capsule())
        }
      }

      if !posts.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(posts) { post in
            VStack(alignment: .leading, spacing: 6) {
              HStack(spacing: 8) {
                AvatarThumbView(
                  url: post.authorAvatarURL,
                  fallbackText: post.authorDisplayName,
                  size: 22,
                  scale: displayScale
                )
                Text(post.authorDisplayName)
                  .font(.caption.weight(.semibold))
                  .lineLimit(1)
                Text("@\(post.authorHandle)")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
              if !post.text.isEmpty {
                Text(post.text)
                  .font(.caption)
                  .foregroundStyle(.primary)
                  .lineLimit(3)
              }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
            )
          }
        }
      }

      Button(action: onPickThis) {
        HStack(spacing: 6) {
          Text("Choose Option \(badge)")
            .font(.caption.weight(.semibold))
          Image(systemName: "hand.thumbsup.fill")
            .font(.caption2)
        }
        .foregroundStyle(Color.accentColor)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      }
      .buttonStyle(.plain)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color.secondary.opacity(0.07))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
    )
  }
}

private struct DuelChoiceButton: View {
  let title: String
  let symbol: String
  let prominent: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: symbol)
          .font(.subheadline.weight(.semibold))
        Text(title)
          .font(.subheadline.weight(.semibold))
      }
      .foregroundStyle(prominent ? .white : .primary)
      .frame(maxWidth: .infinity)
      .frame(height: prominent ? 44 : 38)
      .background(
        Capsule()
          .fill(prominent ? Color.accentColor : Color.secondary.opacity(0.14))
      )
    }
    .buttonStyle(.plain)
  }
}
