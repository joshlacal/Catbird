import Petrel
import SwiftUI

/// Central hub for running and rerunning Catbird Intelligence onboarding features
/// on demand: Scene Explorer, Quick Taste Calibration, Starting Lineup, Feed Storefront,
/// Originals-Only repost management, and full Welcome Onboarding replay.
struct IntelligenceOnboardingHubView: View {
  @Environment(AppState.self) private var appState
  @Environment(SceneNavigationContext.self) private var sceneContext

  var initialFocus: SettingsControlID?

  @State private var activeSceneSession: SceneRerunSession?
  @State private var isShowingFeedStorefront = false
  @State private var isShowingWelcomeReplay = false
  @State private var confirmingReplayTips = false
  @State private var interests: [String] = []

  private struct SceneRerunSession: Identifiable {
    let id = UUID()
    let entryPoint: SceneOnboardingViewModel.EntryPoint
  }

  private var originalsOnlyCount: Int {
    appState.feedFilterSettings.mutedRepostAuthorDIDs.count
  }

  var body: some View {
    SettingsFocusedForm(initialFocus: initialFocus) {
      SettingsScopeSection()

      Section {
        VStack(alignment: .leading, spacing: 6) {
          Label("Catbird Intelligence Onboarding", systemImage: "sparkles")
            .appFont(AppTextRole.headline)
            .fontWeight(.semibold)
          Text("Rerun any part of Catbird’s community discovery, taste calibration, feed storefront, or welcome setup whenever you want to refresh your timeline.")
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
      }

      Section {
        Button {
          activeSceneSession = SceneRerunSession(entryPoint: .explorer)
        } label: {
          SettingsNavigationRow(
            title: "Explore Scenes & Build Lineup",
            summary: "Full 5-step map of 1,000+ live communities, post peeks, taste duels, and lineup",
            systemImage: "safari.fill",
            family: .feeds
          )
        }
        .settingsControl(.init(rawValue: "intel.sceneExplorer"))
        .accessibilityIdentifier("settings.intel.sceneExplorer")

        Button {
          activeSceneSession = SceneRerunSession(entryPoint: .quickCalibrate)
        } label: {
          SettingsNavigationRow(
            title: "Recalibrate Taste & Feed Pace",
            summary: "Auto-seed from your current orbit and jump into Taste Duels and Smart Repost Tamer",
            systemImage: "slider.horizontal.below.sun.max",
            family: .feeds
          )
        }
        .settingsControl(.init(rawValue: "intel.tasteCalibration"))
        .accessibilityIdentifier("settings.intel.tasteCalibration")

        Button {
          activeSceneSession = SceneRerunSession(entryPoint: .lineup)
        } label: {
          SettingsNavigationRow(
            title: "Rebuild Starting Lineup",
            summary: "Solve a fresh role-balanced set of voices, pinnable feeds, and starter packs",
            systemImage: "person.3.sequence.fill",
            family: .feeds
          )
        }
        .settingsControl(.init(rawValue: "intel.startingLineup"))
        .accessibilityIdentifier("settings.intel.startingLineup")

        Button {
          isShowingFeedStorefront = true
        } label: {
          SettingsNavigationRow(
            title: "Browse Feed Storefront",
            summary: "Scan popular, follow-liked, and categorized feeds with live post previews",
            systemImage: "square.grid.2x2.fill",
            family: .feeds
          )
        }
        .settingsControl(.init(rawValue: "intel.feedStorefront"))
        .accessibilityIdentifier("settings.intel.feedStorefront")
      } header: {
        Text("Community Intelligence")
      }

      Section {
        NavigationLink {
          OriginalsOnlyAccountsView()
        } label: {
          SettingsNavigationRow(
            title: "Originals-Only Accounts",
            summary: originalsOnlyCount == 0
              ? String(localized: "No accounts currently muted for reposts", comment: "Summary when zero accounts are muted for reposts.")
              : String(localized: "\(originalsOnlyCount) accounts have reposts hidden", comment: "Summary showing how many accounts have reposts hidden in Originals-Only mode."),
            systemImage: "arrow.2.squarepath",
            family: .feeds
          )
        }
        .settingsControl(.init(rawValue: "intel.originalsOnly"))
        .accessibilityIdentifier("settings.intel.originalsOnly")
      } header: {
        Text("Active Repost Tamer")
      }

      Section {
        Button {
          isShowingWelcomeReplay = true
        } label: {
          SettingsNavigationRow(
            title: "Rerun Welcome Onboarding Now",
            summary: "Walk through Avatar, Interests, Scene Intelligence, and Feed Discovery immediately",
            systemImage: "arrow.counterclockwise.circle.fill",
            family: .support
          )
        }
        .settingsControl(.init(rawValue: "intel.rerunWelcome"))
        .accessibilityIdentifier("settings.intel.rerunWelcome")

        Button {
          confirmingReplayTips = true
        } label: {
          SettingsNavigationRow(
            title: "Reset Tips & Onboarding on Next Launch",
            summary: "Clears TipKit tips and queues welcome onboarding on next launch",
            systemImage: "lightbulb",
            family: .support
          )
        }
        .accessibilityIdentifier("settings.intel.resetTips")
      } header: {
        Text("Welcome & Tips")
      }
    }
    .navigationTitle("Catbird Intelligence")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .task(id: appState.userDID) {
      if let prefs = try? await appState.preferencesManager.getPreferences() {
        interests = prefs.interests
      }
    }
    .sheet(item: $activeSceneSession) { session in
      NavigationStack {
        SceneIntelligenceOnboardingView(
          mode: .tuneExistingFeed,
          entryPoint: session.entryPoint,
          selectedInterests: interests,
          onComplete: {
            activeSceneSession = nil
          },
          onSkip: {
            activeSceneSession = nil
          }
        )
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close") {
              activeSceneSession = nil
            }
          }
        }
      }
      .applyAppStateEnvironment(appState)
      .environment(sceneContext)
    }
    .sheet(isPresented: $isShowingFeedStorefront) {
      AddFeedSheet()
        .applyAppStateEnvironment(appState)
        .environment(sceneContext)
    }
    .sheet(isPresented: $isShowingWelcomeReplay) {
      WelcomeOnboardingView(isReplay: true, initialStep: 0)
        .applyAppStateEnvironment(appState)
        .environment(sceneContext)
    }
    .confirmationDialog(
      "Reset Tips & Onboarding?",
      isPresented: $confirmingReplayTips,
      titleVisibility: .visible
    ) {
      Button("Reset for Next Launch") {
        appState.onboardingManager.resetAllOnboarding(for: appState.userDID)
        appState.toastManager.show(ToastItem(
          message: String(localized: "Onboarding and tips will appear again the next time you open Catbird.", comment: "Toast shown after resetting onboarding and tips."),
          icon: "sparkles"
        ))
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Welcome onboarding for this account and Catbird tips on this device will appear again the next time you open Catbird.")
    }
  }
}
