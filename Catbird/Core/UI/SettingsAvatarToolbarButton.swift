import SwiftUI
import Petrel

struct SettingsAvatarToolbarButton: View {
  @Environment(AppState.self) private var appState
  @Environment(AppStateManager.self) private var appStateManager
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
              Task {
                await appStateManager.switchAccount(to: account.did)
              }
            } label: {
              let displayName = account.cachedDisplayName ?? account.cachedHandle ?? account.handle ?? account.did
              let handle = account.cachedHandle ?? account.handle
//            Label {
//              Text(displayName)
//              if let handle, handle != displayName {
//                Text("@\(handle)")
//              }
//            } icon: {
//              if let image = avatarImages[account.did] {
//                #if os(iOS)
//                  Image(uiImage: image)
//                    .resizable()
//                #elseif os(macOS)
//                  Image(nsImage: image)
//                    .resizable()
//                #endif
//              } else if account.isActive {
//                Image(systemName: "checkmark.circle.fill")
//              } else {
//                Image(systemName: "person.circle")
//              }
//            }
              
              Label {
                Text(displayName)
                  .appBody()
                  .foregroundStyle(.primary)
                  .lineLimit(1)
              } icon: {
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
              if let handle, handle != displayName {
                Text("@\(handle)")
                  .appCaption()
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
            }
            .disabled(account.isActive)
          }
        }
      } label: {
        avatarLabel
      } primaryAction: {
        action()
      }
      .accessibilityLabel("Profile and settings")
      .accessibilityHint("Tap for settings, hold for account switcher")
      .task(id: accounts.map(\.did)) {
        await loadAvatars(for: accounts)
      }
    } else {
      Button(action: action) {
        avatarLabel
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Profile and settings")
      .accessibilityHint("Opens your profile and app settings")
      .accessibilityAddTraits(.isButton)
    }
  }

  private var avatarLabel: some View {
    let avatarURL = appState.currentUserProfile?.finalAvatarURL()

    return AvatarView(
      did: appState.userDID,
      client: appState.atProtoClient,
      size: 30,
      avatarURL: avatarURL
    )
    .scaledToFit()
    .frame(width: 30, height: 30)
    .clipShape(Circle())
    .id("\(appState.userDID)-\(appState.currentUserProfile?.avatar?.description ?? "noavatar")")
  }

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
