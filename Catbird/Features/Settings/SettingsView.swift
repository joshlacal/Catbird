import NukeUI
import SwiftUI
import Petrel

struct SettingsView: View {
  @Environment(AppState.self) private var appState
  @State private var isLoggingOut = false
  @State private var error: Error?
  @State private var isShowingAccountSwitcher = false
  @State private var availableAccounts: Int = 0
  
  // New states for profile management
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
        }

        PreferencesSection(appState: appState)

        Section {
          LogoutButton(isLoggingOut: $isLoggingOut, handleLogout: handleLogout)
        }

        Section {
          VersionRow()
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
    }
  }
  
  // New function to load the user profile
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
      
      // Now use the did variable to fetch the profile
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
      .padding(.horizontal, 8)
      .padding(.bottom, 8)
      .id(appState.currentUserDID)
    }
    .background(Color(.systemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 10))
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
        // Use our new ProfileAvatarView
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
      .background(Color(.secondarySystemBackground))
      .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    .buttonStyle(PlainButtonStyle())
  }
}
// Keep the rest of your components unchanged
struct PreferencesSection: View {
  let appState: AppState

  var body: some View {
    Section("Preferences") {
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
          Text("Mute Words")
        } icon: {
          Image(systemName: "speaker.slash.fill")
            .foregroundStyle(.orange)
        }
      }
    }
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
