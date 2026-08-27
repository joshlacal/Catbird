import XCTest
@testable import Catbird

final class CopilotContextBudgetTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testMaximumTokensConstantIs8192() {
        XCTAssertEqual(CopilotContextBudget.maximumTokens, 8192)
    }

    func testEffectiveCapCapsAt8192WhenModelContextIsLarger() async throws {
        let turns = makeTurnPairs(count: 3, tokenCostPerTurn: 500)
        let selection = try await CopilotContextBudget.selectHistory(
            turns: turns,
            modelContextSize: 16384,
            reservedTokenCount: 1000,
            candidateTokenCount: { candidateTurns in
                candidateTurns.count * 500
            }
        )

        XCTAssertEqual(selection.tokenLimit, 8192)
        XCTAssertTrue(selection.fits)
        XCTAssertEqual(selection.retainedTurns.count, turns.count)
        XCTAssertEqual(selection.removedTurnCount, 0)
    }

    func testSmallerModelContextSizeDeterminesTokenLimit() async throws {
        let turns = makeTurnPairs(count: 4, tokenCostPerTurn: 200)
        let selection = try await CopilotContextBudget.selectHistory(
            turns: turns,
            modelContextSize: 2048,
            reservedTokenCount: 400,
            candidateTokenCount: { candidateTurns in
                candidateTurns.count * 200
            }
        )

        XCTAssertEqual(selection.tokenLimit, 2048)
        XCTAssertTrue(selection.fits)
        XCTAssertEqual(selection.retainedTurns.count, turns.count)
        XCTAssertEqual(selection.removedTurnCount, 0)
    }

    func testTrimsToNewestAdjacentCompleteUserAssistantPairSuffix() async throws {
        let turns = makeTurnPairs(count: 4, tokenCostPerTurn: 250)
        let selection = try await CopilotContextBudget.selectHistory(
            turns: turns,
            modelContextSize: 2000,
            reservedTokenCount: 500,
            candidateTokenCount: { candidateTurns in
                candidateTurns.count * 250
            }
        )

        XCTAssertEqual(selection.tokenLimit, 2000)
        XCTAssertTrue(selection.fits)
        XCTAssertEqual(selection.retainedTurns.count, 6)
        XCTAssertEqual(selection.removedTurnCount, 2)
        XCTAssertEqual(selection.retainedTurns.map(\.text), Array(turns.suffix(6)).map(\.text))
        XCTAssertEqual(selection.retainedTurns.first?.role, .user)
        XCTAssertEqual(selection.retainedTurns.last?.role, .assistant)
    }

    func testOddAndIncompleteTurnsAreExcludedFromRetainedPairs() async throws {
        var turns = makeTurnPairs(count: 2, tokenCostPerTurn: 100)
        let leadingOrphan = CopilotStoredTurn(
            id: UUID(),
            role: .assistant,
            text: "tokens:100:leading",
            createdAt: baseDate.addingTimeInterval(0)
        )
        let trailingOrphan = CopilotStoredTurn(
            id: UUID(),
            role: .user,
            text: "tokens:100:trailing",
            createdAt: baseDate.addingTimeInterval(100)
        )
        turns.insert(leadingOrphan, at: 0)
        turns.append(trailingOrphan)

        let selection = try await CopilotContextBudget.selectHistory(
            turns: turns,
            modelContextSize: 4096,
            reservedTokenCount: 500,
            candidateTokenCount: { candidateTurns in
                candidateTurns.count * 100
            }
        )

        XCTAssertTrue(selection.fits)
        XCTAssertEqual(selection.retainedTurns.count, 4)
        XCTAssertEqual(selection.removedTurnCount, 2)
        for i in stride(from: 0, to: selection.retainedTurns.count, by: 2) {
            XCTAssertEqual(selection.retainedTurns[i].role, .user)
            XCTAssertEqual(selection.retainedTurns[i + 1].role, .assistant)
        }
    }

    func testRetainedTurnsPreserveStrictChronologicalOrder() async throws {
        let turns = makeTurnPairs(count: 4, tokenCostPerTurn: 200)
        let selection = try await CopilotContextBudget.selectHistory(
            turns: turns,
            modelContextSize: 1200,
            reservedTokenCount: 300,
            candidateTokenCount: { candidateTurns in
                candidateTurns.count * 200
            }
        )

        XCTAssertTrue(selection.fits)
        XCTAssertEqual(selection.retainedTurns.count, 4)
        for i in 0..<(selection.retainedTurns.count - 1) {
            XCTAssertLessThan(selection.retainedTurns[i].createdAt, selection.retainedTurns[i + 1].createdAt)
        }
    }

    func testOversizedReservedCostExceedingLimitSetsFitsFalseAndRetainsNone() async throws {
        let turns = makeTurnPairs(count: 2, tokenCostPerTurn: 100)

        let overflow = try await CopilotContextBudget.selectHistory(
            turns: turns,
            modelContextSize: 8192,
            reservedTokenCount: 9000,
            candidateTokenCount: { _ in 0 }
        )
        XCTAssertFalse(overflow.fits)
        XCTAssertTrue(overflow.retainedTurns.isEmpty)
        XCTAssertEqual(overflow.removedTurnCount, turns.count)

        let emptyPromptExceeds = try await CopilotContextBudget.selectHistory(
            turns: turns,
            modelContextSize: 8192,
            reservedTokenCount: 8190,
            candidateTokenCount: { candidateTurns in
                candidateTurns.isEmpty ? 5 : candidateTurns.count * 100
            }
        )
        XCTAssertFalse(emptyPromptExceeds.fits)
        XCTAssertTrue(emptyPromptExceeds.retainedTurns.isEmpty)
        XCTAssertEqual(emptyPromptExceeds.removedTurnCount, turns.count)
    }

    func testBoundarySensitivePromptFormattingPreventsOvercountingOrUndercountingVersusAdditive() async throws {
        let turns = makeTurnPairs(count: 2, tokenCostPerTurn: 140)
        // 2 pairs = 4 turns. Additive raw turn tokens = 4 * 140 = 560 tokens.
        // Budget limit = 1000. Reserved = 400. Available = 600.
        // Additive heuristic: 400 + 560 = 960 <= 1000 (would falsely select 2 pairs).
        // Candidate prompt formatting includes prompt template overhead (+80 tokens for 2 pairs):
        // candidateTokenCount(4 turns) = 560 + 80 = 640 -> 400 + 640 = 1040 > 1000 (exceeds budget).
        // candidateTokenCount(2 turns) = 280 + 40 = 320 -> 400 + 320 = 720 <= 1000 (fits).
        let selection = try await CopilotContextBudget.selectHistory(
            turns: turns,
            modelContextSize: 1000,
            reservedTokenCount: 400,
            candidateTokenCount: { candidateTurns in
                if candidateTurns.isEmpty { return 0 }
                let baseTokens = candidateTurns.count * 140
                let framingOverhead = candidateTurns.count == 4 ? 80 : 40
                return baseTokens + framingOverhead
            }
        )

        XCTAssertTrue(selection.fits)
        XCTAssertEqual(selection.retainedTurns.count, 2)
        XCTAssertEqual(selection.removedTurnCount, 2)
        XCTAssertEqual(selection.retainedTurns.map(\.text), Array(turns.suffix(2)).map(\.text))
    }

    // MARK: - Helpers

    private func makeTurnPairs(count: Int, tokenCostPerTurn: Int) -> [CopilotStoredTurn] {
        var turns: [CopilotStoredTurn] = []
        for i in 1...count {
            let userTurn = CopilotStoredTurn(
                id: UUID(),
                role: .user,
                text: "tokens:\(tokenCostPerTurn):u\(i)",
                createdAt: baseDate.addingTimeInterval(Double(i * 10))
            )
            let assistantTurn = CopilotStoredTurn(
                id: UUID(),
                role: .assistant,
                text: "tokens:\(tokenCostPerTurn):a\(i)",
                createdAt: baseDate.addingTimeInterval(Double(i * 10 + 1))
            )
            turns.append(userTurn)
            turns.append(assistantTurn)
        }
        return turns
    }
}
