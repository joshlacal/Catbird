import SwiftUI
import Petrel

struct SettingsAvatarToolbarButton: View {
  @Environment(AppState.self) private var appState
  @Environment(AppStateManager.self) private var appStateManager
  @MainActor private static var lastKnownAccountDIDs: Set<String> = []
  @MainActor private static var lastProfileRefreshTime: Date?
  private static let refreshThrottleInterval: TimeInterval = 600 // 10 minutes
  @State private var avatarImages: [String: PlatformImage] = [:]

  let action: () -> Void

  var body: some View {
    let accounts = appStateManager.authentication.availableAccounts

    if accounts.count > 1 {
      Menu {
        Section("Accounts") {
          ForEach(accounts) { account in
            Button {
              guard !account.isActive else { return }
              let manager = appStateManager
              Task { @MainActor in
                let outcome = await manager.switchAccount(to: account.did)
                manager.presentAccountSwitchOutcome(outcome)
              }
            } label: {
              let labels = AccountMenuLabels(account: account)
              Label {
                Text(labels.title)
                  .appBody()
                  .foregroundStyle(.primary)
                  .lineLimit(1)
              } icon: {
                accountMenuIcon(for: account)
              }
              if let handle = labels.subtitle {
                Text(handle)
                  .appCaption()
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
            }
            .disabled(account.isActive)
            .accessibilityIdentifier("account.switch.\(account.did)")
          }
        }
      } label: {
        avatarLabel
      } primaryAction: {
        action()
      }
      .accessibilityLabel("Settings")
      .accessibilityHint("Opens Settings. Touch and hold to switch accounts.")
      .task(id: accountsTaskID(accounts)) {
        await refreshAccountProfiles(for: accounts)
        await loadAvatars(for: appStateManager.authentication.availableAccounts)
      }
    } else {
      Button(action: action) {
        avatarLabel
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Settings")
      .accessibilityHint("Opens Settings and account options")
      .accessibilityAddTraits(.isButton)
    }
  }

  private var avatarLabel: some View {
    // Only trust a loaded profile that belongs to the account being shown.
    let profile = appState.currentUserProfile.flatMap {
      $0.did.description == appState.userDID ? $0 : nil
    }
    let avatarURL = profile?.finalAvatarURL()
      ?? appStateManager.authentication.availableAccounts
        .first(where: { $0.did == appState.userDID })?.cachedAvatarURL

    return AvatarView(
      did: appState.userDID,
      client: appState.atProtoClient,
      size: 30,
      avatarURL: avatarURL
    )
    .scaledToFit()
    .frame(width: 30, height: 30)
    .clipShape(Circle())
    .id("\(appState.userDID)-\(avatarURL?.absoluteString ?? "noavatar")")
  }
  @ViewBuilder
  private func accountMenuIcon(for account: AuthenticationManager.AccountInfo) -> some View {
    if let image = avatarImages[account.did] {
      #if os(iOS)
        Image(uiImage: image)
          .resizable()
      #elseif os(macOS)
        Image(nsImage: image)
          .resizable()
      #endif
    } else if account.isActive {
      Image(systemName: "checkmark.circle.fill")
    } else {
      Image(systemName: "person.circle")
    }
  }


  /// Re-runs when the saved accounts or the active account change.
  private func accountsTaskID(_ accounts: [AuthenticationManager.AccountInfo]) -> [String] {
    accounts.map(\.did) + [appState.userDID]
  }

  /// Refreshes saved accounts' names and avatars so the menu never falls back to an identifier.
  /// Throttled to avoid network requests and UserDefaults churn on every tab switch or toolbar appearance,
  /// but refreshes immediately whenever the account list changes or an account lacks cached profile data.
  @MainActor
  private func refreshAccountProfiles(for accounts: [AuthenticationManager.AccountInfo]) async {
    let currentDIDs = Set(accounts.map(\.did))
    let accountListChanged = currentDIDs != Self.lastKnownAccountDIDs
    let anyMissingProfile = accounts.contains { $0.cachedAvatarURL == nil || $0.cachedDisplayName == nil }
    let now = Date()
    if !accountListChanged && !anyMissingProfile,
       let last = Self.lastProfileRefreshTime,
       now.timeIntervalSince(last) < Self.refreshThrottleInterval {
      return
    }
    guard let client = appState.atProtoClient else { return }
    Self.lastKnownAccountDIDs = currentDIDs
    Self.lastProfileRefreshTime = now
    await appStateManager.authentication.refreshCachedAccountProfiles(using: client)
  }

  @MainActor
  private func loadAvatars(for accounts: [AuthenticationManager.AccountInfo]) async {
    for account in accounts {
      guard avatarImages[account.did] == nil else { continue }
      let image = await AvatarImageLoader.shared.loadAvatar(
        did: account.did,
        client: appState.atProtoClient,
        avatarURL: account.cachedAvatarURL,
        size: 30
      )
      if let image {
        avatarImages[account.did] = image
      }
    }
  }
}

// MARK: - Account Menu Labels

/// Text for an account in the quick-switch menu. Never shows a DID: display name,
/// then handle, then "Loading…" until the account's profile arrives.
struct AccountMenuLabels: Equatable {
  let title: String
  let subtitle: String?

  init(account: AuthenticationManager.AccountInfo) {
    self.init(
      displayName: account.cachedDisplayName,
      handle: AuthenticationManager.AccountInfo.loginHandleCandidate(account.cachedHandle)
        ?? AuthenticationManager.AccountInfo.loginHandleCandidate(account.handle)
    )
  }

  init(displayName: String?, handle: String?) {
    let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let validHandle = AuthenticationManager.AccountInfo.loginHandleCandidate(handle)
    let validName = (name?.isEmpty == false && name?.lowercased().hasPrefix("did:") == false) ? name : nil
    if let validName {
      title = validName
      subtitle = validHandle.map { "@\($0)" }
    } else if let validHandle {
      title = "@\(validHandle)"
      subtitle = nil
    } else {
      title = "Loading…"
      subtitle = nil
    }
  }
}
