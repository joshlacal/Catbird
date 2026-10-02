@testable import Catbird
import Foundation
import Testing

/// Regression coverage for `ChatManager.activeConversationId` lifecycle — the state
/// `NotificationManager.willPresent` reads to suppress foreground chat push banners for the
/// conversation currently on screen. See `ChatNotificationRoutingTests` for the payload-parsing
/// half of that suppression (`chatConversationID(fromUserInfo:)`).
struct ChatManagerActiveConversationTests {
  @Test("activeConversationId is set after startMessagePolling returns")
  func activeConversationIdSetAfterStart() {
    let chatManager = ChatManager()

    chatManager.startMessagePolling(for: "convo-x")

    #expect(chatManager.activeConversationId == "convo-x")

    chatManager.stopMessagePolling(for: "convo-x")
  }

  @Test("activeConversationId clears after stopMessagePolling for the same conversation")
  func activeConversationIdClearsOnStop() {
    let chatManager = ChatManager()

    chatManager.startMessagePolling(for: "convo-x")
    chatManager.stopMessagePolling(for: "convo-x")

    #expect(chatManager.activeConversationId == nil)
  }

  @Test("Rapid convo-to-convo switch leaves the newly-opened conversation active")
  func rapidSwitchLeavesNewConversationActive() {
    let chatManager = ChatManager()

    // New view's onAppear (start "B") fires before the old view's onDisappear
    // (stop "A") during a fast navigation transition.
    chatManager.startMessagePolling(for: "convo-a")
    chatManager.startMessagePolling(for: "convo-b")
    chatManager.stopMessagePolling(for: "convo-a")

    #expect(chatManager.activeConversationId == "convo-b")

    chatManager.stopMessagePolling(for: "convo-b")
  }
}
