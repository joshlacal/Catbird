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
        CatbirdBadge("Live Feed Preview", systemImage: "rectangle.stack.person.crop.fill", tone: .accent)

        Spacer()

        if viewModel.previewEstimatedDailyPosts > 0 {
          CatbirdBadge(
            Text("~\(viewModel.previewEstimatedDailyPosts) posts/day", comment: "Estimated daily post volume badge."),
            systemImage: "waveform.path.ecg", tone: .neutral)
        }
      }

      Text("A Taste of Tomorrow’s Timeline")
        .appFont(AppTextRole.title2)
        .fontWeight(.bold)

      Text("Real recent posts from the communities in your orbit. Tap Pin Voice on anyone you already love to lock them into your starting lineup.")
        .appFont(AppTextRole.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  private var inlineRhythmStrip: some View {
    HStack(spacing: 8) {
      PreviewPacePill(
        title: LocalizedStringResource("Calm", comment: "Pace option label for a relaxed daily feed rhythm."),
        isSelected: viewModel.pace == .value_calm,
        action: { Task { await viewModel.updatePace(.value_calm) } }
      )
      PreviewPacePill(
        title: LocalizedStringResource("Balanced", comment: "Pace option label for a balanced daily feed rhythm."),
        isSelected: viewModel.pace == .value_balanced,
        action: { Task { await viewModel.updatePace(.value_balanced) } }
      )
      PreviewPacePill(
        title: LocalizedStringResource("Lively", comment: "Pace option label for an active daily feed rhythm."),
        isSelected: viewModel.pace == .value_lively,
        action: { Task { await viewModel.updatePace(.value_lively) } }
      )

      Spacer()

      if !viewModel.pinnedDIDs.isEmpty {
        CatbirdBadge(
          Text("\(viewModel.pinnedDIDs.count) pinned", comment: "Badge showing how many authors the user pinned during timeline preview."),
          systemImage: "pin.fill", tone: .accent)
      }
    }
  }

  @ViewBuilder
  private var postsStreamSection: some View {
    if viewModel.isLoadingPreview {
      VStack(spacing: 12) {
        ProgressView()
        Text("Hydrating real posts across your chosen scenes…")
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 48)
    } else if viewModel.previewPosts.isEmpty {
      VStack(spacing: 12) {
        Image(systemName: "sparkles.rectangle.stack")
          .appFont(size: 36, weight: .regular, relativeTo: .body)
          .foregroundStyle(Color.accentColor)
        Text("Ready to Assemble Your Lineup")
          .appFont(AppTextRole.headline)
        Text("Continue to review the accounts picked from each of your scenes, with per-account controls.")
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
            .appFont(AppTextRole.headline)
          Text("Inspect roles, Originals-Only taming & feeds")
            .appFont(AppTextRole.caption2)
            .opacity(0.88)
            .lineLimit(2)
        }
        Spacer()
        Image(systemName: "arrow.forward.circle.fill")
          .appFont(AppTextRole.title3)
      }
      .padding(.vertical, Space.sm)
    }
    .buttonStyle(.catbird(.primary, size: .lg, fullWidth: true))
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
  let title: LocalizedStringResource
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    CatbirdChip(title: Text(title), isSelected: isSelected, size: .sm, action: action)
  }
}
