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
            isAuthenticationError: isAuthenticationError,
            handleReAuthentication: handleReAuthentication
          )
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)
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
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(.green)
                }
            }
            
            // NavigationLink {
            //     ThemeTestView()
            // } label: {
            //     Label {
            //         Text("Theme Test")
            //     } icon: {
            //         Image(systemName: "paintbrush.pointed.fill")
            //             .foregroundStyle(.purple)
            //     }
            // }
            
            // NavigationLink {
            //     ColorDemoView()
            // } label: {
            //     Label {
            //         Text("Color Demo")
            //     } icon: {
            //         Image(systemName: "eyedropper.halffull")
            //             .foregroundStyle(.cyan)
            //     }
            // }
            #endif
        }

        Section {
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
                        .foregroundStyle(.blue)
                }
            }
        }
        

        Section {
            LogoutButton(isLoggingOut: $isLoggingOut, handleLogout: handleLogout)
        }
        }
      }
      .navigationTitle("Settings")
      .toolbarTitleDisplayMode(.inline)
      .appDisplayScale(appState: appState)
      .contrastAwareBackground(appState: appState, defaultColor: Color(.systemBackground))
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Done") {
            dismiss()
          }
        }
      }
      .alert("Error", isPresented: .constant(error != nil)) {
        Button("OK") {
          error = nil
        }
      } message: {
        if let error {
          Text(error.localizedDescription)
        }
      }
      .sheet(isPresented: $isShowingAccountSwitcher) {
        AccountSwitcherView()
      }
      .task {
        if appState.isAuthenticated {
          // Cancel any existing profile loading task
          profileLoadingTask?.cancel()
          profileLoadingTask = Task {
            await loadUserProfile()
          }
        }
      }
      .task {
        await updateAccountCount()
      }
      .refreshable {
        if appState.isAuthenticated {
          // Cancel any existing profile loading task before starting a new one
          profileLoadingTask?.cancel()
          profileLoadingTask = Task {
            await loadUserProfile()
          }
        }
        await updateAccountCount()
      }
    }
    .onDisappear {
      // Cancel any ongoing profile loading when the view disappears
      profileLoadingTask?.cancel()
    }
  }
  
  // Load the user profile from the AT Protocol
  private func loadUserProfile() async {
    // Check for task cancellation
    guard !Task.isCancelled else {
      return
    }
    
    // Check authentication state before attempting to load profile
    guard appState.isAuthenticated else {
      await MainActor.run {
        profileError = nil // Clear any existing errors since we're not authenticated
        isLoadingProfile = false
      }
      return
    }
    
    guard let client = appState.atProtoClient else { 
      await MainActor.run {
        profileError = nil // Clear errors if client is not available
        isLoadingProfile = false
      }
      return 
    }
    
    await MainActor.run {
      isLoadingProfile = true
      profileError = nil
    }
    
    do {
      // Check for task cancellation before making network calls
      guard !Task.isCancelled else {
        await MainActor.run {
          isLoadingProfile = false
        }
        return
      }
      
      // Get the DID first, before using it
      let did: String
      if let currentUserDID = appState.currentUserDID {
        did = currentUserDID
      } else {
        did = try await client.getDid()
      }
      
      // Check again for cancellation after potentially async getDid call
      guard !Task.isCancelled else {
        await MainActor.run {
          isLoadingProfile = false
        }
        return
      }
      
      // Use the did variable to fetch the profile
      let (responseCode, profileData) = try await client.app.bsky.actor.getProfile(
        input: .init(actor: ATIdentifier(string: did))
      )
      
      // Check for cancellation before updating UI
      guard !Task.isCancelled else {
        await MainActor.run {
          isLoadingProfile = false
        }
        return
      }
      
      await MainActor.run {
        if responseCode == 200, let profileData = profileData {
          profile = profileData
        } else {
          // Handle different response codes appropriately
          if responseCode == 401 {
            profileError = NSError(domain: "AuthenticationError", code: 401, userInfo: [
              NSLocalizedDescriptionKey: "Your session has expired. Please sign in again."
            ])
          } else if responseCode == 403 {
            profileError = NSError(domain: "AuthorizationError", code: 403, userInfo: [
              NSLocalizedDescriptionKey: "Access denied. You may not have permission to view this profile."
            ])
          } else if responseCode >= 500 {
            profileError = NSError(domain: "ServerError", code: responseCode, userInfo: [
              NSLocalizedDescriptionKey: "Server error. Please try again later."
            ])
          } else {
            profileError = NSError(domain: "ProfileError", code: responseCode, userInfo: [
              NSLocalizedDescriptionKey: "Unable to load profile. Please try again."
            ])
          }
        }
      }
    } catch {
      // Check for cancellation before handling errors
      guard !Task.isCancelled else {
        await MainActor.run {
          isLoadingProfile = false
        }
        return
      }
      
      await MainActor.run {
        // Use the error handler to provide user-friendly error messages
        let (errorType, userMessage, _) = AuthenticationErrorHandler.categorizeError(error)
        let domain = "ProfileError"
        let code = (error as NSError).code
        
        profileError = NSError(domain: domain, code: code, userInfo: [
          NSLocalizedDescriptionKey: userMessage
        ])
      }
    }
    
    await MainActor.run {
      isLoadingProfile = false
    }
  }

  private func handleLogout() async {
    isLoggingOut = true
    defer { isLoggingOut = false }

    do {
      try await appState.handleLogout()
      dismiss()
    } catch {
      self.error = error
    }
  }

  private func updateAccountCount() async {
    await appState.authManager.refreshAvailableAccounts()
    availableAccounts = appState.authManager.availableAccounts.count
  }
  
  // MARK: - Authentication Error Handling
  
  /// Checks if an error is an authentication-related error that requires re-authentication
  private func isAuthenticationError(_ error: Error) -> Bool {
    let errorDescription = error.localizedDescription.lowercased()
    return errorDescription.contains("401") || 
           errorDescription.contains("unauthorized") ||
           errorDescription.contains("authentication") ||
           errorDescription.contains("invalid session") ||
           errorDescription.contains("token")
  }
  
  /// Handles re-authentication when authentication errors occur
  private func handleReAuthentication() async {
    do {
      // Cancel any ongoing profile loading
      profileLoadingTask?.cancel()
      
      // Clear the current error state immediately for better UX
      await MainActor.run {
        profileError = nil
        isLoadingProfile = false
      }
      
      // Reset the auth manager error state
      appState.authManager.resetError()
      
      // Log out the current user to clear invalid session
      await appState.authManager.logout()
      
      // The app should automatically redirect to login view when auth state becomes unauthenticated
      
    } catch {
      // If logout fails, still clear the error state and let the user try to re-authenticate
      await MainActor.run {
        profileError = nil
        isLoadingProfile = false
      }
      appState.authManager.resetError()
    }
  }
}

// MARK: - Component Views

struct AccountHeaderView: View {
    @Environment(\.colorScheme) private var currentColorScheme
  @Binding var isShowingAccountSwitcher: Bool
  let availableAccounts: Int
  let appState: AppState
  
  // Profile-related properties
  let profile: AppBskyActorDefs.ProfileViewDetailed?
  let isLoadingProfile: Bool
  let profileError: Error?
  
  // Auth handling closures
  let isAuthenticationError: (Error) -> Bool
  let handleReAuthentication: () async -> Void

  var body: some View {
    // Don't show "Signed in as" at all if user is not authenticated
    if case .authenticated = appState.authState {
      VStack(spacing: 12) {
        HStack {
          Text("Signed in as")
            .appHeadline()
          Spacer()

          if isLoadingProfile {
            ProgressView()
          } else if let handle = profile?.handle.description {
            Text("@\(handle)")
              .fontWeight(.medium)
          } else if let error = profileError {
            // Check if this is an authentication error (401) 
            if isAuthenticationError(error) {
              Button("Sign In Again") {
                Task {
                  await handleReAuthentication()
                }
              }
              .foregroundStyle(.blue)
              .fontWeight(.medium)
            } else {
              Text("Unable to load profile")
                .foregroundStyle(.secondary)
                .fontWeight(.medium)
            }
          } else {
            Text("Unknown")
              .fontWeight(.medium)
          }
        }
      .padding(.horizontal)
      .padding(.top, 8)

      AccountSwitchButton(
        availableAccounts: availableAccounts,
        isShowingAccountSwitcher: $isShowingAccountSwitcher,
        appState: appState,
        profile: profile,
        isLoadingProfile: isLoadingProfile
      )
      .padding(.horizontal)
      .padding(.bottom, 8)
      .background(Color.dynamicSecondaryBackground(appState.themeManager, currentScheme: currentColorScheme))
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .id(appState.currentUserDID)
      }
    } else {
      // Show nothing when not authenticated - user will see LoginView instead
      EmptyView()
    }
  }
}

struct AccountSwitchButton: View {
  let availableAccounts: Int
  @Binding var isShowingAccountSwitcher: Bool
  let appState: AppState
  
  // Profile-related properties
  let profile: AppBskyActorDefs.ProfileViewDetailed?
  let isLoadingProfile: Bool

  var body: some View {
    Button {
      isShowingAccountSwitcher = true
    } label: {
      HStack(spacing: 12) {
        // Avatar image
        ProfileAvatarView(
          url: profile?.avatar?.url,
          fallbackText: profile?.handle.description.prefix(1).uppercased() ?? "?",
          size: 50
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
      .padding(12)
    }
    .buttonStyle(PlainButtonStyle())
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
  SettingsView()
    .environment(AppState.shared)
}
