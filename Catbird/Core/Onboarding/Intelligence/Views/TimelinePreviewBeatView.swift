import Petrel
import PetrelCatbird
import SwiftUI

struct TimelinePreviewBeatView: View {
  @Bindable var viewModel: SceneOnboardingViewModel
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          headerSection
          inlineRhythmStrip
          postsStreamSection
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 110)
      }

      bottomActionDock
    }
    .accessibilityIdentifier("intel.beat.preview")
  }

  private var headerSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Label("Live Feed Preview", systemImage: "rectangle.stack.person.crop.fill")
          .font(.caption.weight(.semibold))
          .foregroundStyle(Color.accentColor)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(Color.accentColor.opacity(0.12), in: Capsule())

        Spacer()

        if viewModel.previewEstimatedDailyPosts > 0 {
          Label("~\(viewModel.previewEstimatedDailyPosts) posts/day", systemImage: "waveform.path.ecg")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.12), in: Capsule())
        }
      }

      Text("A Taste of Tomorrow’s Timeline")
        .font(.title2.weight(.bold))

      Text("Real recent posts from the communities in your orbit. Tap Pin Voice on anyone you already love to lock them into your starting lineup.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  private var inlineRhythmStrip: some View {
    HStack(spacing: 8) {
      PreviewPacePill(
        title: "Calm",
        isSelected: viewModel.pace == .value_calm,
        action: { Task { await viewModel.updatePace(.value_calm) } }
      )
      PreviewPacePill(
        title: "Balanced",
        isSelected: viewModel.pace == .value_balanced,
        action: { Task { await viewModel.updatePace(.value_balanced) } }
      )
      PreviewPacePill(
        title: "Lively",
        isSelected: viewModel.pace == .value_lively,
        action: { Task { await viewModel.updatePace(.value_lively) } }
      )

      Spacer()

      if !viewModel.pinnedDIDs.isEmpty {
        Label("\(viewModel.pinnedDIDs.count) pinned", systemImage: "pin.fill")
          .font(.caption.weight(.semibold).monospacedDigit())
          .foregroundStyle(Color.accentColor)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(Color.accentColor.opacity(0.14), in: Capsule())
      }
    }
  }

  @ViewBuilder
  private var postsStreamSection: some View {
    if viewModel.isLoadingPreview {
      VStack(spacing: 12) {
        ProgressView()
        Text("Hydrating real posts across your chosen scenes…")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 48)
    } else if viewModel.previewPosts.isEmpty {
      VStack(spacing: 12) {
        Image(systemName: "sparkles.rectangle.stack")
          .font(.system(size: 36))
          .foregroundStyle(Color.accentColor)
        Text("Ready to Assemble Your Lineup")
          .font(.headline)
        Text("Continue to inspect your role-balanced creator lineup with per-account controls.")
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
    } else if horizontalSizeClass == .regular {
      LazyVGrid(
        columns: [
          GridItem(.flexible(), spacing: 14, alignment: .top),
          GridItem(.flexible(), spacing: 14, alignment: .top),
        ],
        spacing: 14
      ) {
        ForEach(viewModel.previewPosts) { post in
          HydratedPostCardView(
            post: post,
            isPinned: viewModel.isAuthorPinned(post.authorDID),
            onTogglePin: { viewModel.togglePinAuthor(did: post.authorDID) }
          )
        }
      }
    } else {
      LazyVStack(spacing: 12) {
        ForEach(viewModel.previewPosts) { post in
          HydratedPostCardView(
            post: post,
            isPinned: viewModel.isAuthorPinned(post.authorDID),
            onTogglePin: { viewModel.togglePinAuthor(did: post.authorDID) }
          )
        }
      }
    }
  }

  private var bottomActionDock: some View {
    Button {
      Task { await viewModel.advanceToStartingLineup() }
    } label: {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 1) {
          Text("See My Starting Lineup")
            .font(.headline)
          Text("Inspect roles, Originals-Only taming & feeds")
            .font(.caption2)
            .opacity(0.88)
        }
        Spacer()
        Image(systemName: "arrow.right.circle.fill")
          .font(.title3)
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 20)
      .frame(height: 54)
      .background(Color.accentColor, in: Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("intel.preview.toLineup")
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .adaptiveGlassEffect(
      style: .regular,
      in: RoundedRectangle(cornerRadius: 28, style: .continuous)
    )
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
  }
}

private struct PreviewPacePill: View {
  let title: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(isSelected ? .white : .primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
          Capsule()
            .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
        )
    }
    .buttonStyle(.plain)
  }
}
