import SwiftUI
import Petrel

struct SettingsAvatarToolbarButton: View {
  @Environment(AppState.self) private var appState
  @Environment(AppStateManager.self) private var appStateManager
  @MainActor private static var lastKnownAccountDIDs: Set<String> = []
  @MainActor private static var lastProfileRefreshTime: Date?
  private static let refreshThrottleInterval: TimeInterval = 600 // 10 minutes
  private static let menuAvatarSize: CGFloat = 30
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
    if let image = avatarImages[account.did]
      ?? AvatarImageLoader.shared.cachedAvatar(
        did: account.did, avatarURL: account.cachedAvatarURL, size: Self.menuAvatarSize)
    {
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

  /// Loads every missing avatar concurrently and publishes them in one state update.
  /// Updating per image rebuilds the open menu each time, which scrolls it back to the top.
  @MainActor
  private func loadAvatars(for accounts: [AuthenticationManager.AccountInfo]) async {
    let missing = accounts.filter { avatarImages[$0.did] == nil }
    guard !missing.isEmpty else { return }
    let client = appState.atProtoClient
    let size = Self.menuAvatarSize
    let loaded = await withTaskGroup(of: (String, PlatformImage?).self) { group in
      for account in missing {
        let did = account.did
        let avatarURL = account.cachedAvatarURL
        group.addTask {
          let image = await AvatarImageLoader.shared.loadAvatar(
            did: did,
            client: client,
            avatarURL: avatarURL,
            size: size
          )
          return (did, image)
        }
      }
      var results: [String: PlatformImage] = [:]
      for await (did, image) in group {
        if let image { results[did] = image }
      }
      return results
    }
    guard !Task.isCancelled, !loaded.isEmpty else { return }
    avatarImages.merge(loaded) { current, _ in current }
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
      title = String(localized: "Loading…", comment: "Placeholder in account switcher menu while account profile is loading.")
      subtitle = nil
    }
  }
}
