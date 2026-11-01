import Petrel
import PetrelCatbird
import SwiftUI

/// Master 5-Beat Community Scene Intelligence Onboarding & Feed Tuning Experience.
public struct SceneIntelligenceOnboardingView: View {
  @Environment(AppState.self) private var appState

  let mode: SceneOnboardingViewModel.ExperienceMode
  let selectedInterests: [String]
  let injectedService: (any CatbirdIntelligenceServicing)?
  let preconfiguredViewModel: SceneOnboardingViewModel?
  let onComplete: () -> Void
  let onSkip: (() -> Void)?

  @State private var viewModel: SceneOnboardingViewModel?
  @State private var peekDetent: PresentationDetent = .large

  public init(
    mode: SceneOnboardingViewModel.ExperienceMode = .newAccountOnboarding,
    selectedInterests: [String] = [],
    service: (any CatbirdIntelligenceServicing)? = nil,
    preconfiguredViewModel: SceneOnboardingViewModel? = nil,
    onComplete: @escaping () -> Void,
    onSkip: (() -> Void)? = nil
  ) {
    self.mode = mode
    self.selectedInterests = selectedInterests
    self.injectedService = service
    self.preconfiguredViewModel = preconfiguredViewModel
    self.onComplete = onComplete
    self.onSkip = onSkip
  }

  public var body: some View {
    Group {
      if let vm = viewModel {
        if vm.shouldFallbackToLegacySuggested, mode == .newAccountOnboarding {
          OnboardingSuggestedAccountsStep(
            selectedInterests: selectedInterests,
            onContinue: onComplete,
            onSkip: { (onSkip ?? onComplete)() }
          )
        } else {
          activeExperienceBody(vm: vm)
        }
      } else {
        VStack(spacing: 12) {
          ProgressView()
          Text("Opening Scene Explorer…")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task {
      if viewModel == nil {
        if let preconfiguredViewModel {
          self.viewModel = preconfiguredViewModel
        } else {
          let svc: any CatbirdIntelligenceServicing
          if let injectedService {
            svc = injectedService
          } else if let client = appState.atProtoClient {
            svc = LiveCatbirdIntelligenceService(appState: appState, client: client)
          } else {
            svc = UnavailableCatbirdIntelligenceService()
          }
          let created = SceneOnboardingViewModel(
            service: svc,
            mode: mode,
            initialInterests: selectedInterests
          )
          self.viewModel = created
          await created.loadInitialCatalog()
        }
      }
    }
  }

  @ViewBuilder
  private func activeExperienceBody(vm: SceneOnboardingViewModel) -> some View {
    VStack(spacing: 0) {
      if vm.currentBeat != .celebration {
        beatNavigationHeader(vm: vm)
      }

      ZStack {
        switch vm.currentBeat {
        case .explorer:
          SceneExplorerBeatView(viewModel: vm)
            .transition(.opacity)
        case .calibration:
          TasteCalibrationBeatView(viewModel: vm)
            .transition(.opacity)
        case .preview:
          TimelinePreviewBeatView(viewModel: vm)
            .transition(.opacity)
        case .lineup:
          StartingLineupBeatView(
            viewModel: vm,
            onSkipAll: onSkip
          )
          .transition(.opacity)
        case .celebration:
          celebrationBeatView(vm: vm)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
      }
      .animation(.easeInOut(duration: 0.24), value: vm.currentBeat)
    }
    .sheet(
      item: Binding(
        get: { vm.activePeek },
        set: { next in
          if next == nil {
            vm.closePeek()
          }
        }
      )
    ) { peek in
      ScenePeekSheet(
        state: peek,
        selectionWeight: vm.selectionWeight(for: peek.community.communityId),
        isAuthorPinned: { did in vm.isAuthorPinned(did) },
        onTogglePick: { vm.toggleCommunity(peek.community) },
        onToggleBoost: { vm.toggleHeartBoost(for: peek.community) },
        onTogglePinAuthor: { did in vm.togglePinAuthor(did: did) },
        onOpenNeighbor: { neighbor in
          Task { await vm.openPeek(for: neighbor) }
        },
        onClose: { vm.closePeek() }
      )
      .presentationDetents([.medium, .large], selection: $peekDetent)
      .presentationDragIndicator(.visible)
      .onAppear {
        peekDetent = .large
      }
    }
  }

  private func beatNavigationHeader(vm: SceneOnboardingViewModel) -> some View {
    let interactiveBeats: [SceneOnboardingViewModel.Beat] = [
      .explorer, .calibration, .preview, .lineup,
    ]

    return VStack(spacing: 8) {
      HStack(spacing: 10) {
        if vm.currentBeat != .explorer {
          Button {
            vm.goBackOneBeat()
          } label: {
            HStack(spacing: 4) {
              Image(systemName: "chevron.backward")
                .font(.caption.weight(.bold))
              Text("Back")
                .font(.caption.weight(.semibold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("intel.nav.back")
        }

        HStack(spacing: 6) {
          ForEach(interactiveBeats) { beat in
            let isActive = beat.rawValue == vm.currentBeat.rawValue
            let isCompleted = beat.rawValue < vm.currentBeat.rawValue

            HStack(spacing: 4) {
              Circle()
                .fill(
                  isActive || isCompleted
                    ? Color.accentColor
                    : Color.secondary.opacity(0.25)
                )
                .frame(width: 7, height: 7)

              if isActive {
                Text(beat.title)
                  .font(.caption2.weight(.bold))
                  .foregroundStyle(.primary)
                  .lineLimit(1)
              }
            }
            .padding(.horizontal, isActive ? 8 : 2)
            .padding(.vertical, 4)
            .background(
              Capsule()
                .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
            )
          }
        }

        Spacer()

        if let onSkip, vm.currentBeat == .explorer, mode == .newAccountOnboarding {
          Button("Skip", action: onSkip)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("intel.nav.skip")
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .padding(.bottom, 4)
    }
  }

  private func celebrationBeatView(vm: SceneOnboardingViewModel) -> some View {
    let receipt = vm.commitReceipt

    return ScrollView {
      VStack(spacing: 24) {
        Spacer(minLength: 28)

        Image(systemName: "sparkles")
          .font(.system(size: 64, weight: .bold))
          .foregroundStyle(Color.accentColor)
          .padding(24)
          .adaptiveGlassEffect(style: .regular, in: Circle())

        VStack(spacing: 10) {
          Text(mode == .tuneExistingFeed ? "Your Feed Is Tuned" : "Your Orbit Is Live")
            .font(.largeTitle.weight(.bold))
            .multilineTextAlignment(.center)

          Text("Real voices, balanced roles, and calm pacing — tailored to the scenes you chose.")
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
        }

        if let receipt {
          HStack(spacing: 12) {
            CelebrationStatCard(
              value: "\(receipt.followedCount)",
              label: "Voices Followed",
              symbol: "person.2.fill"
            )
            if receipt.originalsOnlyCount > 0 {
              CelebrationStatCard(
                value: "\(receipt.originalsOnlyCount)",
                label: "Originals Only",
                symbol: "sparkles"
              )
            }
            if receipt.pinnedFeedsCount > 0 {
              CelebrationStatCard(
                value: "\(receipt.pinnedFeedsCount)",
                label: "Feeds Pinned",
                symbol: "pin.fill"
              )
            }
          }
          .padding(.horizontal, 20)
        }

        Spacer(minLength: 24)

        Button(action: onComplete) {
          HStack(spacing: 8) {
            Text(mode == .tuneExistingFeed ? "Back to Catbird" : "Continue")
              .font(.headline)
            Image(systemName: "arrow.right")
              .font(.headline)
          }
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)
          .frame(height: 54)
          .background(Color.accentColor, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
        .accessibilityIdentifier("intel.celebration.continue")
      }
    }
    .accessibilityIdentifier("intel.beat.celebration")
  }
}

private struct CelebrationStatCard: View {
  let value: String
  let label: String
  let symbol: String

  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: symbol)
        .font(.subheadline.weight(.bold))
        .foregroundStyle(Color.accentColor)
      Text(value)
        .font(.title2.weight(.bold).monospacedDigit())
      Text(label)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 14)
    .padding(.horizontal, 8)
    .adaptiveGlassEffect(
      style: .regular,
      in: RoundedRectangle(cornerRadius: 18, style: .continuous)
    )
  }
}
