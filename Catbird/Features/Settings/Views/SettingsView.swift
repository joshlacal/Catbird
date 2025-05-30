import NukeUI
import SwiftUI
import Petrel

struct SettingsView: View {
  @Environment(AppState.self) private var appState
  @State private var isLoggingOut = false
  @State private var error: Error?
  @State private var isShowingAccountSwitcher = false
  @State private var availableAccounts: Int = 0
  
  // Profile management
  @State private var profile: AppBskyActorDefs.ProfileViewDetailed?
  @State private var isLoadingProfile = false
  @State private var profileError: Error?

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          AccountHeaderView(
            isShowingAccountSwitcher: $isShowingAccountSwitcher,
            availableAccounts: availableAccounts,
            appState: appState,
            profile: profile,
            isLoadingProfile: isLoadingProfile,
            profileError: profileError
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

            NavigationLink(destination: LanguageSettingsView()) {
                Label {
                    Text("Languages")
                } icon: {
                    Image(systemName: "globe")
                        .foregroundStyle(.teal)
                }
            }
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

            #if DEBUG
            NavigationLink {
                WidgetDebugView()
            } label: {
                Label {
                    Text("Widget Debugger")
                } icon: {
                    Image(systemName: "hammer.fill")
                        .foregroundStyle(.gray)
                }
            }
            
            NavigationLink {
                ThemeTestView()
            } label: {
                Label {
                    Text("Theme Test")
                } icon: {
                    Image(systemName: "paintbrush.pointed.fill")
                        .foregroundStyle(.purple)
                }
            }
            
            NavigationLink {
                ColorDemoView()
            } label: {
                Label {
                    Text("Color Demo")
                } icon: {
                    Image(systemName: "eyedropper.halffull")
                        .foregroundStyle(.cyan)
                }
            }
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
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
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
          await loadUserProfile()
        }
      }
      .task {
        await updateAccountCount()
      }
      .refreshable {
        if appState.isAuthenticated {
          await loadUserProfile()
        }
        await updateAccountCount()
      }
    }
  }
  
  // Load the user profile from the AT Protocol
  private func loadUserProfile() async {
    guard let client = appState.atProtoClient else { return }
    
    isLoadingProfile = true
    profileError = nil
    
    do {
      // Get the DID first, before using it
      let did: String
      if let currentUserDID = appState.currentUserDID {
        did = currentUserDID
      } else {
        did = try await client.getDid()
      }
      
      // Use the did variable to fetch the profile
      let (responseCode, profileData) = try await client.app.bsky.actor.getProfile(
        input: .init(actor: ATIdentifier(string: did))
      )
      
      if responseCode == 200, let profileData = profileData {
        profile = profileData
      } else {
        profileError = NSError(domain: "ProfileError", code: responseCode, userInfo: [
          NSLocalizedDescriptionKey: "Failed to load profile with code \(responseCode)"
        ])
      }
    } catch {
      profileError = error
    }
    
    isLoadingProfile = false
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

  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Text("Signed in as")
          .font(.headline)
        Spacer()

        Group {
          if isLoadingProfile {
            ProgressView()
          } else if let handle = profile?.handle.description {
            Text("@\(handle)")
              .fontWeight(.medium)
          } else if let error = profileError {
            Text("Error: \(error.localizedDescription)")
              .foregroundStyle(.red)
          } else {
            Text("Unknown")
              .fontWeight(.medium)
          }
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
      .background(Color(.secondarySystemBackground))
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .id(appState.currentUserDID)
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
                .font(.headline)
                .foregroundStyle(.secondary)
            } else if let displayName = profile?.displayName {
              Text(displayName)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            } else if let handle = profile?.handle.description {
              Text("@\(handle)")
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            } else {
              Text("Unknown profile")
                .font(.body)
                .fontWeight(.medium)
            }
          }

          if let handle = profile?.handle.description {
            Text("@\(handle)")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          
          if availableAccounts > 1 {
            Text("\(availableAccounts) accounts available")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Spacer()

        Image(systemName: "chevron.right")
          .foregroundColor(.gray)
          .font(.footnote)
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
    .environment(AppState())
}
