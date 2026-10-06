import Foundation

struct CopilotHistorySelection: Sendable {
    let tokenLimit: Int
    let fits: Bool
    let retainedTurns: [CopilotStoredTurn]
    let removedTurnCount: Int
}

enum CopilotContextBudget {
    struct TurnPair: Encodable {
        let user: CopilotStoredTurn
        let previousAssistantAnswer: CopilotStoredTurn
        let assistantTextStatus = "Previous answer, not factual evidence."
    }

    static let maximumTokens: Int = 8192

    static func formatHistory(turns: [CopilotStoredTurn]) -> String {
        CopilotPrompt.sourceJSON(extractPairs(from: turns))
    }

    static func extractPairs(from turns: [CopilotStoredTurn]) -> [TurnPair] {
        // Keep persisted order when timestamps are equal, so a pair cannot be split.
        let sortedTurns = turns.enumerated().sorted {
            if $0.element.createdAt == $1.element.createdAt { return $0.offset < $1.offset }
            return $0.element.createdAt < $1.element.createdAt
        }.map(\.element)
        var pairs: [TurnPair] = []
        var index = 0

        while index + 1 < sortedTurns.count {
            let user = sortedTurns[index]
            let assistant = sortedTurns[index + 1]
            if user.role == .user && assistant.role == .assistant {
                pairs.append(TurnPair(user: user, previousAssistantAnswer: assistant))
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
        try Task.checkCancellation()
        let tokenLimit = min(modelContextSize, maximumTokens)

        let baseCandidateTokens = try await candidateTokenCount([])
        try Task.checkCancellation()
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
                try Task.checkCancellation()
                let candidateTurns = pairs.suffix(count).flatMap { [$0.user, $0.previousAssistantAnswer] }
                let candidateCost = try await candidateTokenCount(candidateTurns)
                try Task.checkCancellation()
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

    /// Before model token counting is available, bound the supplied text by UTF-8 bytes.
    /// The turn runner supplies history only; this is not a full-session token preflight.
    /// Callers supplying a whole prompt must also reserve instructions and tool/output space.
    static func selectLegacyHistory(
        turns: [CopilotStoredTurn],
        modelContextSize: Int,
        reservedTokenCount: Int,
        candidatePrompt: ([CopilotStoredTurn]) -> String
    ) async throws -> CopilotHistorySelection {
        try await selectHistory(
            turns: turns,
            modelContextSize: modelContextSize,
            reservedTokenCount: reservedTokenCount,
            candidateTokenCount: { candidatePrompt($0).utf8.count }
        )
    }
}
