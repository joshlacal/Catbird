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

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ResponsiveContentView {
        List {
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

        // Main settings categories
        Section("Settings") {
            NavigationLink(destination: AccountSettingsView()) {
                Label {
                    Text("Account")
                } icon: {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.blue)
                }
            }

            NavigationLink(destination: PrivacySecuritySettingsView()) {
                Label {
                    Text("Privacy & Security")
                } icon: {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.green)
                }
            }

            NavigationLink(destination: ModerationSettingsView()) {
                Label {
                    Text("Moderation")
                } icon: {
                    Image(systemName: "shield.fill")
                        .foregroundStyle(.orange)
                }
            }

            NavigationLink(destination: ContentMediaSettingsView()) {
                Label {
                    Text("Content & Media")
                } icon: {
                    Image(systemName: "photo.on.rectangle.angled")
                        .foregroundStyle(.purple)
                }
            }
        }

        Section {
            NavigationLink(destination: AppearanceSettingsView()) {
                Label {
                    Text("Appearance")
                } icon: {
                    Image(systemName: "paintbrush.fill")
                        .foregroundStyle(.pink)
                }
            }

            NavigationLink(destination: AccessibilitySettingsView()) {
                Label {
                    Text("Accessibility")
                } icon: {
                    Image(systemName: "accessibility")
                        .foregroundStyle(.indigo)
                }
            }

            // NavigationLink(destination: LanguageSettingsView()) {
            //     Label {
            //         Text("Languages")
            //     } icon: {
            //         Image(systemName: "globe")
            //             .foregroundStyle(.teal)
            //     }
            // }
        }

        // Notifications and feeds section
        Section("App & Notifications") {
            NavigationLink {
                NotificationSettingsView()
            } label: {
                HStack {
                    Label {
                        Text("Notifications")
                    } icon: {
                        Image(systemName: "bell.fill")
                            .foregroundStyle(.blue)
                    }

                    if appState.notificationManager.notificationsEnabled {
                        Spacer()
                        Text("On")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            NavigationLink {
                FeedFilterSettingsView()
            } label: {
                HStack {
                    Label {
                        Text("Feed Filters")
                    } icon: {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .foregroundStyle(.indigo)
                    }

                    Spacer()
                    Text("\(appState.feedFilterSettings.activeFilterIds.count) active")
                        .foregroundStyle(.secondary)
                }
            }

            NavigationLink {
                MuteWordsSettingsView()
            } label: {
                Label {
                    Text("Muted Words")
                } icon: {
                    Image(systemName: "speaker.slash.fill")
                        .foregroundStyle(.orange)
                }
            }
            
            Button {
                appState.onboardingManager.resetAllOnboarding()
            } label: {
                Label {
                    Text("Show Tips Again")
                } icon: {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                }
            }

            #if DEBUG
            // NavigationLink {
            //     WidgetDebugView()
            // } label: {
            //     Label {
            //         Text("Widget Debugger")
            //     } icon: {
            //         Image(systemName: "hammer.fill")
            //             .foregroundStyle(.gray)
            //     }
            // }
            
            NavigationLink {
                SystemLogView()
            } label: {
                Label {
                    Text("System Logs")
                } icon: {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(.gray)
                }
            }
            #endif
        }

        Section("Support & Information") {
            NavigationLink(destination: HelpSettingsView()) {
                Label {
                    Text("Help")
                } icon: {
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundStyle(.blue)
                }
            }

            NavigationLink(destination: AboutSettingsView()) {
                Label {
                    Text("About")
                } icon: {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.gray)
                }
            }

            NavigationLink(destination: OpenSourceLicensesView()) {
                Label {
                    Text("Open Source Licenses")
                } icon: {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.purple)
                }
            }
        }

        Section("Advanced") {
          NavigationLink(destination: AdvancedSettingsView()) {
            Label {
              Text("Advanced")
            } icon: {
              Image(systemName: "gearshape.2.fill")
                  .foregroundStyle(.gray)
            }
          }

          NavigationLink(destination: DiagnosticsSettingsView()) {
            Label {
              Text("Diagnostics")
            } icon: {
              Image(systemName: "stethoscope")
                .foregroundStyle(.gray)
            }
          }

          if #available(iOS 18.0, macOS 13.0, *) {
            NavigationLink(destination: DeviceManagementView()) {
              Label {
                Text("Devices")
              } icon: {
                Image(systemName: "iphone.and.ipad")
                    .foregroundStyle(.blue)
              }
            }
          }

          #if DEBUG
          VersionRow()
          #endif
        }
        
        Section("Experimental") {
          Toggle(isOn: Binding(
            get: { 
              return ExperimentalSettings.shared.isMLSChatEnabled(for: appState.userDID)
            },
            set: { newValue in
              if newValue {
                // CRITICAL FIX: Initialize MLS (device registration + key packages) and call optIn
                // This ensures other users can find and add this user to conversations
                Task {
                  await optInToMLS()
                }
              } else {
                ExperimentalSettings.shared.disableMLSChat(for: appState.userDID)
                // Opt out from MLS server
                Task {
                  await optOutFromMLS()
                }
              }
            }
          )) {
            Label {
              VStack(alignment: .leading, spacing: 2) {
                Text("Catbird Groups")
                Text("E2E encrypted group chat")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            }
          }
          .tint(.orange)
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
            Text("Done")
          }
        }
      }
      .sheet(isPresented: $isShowingAccountSwitcher) {
        AccountSwitcherView()
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

    profileLoadingTask = Task {
       let userDID = appState.userDID 

      await MainActor.run {
        isLoadingProfile = true
        profileError = nil
      }

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
  
  // MARK: - MLS Opt-In/Out
  
  /// Opt in to MLS on the server and initialize device/key packages
  /// CRITICAL: Must initialize MLS before optIn to ensure key packages are uploaded
  private func optInToMLS() async {
    let userDID = appState.userDID
    
    do {
      // Initialize MLS first (device registration + key packages)
      try await appState.initializeMLS()
      
      // Then call optIn to mark user as available
      guard let apiClient = await appState.getMLSAPIClient() else {
        return
      }
      _ = try await apiClient.optIn()
      
      // Save local setting only after successful server opt-in
      ExperimentalSettings.shared.enableMLSChat(for: userDID)
    } catch {
      // Failed to opt in - don't save local setting
      // User will need to try again
    }
  }
  
  /// Opt out from MLS on the server when user disables the feature
  private func optOutFromMLS() async {
    guard let apiClient = await appState.getMLSAPIClient() else {
      return
    }
    
    do {
      _ = try await apiClient.optOut()
    } catch {
      // Silently fail - the local toggle is already off
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

    do {
      try await AppStateManager.shared.authentication.logout()
      await MainActor.run {
        isLoggingOut = false
        dismiss()
      }
    } catch {
      // If logout fails, still clear the error state and let the user try to re-authenticate
      await MainActor.run {
        profileError = nil
        isLoadingProfile = false
      }
      AppStateManager.shared.authentication.resetError()
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
    @Previewable @Environment(AppState.self) var appState

  SettingsView()
    .applyAppStateEnvironment(appState)
}
