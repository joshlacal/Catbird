import Foundation
import Petrel
import Testing
@testable import Catbird

@MainActor
struct ChatHistoryDiagnosticsTests {
  @Test("A successful exhausted page has no further history cursor")
  func exhaustedCursorDoesNotOfferMoreMessages() async {
    let client = await ATProtoClient(baseURL: URL(string: "https://chat-history.invalid")!)
    let manager = ChatManager(client: client, messagePageLoader: { _, _ in
      (200, .init(messages: []))
    })

    await manager.loadMessages(convoId: "exhausted", refresh: true)

    #expect(manager.messageLoadStates["exhausted"] == .loaded)
    #expect(!manager.hasMoreMessages(for: "exhausted"))
    #expect(!manager.hasMoreMessages(for: "never-loaded"))
  }

  @Test("A real cursor is used for the next page and nil exhausts it")
  func nextPageUsesCursorThenExhausts() async {
    let client = await ATProtoClient(baseURL: URL(string: "https://chat-history.invalid")!)
    var requestedCursors: [String?] = []
    let manager = ChatManager(client: client, messagePageLoader: { _, parameters in
      requestedCursors.append(parameters.cursor)
      let cursor: String? = requestedCursors.count == 1 ? "opaque-private-cursor" : nil
      return (200, .init(cursor: cursor, messages: []))
    })

    await manager.loadMessages(convoId: "paginated", refresh: true)
    #expect(manager.hasMoreMessages(for: "paginated"))
    await manager.loadMessages(convoId: "paginated", refresh: false)

    #expect(requestedCursors == [nil, "opaque-private-cursor"])
    #expect(!manager.hasMoreMessages(for: "paginated"))
  }

  @Test("Diagnostic output has only the approved operational fields")
  func diagnosticPrivacyShape() throws {
    let requestID = UUID()
    let relatedID = UUID()
    var event = ChatHistoryLoadDiagnostic(
      requestID: requestID, relatedRequestID: relatedID,
      phase: .finished, outcome: .decodedPopulated, httpStatus: 200,
      refresh: true, inputCursorPresent: false, outputCursorPresent: true,
      receivedCount: 4, userCount: 1, systemCount: 1, deletedCount: 1, unknownCount: 1,
      cachedBefore: 0, cachedAfter: 2, elapsedMilliseconds: 15
    )
    let line = try #require(event.logLine)
    let data = try #require(line.data(using: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == Set([
      "requestID", "relatedRequestID", "phase", "outcome", "httpStatus", "refresh",
      "inputCursorPresent", "outputCursorPresent", "receivedCount", "userCount",
      "systemCount", "deletedCount", "unknownCount", "cachedBefore", "cachedAfter",
      "elapsedMilliseconds"
    ]))
    let textFields = object.compactMapValues { $0 as? String }
    #expect(textFields == [
      "requestID": requestID.uuidString, "relatedRequestID": relatedID.uuidString,
      "phase": "finished", "outcome": "decodedPopulated"
    ])

    // The encoding distinguishes a decoded empty page from a decoder failure without a body.
    event.outcome = .decodedEmpty
    event.receivedCount = 0
    #expect(try #require(event.logLine).contains("decodedEmpty"))
    event.outcome = .decodeFailed
    event.receivedCount = nil
    let failedLine = try #require(event.logLine)
    #expect(failedLine.contains("decodeFailed"))
    #expect(!failedLine.contains("receivedCount"))
    #expect(!line.contains("opaque-private-cursor"))
  }
}
