#if DEBUG
import Foundation
import Petrel
import PetrelCatbird
import SwiftData
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Disposable, unauthenticated DEBUG presentation fixture for exercising the 5-Beat
/// Community Scene Intelligence onboarding flow against a local `catbird-intel` XRPC server
/// and read-only public Bluesky hydration (`<= 4 req/s`).
@MainActor
struct OnboardingIntelligenceUIFixture: View {
  static let launchArgument = "--onboarding-intel-ui-fixture"

  @State private var appState: AppState?
  @State private var sceneContext: SceneNavigationContext?
  @State private var container: ModelContainer?
  @State private var viewModel: SceneOnboardingViewModel?
  @State private var failure: String?

  private let arguments = ProcessInfo.processInfo.arguments

  private var intelOriginURL: URL {
    let raw = argumentValue(prefix: "--intel-origin=") ?? "http://127.0.0.1:3210"
    return URL(string: raw) ?? URL(string: "http://127.0.0.1:3210")!
  }

  private var initialBeatArg: String {
    argumentValue(prefix: "--intel-initial-beat=") ?? "explorer"
  }

  private var searchArg: String? {
    argumentValue(prefix: "--intel-search=")
  }

  private var openPeekArg: Int? {
    argumentValue(prefix: "--intel-open-peek=").flatMap(Int.init)
  }

  private var presetPicksArg: [(cid: Int, weight: Int)] {
    guard let raw = argumentValue(prefix: "--intel-preset-picks="), !raw.isEmpty else {
      return []
    }
    return raw.split(separator: ",").compactMap { token in
      let parts = token.split(separator: ":")
      guard let first = parts.first, let cid = Int(first) else { return nil }
      let weight = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
      return (cid, max(1, min(2, weight)))
    }
  }

  var body: some View {
    Group {
      if let appState, let container, let sceneContext, let viewModel {
        NavigationStack {
          SceneIntelligenceOnboardingView(
            mode: .newAccountOnboarding,
            selectedInterests: ["dev", "art", "games"],
            preconfiguredViewModel: viewModel,
            onComplete: {},
            onSkip: {}
          )
        }
        .environment(appState)
        .environment(sceneContext)
        .environment(AppStateManager.shared)
        .environment(\.fontManager, appState.fontManager)
        .modelContainer(container)
        .preferredColorScheme(arguments.contains("--intel-dark") ? .dark : .light)
      } else if let failure {
        ContentUnavailableView(
          "Onboarding Intelligence Fixture Failed",
          systemImage: "exclamationmark.triangle",
          description: Text(failure)
        )
        .accessibilityIdentifier("intel.fixture.failure")
      } else {
        ProgressView("Preparing Scene Intelligence Showcase…")
      }
    }
    .task { await prepare() }
    .onDisappear {
      sceneContext?.invalidate()
      appState?.cleanup()
    }
  }

  @MainActor
  private func prepare() async {
    guard appState == nil else { return }
    do {
      try Self.requireUnauthenticatedHost()
      PetrelCatbirdLexicons.register()

      let accountDID = "did:plc:intelfixture" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
      let suiteName = "intel.native.fixture.\(UUID().uuidString)"
      guard let defaults = UserDefaults(suiteName: suiteName) else {
        throw FixtureError.defaultsUnavailable
      }

      let modelContainer = try ModelContainer(
        for: AppSettingsModel.self, Preferences.self, DraftPost.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
      )
      modelContainer.mainContext.insert(AppSettingsModel(accountDID: accountDID))
      modelContainer.mainContext.insert(Preferences(accountDID: accountDID))
      try modelContainer.mainContext.save()

      let publicAppViewClient = await ATProtoClient(
        baseURL: URL(string: "https://public.api.bsky.app")!
      )
      let state = AppState(
        userDID: accountDID,
        client: publicAppViewClient,
        regulatoryChecker: NoAgePrompt()
      )
      state.composerDraftManager.configureForTesting(modelContext: modelContainer.mainContext)
      state.appSettings.initialize(with: modelContainer.mainContext, accountDID: accountDID)

      let draftManager = ComposerDraftManager(
        accountDID: accountDID,
        modelContext: modelContainer.mainContext,
        defaults: defaults
      )
      let sceneID = UUID()
      let editingSession = SceneComposerEditingSession(
        manager: draftManager,
        accountDID: accountDID,
        sceneID: sceneID,
        defaults: defaults
      )
      let navContext = SceneNavigationContext(
        appState: state,
        sceneID: sceneID,
        composerEditingSession: editingSession
      )

      let showcaseService = LoopbackShowcaseIntelligenceService(
        intelOrigin: intelOriginURL,
        publicAppViewClient: publicAppViewClient,
        appState: state
      )
      let vm = SceneOnboardingViewModel(
        service: showcaseService,
        mode: .newAccountOnboarding,
        initialInterests: ["dev", "art", "games"]
      )
      await vm.loadInitialCatalog()

      // Apply optional deterministic launch presets for multi-beat Simulator inspection
      for pick in presetPicksArg {
        let summary: BlueCatbirdIntelDefs.CommunitySummary?
        if let existing = vm.knownCommunitiesById[pick.cid] {
          summary = existing
        } else if let fetched = try? await showcaseService.getCommunity(communityId: pick.cid).community {
          summary = fetched
        } else {
          summary = nil
        }
        if let summary {
          if pick.weight >= 2 {
            vm.toggleHeartBoost(for: summary)
          } else {
            vm.toggleCommunity(summary)
          }
        }
      }

      if let query = searchArg, !query.isEmpty {
        vm.searchQuery = query
        await vm.performSearchNow()
      }

      if let peekCid = openPeekArg {
        let summary: BlueCatbirdIntelDefs.CommunitySummary?
        if let existing = vm.knownCommunitiesById[peekCid] {
          summary = existing
        } else {
          summary = try? await showcaseService.getCommunity(communityId: peekCid).community
        }
        if let summary {
          await vm.openPeek(for: summary)
        }
      }

      switch initialBeatArg {
      case "calibration":
        await vm.advanceFromExplorerToCalibration()
      case "preview":
        await vm.advanceToPreview()
      case "lineup":
        await vm.advanceToStartingLineup()
      case "celebration":
        await vm.advanceToStartingLineup()
        await vm.commitStartingLineup()
      default:
        break
      }

      self.container = modelContainer
      self.sceneContext = navContext
      self.appState = state
      self.viewModel = vm
    } catch {
      failure = error.localizedDescription
    }
  }

  private func argumentValue(prefix: String) -> String? {
    arguments.first(where: { $0.hasPrefix(prefix) })
      .map { String($0.dropFirst(prefix.count)) }
  }

  private static func requireUnauthenticatedHost() throws {
    let shared = AppStateManager.shared
    guard shared.authentication.client == nil,
          shared.authentication.state.userDID == nil,
          !shared.authentication.state.isAuthenticating,
          shared.lifecycle.appState == nil,
          shared.lifecycle.userDID == nil else {
      throw FixtureError.authenticatedHost
    }
  }

  private enum FixtureError: LocalizedError {
    case authenticatedHost
    case defaultsUnavailable

    var errorDescription: String? {
      switch self {
      case .authenticatedHost:
        "Use an unauthenticated simulator session when launching OnboardingIntelligenceUIFixture."
      case .defaultsUnavailable:
        "Failed to initialize isolated UserDefaults suite."
      }
    }
  }

  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal {
      PlatformAgeSignal(requirement: .none, ageBand: nil, significantChangeConsentRequired: false)
    }
    #if os(iOS)
    @MainActor func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? {
      nil
    }
    #endif
  }
}
#endif
