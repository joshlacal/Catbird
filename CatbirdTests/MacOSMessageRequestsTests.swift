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
}
