import SwiftUI
import Petrel

struct SettingsAvatarToolbarButton: View {
  @Environment(AppState.self) private var appState
  let action: () -> Void

  var body: some View {
    Button(action: action) {
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
    .buttonStyle(.plain)
    .accessibilityLabel("Profile and settings")
    .accessibilityHint("Opens your profile and app settings")
    .accessibilityAddTraits(.isButton)
  }
}
