import Foundation
import Testing
@testable import Catbird

struct CopilotToolResultTests {
  @Test func keepsShortResultIntact() async throws {
    let result = try await CopilotToolResult.bounded("Original source", tokenCount: { $0.utf8.count })
    #expect(result.text == "Original source")
    #expect(!result.wasTruncated)
  }

  @Test func boundsUnicodeResultAndDisclosesTruncation() async throws {
    let source = String(repeating: "A 猫 🐈\n", count: 300)
    let result = try await CopilotToolResult.bounded(source, tokenCount: { $0.utf8.count })
    #expect(result.wasTruncated)
    #expect(result.text.utf8.count <= CopilotToolResult.maximumTokens)
    #expect(result.text.hasPrefix("Partial tool result (truncated; omitted contents are unknown):"))
    #expect(!result.text.contains("�"))
  }

  @Test func cancellationDuringCountingDoesNotReturnEvidence() async {
    let task = Task {
      try await CopilotToolResult.bounded("Source", tokenCount: { _ in
        withUnsafeCurrentTask { $0?.cancel() }
        return 1
      })
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test func legacyContextAndNewEvidenceRoundTrip() throws {
    let legacy = Data(#"{"post":{"uri":"at://did:plc:a/app.bsky.feed.post/1","authorDID":"did:plc:a","text":"Post"}}"#.utf8)
    let context = try JSONDecoder().decode(CopilotContext.self, from: legacy)
    guard case .post(let uri, let cid, let author, let text, let evidence) = context else {
      Issue.record("Expected legacy post"); return
    }
    #expect(cid == nil)
    #expect(evidence == nil)
    let snapshot = CopilotPostEvidence(
      selectedPost: .init(uri: uri, cid: "cid1", authorDID: author, text: text),
      quotedPosts: [.init(uri: "at://did:plc:q/app.bsky.feed.post/2", text: "Quoted evidence")],
      coverage: ["Visible snapshot"]
    )
    let enriched = CopilotContext.post(uri: uri, cid: "cid1", authorDID: author, text: text, evidence: snapshot)
    let roundTrip = try JSONDecoder().decode(CopilotContext.self, from: JSONEncoder().encode(enriched))
    #expect(roundTrip == enriched)
    #expect(context.matchesHistoryContext(enriched))
    #expect(enriched.matchesHistoryContext(context))
  }

  @Test func evidenceHistoryRemainsAccountScopedAndClearable() async throws {
    let suite = "CopilotEvidenceHistoryTests.\(UUID().uuidString)"
    let store = CopilotHistoryStore(defaults: UserDefaults(suiteName: suite)!)
    let a = "did:plc:a"
    let b = "did:plc:b"
    let evidence = CopilotEvidence(origin: "read", text: "Account A evidence", sources: [], wasTruncated: false)
    let conversation = CopilotConversation(accountDID: a, context: .search(query: "cats"), turns: [
      .init(role: .user, text: "Find cats"),
      .init(role: .assistant, text: "Answer", evidence: [evidence], proposalOutcome: "Not executed")
    ])
    try await store.save(conversation)
    #expect(try await store.conversations(for: b).isEmpty)
    let stored = try await store.conversations(for: a)
    #expect(stored.first?.turns.last?.evidence == [evidence])
    await store.clear(accountDID: a)
    await store.clear(accountDID: b)
    #expect(try await store.conversations(for: a).isEmpty)
  }
}
