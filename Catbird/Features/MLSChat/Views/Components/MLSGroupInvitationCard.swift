import CatbirdMLSCore
import SwiftUI

/// Literal authenticated invitation reference. Opening it only navigates; the
/// existing group policy UI owns any separate acceptance operation.
struct MLSGroupInvitationCard: View {
  @Environment(AppState.self) private var appState
  @Environment(SceneNavigationContext.self) private var sceneContext
  @Environment(\.colorScheme) private var colorScheme
  let reference: MLSGroupInvitationReference

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Group invitation", systemImage: "person.2.fill").appFont(AppTextRole.headline)
      Text("This invitation is separate from the message conversation. Opening it does not join the group.")
        .appFont(AppTextRole.caption).foregroundStyle(.secondary)
      if appState.userDID == reference.recipientDid || appState.userDID == reference.invitedByDid {
        Button("View group invitation") {
          appState.navigateToMLSConversation(reference.conversationId, preferredSceneID: sceneContext.sceneID)
        }
        .buttonStyle(.catbird(.tonal, size: .sm))
      }
    }
    .padding(Space.lg)
    .embedCardStyle(colorScheme: colorScheme)
    .accessibilityIdentifier("encrypted-group-invitation")
  }
}
