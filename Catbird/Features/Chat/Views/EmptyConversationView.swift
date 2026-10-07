import SwiftUI

// MARK: - Empty Conversation View

struct EmptyConversationView: View {
  @Environment(AppState.self) private var appState
  
  var body: some View {
    ContentUnavailableView(
      "No Conversation Selected",
      systemImage: "bubble.left.and.bubble.right",
      description: Text("Choose a conversation from the list to start messaging.")
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
  }
}

#Preview("EmptyConversationView") {
  EmptyConversationView()
    .previewWithAuthenticatedState()
}
