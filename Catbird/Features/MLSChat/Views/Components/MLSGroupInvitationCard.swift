import CatbirdMLSCore
import SwiftUI

/// Literal authenticated invitation reference. Opening it only navigates; the
/// existing group policy UI owns any separate acceptance operation.
struct MLSGroupInvitationCard: View {
  @Environment(AppState.self) private var appState
  let reference: MLSGroupInvitationReference

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Group invitation", systemImage: "person.2.fill").font(.headline)
      Text("This invitation is separate from the message conversation. Opening it does not join the group.")
        .font(.caption).foregroundStyle(.secondary)
      if appState.userDID == reference.recipientDid || appState.userDID == reference.invitedByDid {
        Button("View group invitation") {
          appState.navigationManager.targetMLSConversationId = reference.conversationId
        }
      }
    }
    .padding()
    .background(.quaternary, in: .rect(cornerRadius: 12))
    .accessibilityIdentifier("encrypted-group-invitation")
  }
}
