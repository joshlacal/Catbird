import SwiftUI

// MARK: - Empty Conversation View

struct EmptyConversationView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme
  
  var body: some View {
    VStack(spacing: DesignTokens.Spacing.lg) {
      Image(systemName: "bubble.left.and.bubble.right")
        .font(.system(size: 80))
        .foregroundStyle(.tertiary)
        .symbolRenderingMode(.hierarchical)
      
      VStack(spacing: DesignTokens.Spacing.sm) {
        Text("Select a conversation")
          .appTitle()
        
        Text("Choose a conversation from the list to start messaging")
          .appBody()
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
  }
}