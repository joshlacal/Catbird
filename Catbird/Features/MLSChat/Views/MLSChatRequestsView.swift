import OSLog
import Petrel
import SwiftUI
import CatbirdMLSCore

struct MLSChatRequestsButton: View {
  let pendingCount: Int
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        Image(systemName: "tray")
          .appBody()

        if pendingCount > 0 {
          Text("\(pendingCount)")
            .appCaption()
            .fontWeight(.bold)
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.red)
            .clipShape(Capsule())
            .offset(x: 12, y: -8)
        }
      }
    }
    .accessibilityLabel(accessibilityLabel)
  }

  private var accessibilityLabel: String {
    if pendingCount == 0 {
      return "Chat requests"
    }
    return "Chat requests, \(pendingCount) pending"
  }
}

@MainActor
enum MLSChatRequestAcceptance {
  static func perform(
    conversationID: String,
    isCurrent: () -> Bool,
    accept: (String) async throws -> Void,
    didAccept: (String) async -> Void
  ) async throws {
    guard isCurrent() else { throw CancellationError() }
    try await accept(conversationID)
    guard isCurrent() else { throw CancellationError() }
    await didAccept(conversationID)
  }
}


enum MLSChatRequestPresentation {
  static func groupTitle(_ title: String?) -> String {
    let knownTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return knownTitle.isEmpty ? "Group chat invitation" : knownTitle
  }
}
