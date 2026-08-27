import Foundation

struct CopilotHistorySelection: Sendable {
    let tokenLimit: Int
    let fits: Bool
    let retainedTurns: [CopilotStoredTurn]
    let removedTurnCount: Int
}

enum CopilotContextBudget {
    private struct TurnPair {
        let user: CopilotStoredTurn
        let assistant: CopilotStoredTurn
    }

    static let maximumTokens: Int = 8192

    private static func format(_ pairs: [TurnPair]) -> String {
        pairs.map { "User: \($0.user.text)\nAssistant: \($0.assistant.text)" }
            .joined(separator: "\n")
    }

    static func formatHistory(turns: [CopilotStoredTurn]) -> String {
        format(extractPairs(from: turns))
    }

    private static func extractPairs(from turns: [CopilotStoredTurn]) -> [TurnPair] {
        let sortedTurns = turns.sorted { $0.createdAt < $1.createdAt }
        var pairs: [TurnPair] = []
        var index = 0

        while index + 1 < sortedTurns.count {
            let user = sortedTurns[index]
            let assistant = sortedTurns[index + 1]
            if user.role == .user && assistant.role == .assistant {
                pairs.append(TurnPair(user: user, assistant: assistant))
                index += 2
            } else {
                index += 1
            }
        }
        return pairs
    }

    static func selectHistory(
        turns: [CopilotStoredTurn],
        modelContextSize: Int,
        reservedTokenCount: Int,
        candidateTokenCount: ([CopilotStoredTurn]) async throws -> Int
    ) async throws -> CopilotHistorySelection {
        let tokenLimit = min(modelContextSize, maximumTokens)

        let baseCandidateTokens = try await candidateTokenCount([])
        guard reservedTokenCount + baseCandidateTokens <= tokenLimit else {
            return CopilotHistorySelection(
                tokenLimit: tokenLimit,
                fits: false,
                retainedTurns: [],
                removedTurnCount: turns.count
            )
        }

        let pairs = extractPairs(from: turns)
        var bestTurns: [CopilotStoredTurn] = []

        if !pairs.isEmpty {
            for count in 1...pairs.count {
                let candidateTurns = pairs.suffix(count).flatMap { [$0.user, $0.assistant] }
                let candidateCost = try await candidateTokenCount(candidateTurns)
                if reservedTokenCount + candidateCost <= tokenLimit {
                    bestTurns = candidateTurns
                } else {
                    break
                }
            }
        }

        let removedTurnCount = turns.count - bestTurns.count
        return CopilotHistorySelection(
            tokenLimit: tokenLimit,
            fits: true,
            retainedTurns: bestTurns,
            removedTurnCount: removedTurnCount
        )
    }
}
