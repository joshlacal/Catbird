import NukeUI
import SwiftUI
import Petrel

struct SettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var currentColorScheme
  @State private var isLoggingOut = false
  @State private var error: Error?
  @State private var isShowingAccountSwitcher = false
  @State private var availableAccounts: Int = 0

  // Profile management
  @State private var profile: AppBskyActorDefs.ProfileViewDetailed?
  @State private var isLoadingProfile = false
  @State private var profileError: Error?
  @State private var profileLoadingTask: Task<Void, Never>?
  @State private var hasLoadedFromNetwork = false

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ResponsiveContentView {
        Form {
          Section {
            AccountHeaderView(
              isShowingAccountSwitcher: $isShowingAccountSwitcher,
              availableAccounts: availableAccounts,
              appState: appState,
              profile: profile,
              isLoadingProfile: isLoadingProfile,
              profileError: profileError,
              isAuthenticationError: isAuthenticationError
            )
          }

          Section("Your Account") {
            NavigationLink(destination: AccountSettingsView()) {
              Label("Account", systemImage: "person.fill")
            }
            NavigationLink(destination: PrivacySecuritySettingsView()) {
              Label("Privacy & Security", systemImage: "lock.fill")
            }
          }

          Section("Reading & Content") {
            NavigationLink(destination: ContentMediaSettingsView()) {
              Label("Content & Media", systemImage: "photo.on.rectangle.angled")
            }
            NavigationLink(destination: ModerationSettingsView()) {
              Label("Moderation", systemImage: "shield.fill")
            }
            NavigationLink(destination: FeedFilterSettingsView()) {
              LabeledContent {
                Text("\(appState.feedFilterSettings.filters.filter { $0.isEnabled }.count) active")
              } label: {
                Label("Feed Filters", systemImage: "line.3.horizontal.decrease.circle.fill")
              }
            }
          }

          Section("Display & Accessibility") {
            NavigationLink(destination: AppearanceSettingsView()) {
              Label("Appearance", systemImage: "paintbrush.fill")
            }
            NavigationLink(destination: AccessibilitySettingsView()) {
              Label("Accessibility", systemImage: "accessibility")
            }
          }

          Section("Notifications") {
            NavigationLink(destination: NotificationSettingsView()) {
              LabeledContent {
                Text(appState.notificationManager.notificationsEnabled ? "On" : "Off")
              } label: {
                Label("Notifications", systemImage: "bell.fill")
              }
            }
          }

          Section("Help & Support") {
            NavigationLink(destination: HelpSettingsView()) {
              Label("Help", systemImage: "questionmark.circle.fill")
            }
            Button {
              appState.onboardingManager.resetAllOnboarding()
            } label: {
              Label("Show Tips Again", systemImage: "lightbulb.fill")
            }
            NavigationLink(destination: AboutSettingsView()) {
              Label("About & Support", systemImage: "info.circle.fill")
            }
            NavigationLink(destination: OpenSourceLicensesView()) {
              Label("Open Source Licenses", systemImage: "doc.text")
            }
          }

          Section("Advanced") {
            NavigationLink(destination: AdvancedSettingsView()) {
              Label("Service Providers", systemImage: "gearshape.2.fill")
            }
            #if DEBUG
              NavigationLink(destination: SystemLogView()) {
                Label("System Logs", systemImage: "doc.text.fill")
              }
              VersionRow()
            #endif
          }

          Section {
            LogoutButton(isLoggingOut: $isLoggingOut, handleLogout: handleLogout)
          }
        }
      }
      .navigationTitle("Settings")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button {
              dismiss()
            } label: {
              Image(systemName: "xmark")

            }
          }
        }
        .sheet(isPresented: $isShowingAccountSwitcher) {
          AccountSwitcherView()
            .environment(AppStateManager.shared)
        }
        .alert(isPresented: .constant(error != nil)) {
          Alert(
            title: Text("Error"),
            message: Text(error?.localizedDescription ?? "Unknown error"),
            dismissButton: .default(Text("OK")) {
              error = nil
            }
          )
        }
        .onAppear {
          Task {
            await updateAvailableAccountsCount()
          }
          loadOrRefreshProfile()
        }
        .onChange(of: appState.userDID) { _, _ in
          loadOrRefreshProfile()
        }
        .id(appState.userDID)
    }
  }

  // MARK: - Profile Loading

  private func loadOrRefreshProfile() {
    profileLoadingTask?.cancel()

    let userDID = appState.userDID

    // Show cached data immediately if we haven't loaded from network yet
    if profile == nil || profile?.did.description != userDID {
      if let cached = AppStateManager.shared.authentication.getCachedProfileData(for: userDID) {
        // Build a lightweight profile from cache for instant display
        // The network fetch below will replace this with full data
        isLoadingProfile = true
        hasLoadedFromNetwork = false
      } else {
        isLoadingProfile = true
      }
    }

    profileLoadingTask = Task {
      do {
        guard let client = AppStateManager.shared.authentication.client else {
          throw AuthError.clientNotInitialized
        }

        let params = try AppBskyActorGetProfile.Parameters(actor: ATIdentifier(string: userDID))
        let (_, fetchedProfile) = try await client.app.bsky.actor.getProfile(input: params)
        try Task.checkCancellation()

        await MainActor.run {
          profile = fetchedProfile
          isLoadingProfile = false
          profileError = nil
          hasLoadedFromNetwork = true

          // Update the cache for future use
          if let fetchedProfile {
            AppStateManager.shared.authentication.cacheProfileData(
              for: userDID,
              handle: fetchedProfile.handle.description,
              displayName: fetchedProfile.displayName,
              avatarURL: fetchedProfile.finalAvatarURL()
            )
          }
        }
      } catch is CancellationError {
        // Normal cancellation - do nothing
      } catch {
        await MainActor.run {
          profileError = error
          isLoadingProfile = false
        }
      }
    }
  }

  // MARK: - Account Management

  private func updateAvailableAccountsCount() async {
    await MainActor.run {
      availableAccounts = AppStateManager.shared.authentication.availableAccounts.count
    }
  }

  // MARK: - Authentication Helpers

  private func isAuthenticationError(_ error: Error) -> Bool {
    let (_, _, requiresReAuth) = AuthenticationErrorHandler.categorizeError(error)
    return requiresReAuth
  }

  // MARK: - Logout

  private func handleLogout() async {
    await MainActor.run {
      isLoggingOut = true
    }

    // Use AppStateManager.logout() to ensure lifecycle transitions to .unauthenticated
    // This will also call AuthManager.logout() internally which handles the gateway logout
    await AppStateManager.shared.logout()

    await MainActor.run {
      isLoggingOut = false
      // Dismiss the settings sheet - the app will show LoginView due to lifecycle change
      dismiss()
    }
  }
}

// MARK: - Component Views

struct AccountHeaderView: View {
  @Binding var isShowingAccountSwitcher: Bool
  let availableAccounts: Int
  let appState: AppState

  // Profile-related properties
  let profile: AppBskyActorDefs.ProfileViewDetailed?
  let isLoadingProfile: Bool
  let profileError: Error?

  // Auth handling closures
  let isAuthenticationError: (Error) -> Bool

  var body: some View {
    // Keep it native: simple list-style row without custom chrome
    if case .authenticated = appState.authState {
      Button {
        isShowingAccountSwitcher = true
      } label: {
        VStack(alignment: .leading, spacing: 4) {
          AccountSwitchButton(
            availableAccounts: availableAccounts,
            profile: profile,
            isLoadingProfile: isLoadingProfile
          )

          if let error = profileError {
            if isAuthenticationError(error) {
              Text("Session expired. Tap to sign in.")
                .appCaption()
                .foregroundStyle(.red)
            } else {
              Text("Unable to load profile.")
                .appCaption()
                .foregroundStyle(.secondary)
            }
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .id(appState.userDID)
    } else {
      // Show nothing when not authenticated - user will see LoginView instead
      EmptyView()
    }
  }
}

struct AccountSwitchButton: View {
  let availableAccounts: Int

  // Profile-related properties
  let profile: AppBskyActorDefs.ProfileViewDetailed?
  let isLoadingProfile: Bool

  var body: some View {
    HStack(spacing: 12) {
      // Avatar image
      ProfileAvatarView(
        url: profile?.finalAvatarURL(),
        fallbackText: profile?.handle.description.prefix(1).uppercased() ?? "?",
        size: 44
      )

      VStack(alignment: .leading, spacing: 4) {
        Group {
          if isLoadingProfile {
            Text("Loading...")
              .appHeadline()
              .foregroundStyle(.secondary)
          } else if let displayName = profile?.displayName {
            Text(displayName)
              .appHeadline()
              .foregroundStyle(.primary)
              .lineLimit(1)
          } else if let handle = profile?.handle.description {
            Text("@\(handle)")
              .appHeadline()
              .foregroundStyle(.primary)
              .lineLimit(1)
          } else {
            Text("Unknown profile")
              .appBody()
              .fontWeight(.medium)
          }
        }

        if let handle = profile?.handle.description {
          Text("@\(handle)")
            .appSubheadline()
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        if availableAccounts > 1 {
          Text("\(availableAccounts) accounts available")
            .appCaption()
            .foregroundStyle(.secondary)
        }
      }

      Spacer()

      Image(systemName: "chevron.right")
        .foregroundColor(.gray)
        .appFont(AppTextRole.footnote)
    }
    // Use the default list row metrics for a more native feel
  }
}

struct LogoutButton: View {
  @Binding var isLoggingOut: Bool
  let handleLogout: () async -> Void

  var body: some View {
    Button(role: .destructive) {
      Task {
        await handleLogout()
      }
    } label: {
      if isLoggingOut {
        HStack {
          Text("Signing out...")
          Spacer()
          ProgressView()
        }
      } else {
        Text("Sign Out")
      }
    }
    .disabled(isLoggingOut)
  }
}

struct VersionRow: View {
  var body: some View {
    HStack {
      Text("Version")
        .foregroundStyle(.secondary)
      Spacer()
      Text(Bundle.main.appVersionString)
    }
  }
}

// MARK: - Bundle Extension

extension Bundle {
  var appVersionString: String {
    let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
    return "\(version) (\(build))"
  }
}

// MARK: - Previews

#Preview {
  AsyncPreviewContent { appState in
    SettingsView()
  }
}
