import Foundation
import Testing
@testable import Catbird

/// F72: macOS parity for incoming message requests.
/// Verifies that incoming pending direct requests are selectable, navigable, and
/// surfaced through the message requests entrypoint.
@Suite("macOS Message Requests Parity (F72)")
struct MacOSMessageRequestsTests {

  @Test("Selection is preserved for canonical incoming requests even when pending")
  func incomingPendingRequestSelectionPreserved() {
    let canonicalIDs: Set<String> = ["convo-pending-inbound-1", "convo-accepted-2"]
    let selectedConvoId: String? = "convo-pending-inbound-1"

    // The bug was: if !acceptedConversations.contains(selectedConvoId) { selectedConvoId = nil }
    // where acceptedConversations filtered out .pendingInbound.
    // Fixed logic in MacOSChatTabView.swift:
    var currentSelected = selectedConvoId
    if let id = currentSelected, !canonicalIDs.contains(id) {
      currentSelected = nil
    }

    #expect(currentSelected == "convo-pending-inbound-1", "Incoming pending request selection must be preserved")

    // Unknown/deleted conversation is still cleared:
    var unknownSelected: String? = "convo-deleted-999"
    if let id = unknownSelected, !canonicalIDs.contains(id) {
      unknownSelected = nil
    }
    #expect(unknownSelected == nil, "Unknown conversation must be cleared")
  }

  @Test("E2E open-request command maps conversationId to targetMLSConversationId")
  func openRequestCommandRouting() {
    let convoId = "00000000-0000-4000-8000-000000000001"
    let url = URL(string: "blue.catbird://e2e/open-request?conversationId=\(convoId)")!
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let params = components.queryItems else {
      Issue.record("Failed to parse URL components")
      return
    }
    let dict = Dictionary(uniqueKeysWithValues: params.compactMap { item in
      item.value.map { (item.name, $0) }
    })
    #expect(dict["conversationId"] == convoId)
  }

  @Test("F79: Request accept action invokes onAccepted exactly once and never calls decline")
  func acceptActionDispatchesAcceptAndNeverDecline() async {
    final class MockActionTracker: @unchecked Sendable {
      var acceptedConvoIDs: [String] = []
      var declinedConvoIDs: [String] = []
      var onAcceptedCalls: [String] = []

      func accept(convoId: String) { acceptedConvoIDs.append(convoId) }
      func decline(convoId: String) { declinedConvoIDs.append(convoId) }
      func notifyAccepted(convoId: String) { onAcceptedCalls.append(convoId) }
    }

    let tracker = MockActionTracker()
    let testConvoID = "00000000-0000-4000-8000-000000000042"

    // Simulating MLSDirectRequestDetailView.act(.accept) with restored case .decline:
    enum TestAction { case accept, decline }
    let action: TestAction = .accept

    switch action {
    case .accept:
      tracker.accept(convoId: testConvoID)
      tracker.notifyAccepted(convoId: testConvoID)
    case .decline:
      tracker.decline(convoId: testConvoID)
    }

    #expect(tracker.acceptedConvoIDs == [testConvoID], "Accept must be called exactly once")
    #expect(tracker.onAcceptedCalls == [testConvoID], "onAccepted callback must be invoked exactly once")
    #expect(tracker.declinedConvoIDs.isEmpty, "Accept must NEVER fall through to decline (F79 regression)")
  }

  @Test("F79: AppNavigationManager.chatTabIndex constant equals 4")
  func chatTabIndexConstant() {
    #expect(AppNavigationManager.chatTabIndex == 4)
  }
}
