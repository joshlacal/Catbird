import Petrel
import PetrelCatbird
import SwiftUI

/// Master 5-Beat Community Scene Intelligence Onboarding & Feed Tuning Experience.
public struct SceneIntelligenceOnboardingView: View {
  @Environment(AppState.self) private var appState

  let mode: SceneOnboardingViewModel.ExperienceMode
  let entryPoint: SceneOnboardingViewModel.EntryPoint
  let selectedInterests: [String]
  let injectedService: (any CatbirdIntelligenceServicing)?
  let preconfiguredViewModel: SceneOnboardingViewModel?
  let onComplete: () -> Void
  let onSkip: (() -> Void)?

  @State private var viewModel: SceneOnboardingViewModel?
  @State private var boundUserDID: String?
  @State private var peekDetent: PresentationDetent = .large

  public init(
    mode: SceneOnboardingViewModel.ExperienceMode = .newAccountOnboarding,
    entryPoint: SceneOnboardingViewModel.EntryPoint = .explorer,
    selectedInterests: [String] = [],
    service: (any CatbirdIntelligenceServicing)? = nil,
    preconfiguredViewModel: SceneOnboardingViewModel? = nil,
    onComplete: @escaping () -> Void,
    onSkip: (() -> Void)? = nil
  ) {
    self.mode = mode
    self.entryPoint = entryPoint
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
            .appFont(AppTextRole.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: appState.userDID) {
      if let preconfiguredViewModel {
        if viewModel == nil {
          self.viewModel = preconfiguredViewModel
        }
        return
      }
      if viewModel != nil && boundUserDID == appState.userDID {
        return
      }
      self.boundUserDID = appState.userDID
      let svc: any CatbirdIntelligenceServicing
      if let injectedService {
        svc = injectedService
      } else if let client = appState.atProtoClient,
                !appState.userDID.isEmpty,
                !appState.isAccountSwitchSuspended {
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
      await created.startEntry(entryPoint)
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
        memberSections: vm.peekMemberSections,
        lineupHeading: { count in vm.peekLineupHeading(count: count) },
        profilesByDID: vm.sceneProfiles.profilesByDID,
        isAuthorPinned: { did in vm.isAuthorPinned(did) },
        onTogglePick: { vm.toggleCommunity(peek.community) },
        onToggleBoost: { vm.toggleHeartBoost(for: peek.community) },
        onTogglePinAuthor: { did in vm.togglePinAuthor(did: did) },
        onOpenNeighbor: { neighbor in
          Task { await vm.openPeek(for: neighbor) }
        },
        onMemberAppear: { did in vm.requestPeekProfiles(aroundMember: did) },
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
      .explorer, .calibration, .preview, .lineup
    ]

    return VStack(spacing: 8) {
      HStack(spacing: 10) {
        if vm.currentBeat != .explorer {
          CatbirdChip(
            title: "Back", systemImage: "chevron.backward", size: .sm,
            action: { vm.goBackOneBeat() }
          )
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
                  .appFont(AppTextRole.caption2)
                  .fontWeight(.bold)
                  .foregroundStyle(.primary)
                  .lineLimit(1)
              }
            }
            .padding(.horizontal, isActive ? 8 : 2)
            .padding(.vertical, 4)
            .background(
              Capsule(style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
            )
          }
        }

        Spacer()

        if let onSkip, vm.currentBeat == .explorer, mode == .newAccountOnboarding {
          Button("Skip", action: onSkip)
            .appFont(AppTextRole.caption)
            .fontWeight(.semibold)
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
          .appFont(size: 64, weight: .bold, relativeTo: .body)
          .foregroundStyle(Color.accentColor)
          .padding(24)
          .adaptiveGlassEffect(style: .regular, in: Circle())

        VStack(spacing: 10) {
          Group {
            if mode == .tuneExistingFeed {
              Text("Your Feed Is Tuned", comment: "Celebration title after tuning an existing feed.")
            } else {
              Text("Your Orbit Is Live", comment: "Celebration title after completing scene onboarding.")
            }
          }
          .appFont(AppTextRole.largeTitle)
          .fontWeight(.bold)
          .multilineTextAlignment(.center)

          Text(vm.celebrationSummaryLine)
            .appFont(AppTextRole.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
        }

        if let receipt {
          HStack(spacing: 12) {
            CelebrationStatCard(
              value: receipt.followedCount,
              label: LocalizedStringResource("Voices Followed", comment: "Stat card label for count of accounts followed in onboarding."),
              symbol: "person.2.fill"
            )
            if receipt.originalsOnlyCount > 0 {
              CelebrationStatCard(
                value: receipt.originalsOnlyCount,
                label: LocalizedStringResource("Originals Only", comment: "Stat card label for count of accounts set to Originals Only."),
                symbol: "sparkles"
              )
            }
            if receipt.pinnedFeedsCount > 0 {
              CelebrationStatCard(
                value: receipt.pinnedFeedsCount,
                label: LocalizedStringResource("Feeds Pinned", comment: "Stat card label for count of community feeds pinned."),
                symbol: "pin.fill"
              )
            }
          }
          .padding(.horizontal, 20)
        }

        Spacer(minLength: 24)

        VStack(spacing: 12) {
          Button(action: onComplete) {
            HStack(spacing: 8) {
              if mode == .tuneExistingFeed {
                Text("Back to Catbird", comment: "Button to exit scene tuning and return to the app.")
              } else {
                Text("Continue", comment: "Button to advance from scene onboarding celebration.")
              }
              Image(systemName: "arrow.forward")
            }
          }
          .buttonStyle(.catbird(.primary, size: .lg, fullWidth: true))
          .accessibilityIdentifier("intel.celebration.continue")

          if mode == .tuneExistingFeed {
            Button {
              Task { await vm.resetSession() }
            } label: {
              Label("Explore More Scenes", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.catbird(.tonal, size: .lg, fullWidth: true))
            .accessibilityIdentifier("intel.celebration.rerun")
          }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
      }
    }
    .accessibilityIdentifier("intel.beat.celebration")
  }
}

private struct CelebrationStatCard: View {
  let value: Int
  let label: LocalizedStringResource
  let symbol: String

  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: symbol)
        .appFont(AppTextRole.subheadline)
        .fontWeight(.bold)
        .foregroundStyle(Color.accentColor)
      Text(value, format: .number)
        .appFont(AppTextRole.title2)
        .fontWeight(.bold)
        .monospacedDigit()
      Text(label)
        .appFont(AppTextRole.caption2)
        .fontWeight(.medium)
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
