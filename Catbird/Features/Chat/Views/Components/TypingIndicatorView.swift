import SwiftUI
import Petrel

struct TypingIndicatorView: View {
  let convoId: String
  @Environment(AppState.self) private var appState
  @State private var animationPhase: Double = 0
  
  private var typingUsers: Set<String> {
    Task {
      return await appState.chatManager.getTypingUsers(for: convoId)
    }
    // Fallback to checking local state
    return appState.chatManager.typingIndicators[convoId] ?? Set<String>()
  }
  
  private var typingText: String {
    let userCount = typingUsers.count
    switch userCount {
    case 0:
      return ""
    case 1:
      return "Someone is typing..."
    case 2:
      return "2 people are typing..."
    default:
      return "\(userCount) people are typing..."
    }
  }
  
  var body: some View {
    if !typingUsers.isEmpty {
      HStack(spacing: 8) {
        HStack(spacing: 3) {
          ForEach(0..<3) { index in
            Circle()
              .fill(Color.gray.opacity(0.6))
              .frame(width: 6, height: 6)
              .scaleEffect(1 + 0.3 * sin(animationPhase + Double(index) * 0.5))
              .animation(
                .easeInOut(duration: 1.2)
                .repeatForever(autoreverses: false),
                value: animationPhase
              )
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.gray.opacity(0.15))
        )
        
        Text(typingText)
          .font(.caption)
          .foregroundColor(.secondary)
          .animation(.easeInOut(duration: 0.3), value: typingText)
        
        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 4)
      .transition(.move(edge: .bottom).combined(with: .opacity))
      .onAppear {
        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
          animationPhase = .pi * 2
        }
      }
    }
  }
}

struct TypingIndicatorView_Previews: PreviewProvider {
  static var previews: some View {
    TypingIndicatorView(convoId: "test-convo")
      .environment(AppState())
  }
}