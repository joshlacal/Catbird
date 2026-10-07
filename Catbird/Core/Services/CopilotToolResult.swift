import Foundation

/// Caps the exact text returned by a read, with a token counter supplied by the active local model.
enum CopilotToolResult {
  static let maximumTokens = 512

  static func bounded(
    _ text: String,
    tokenCount: @Sendable (String) async throws -> Int
  ) async throws -> (text: String, wasTruncated: Bool) {
    try Task.checkCancellation()
    let count = try await tokenCount(text)
    try Task.checkCancellation()
    guard count > maximumTokens else { return (text, false) }
    let notice = "Partial tool result (truncated; omitted contents are unknown):\n"
    var prefix = text
    // Geometric reduction bounds tokenizer work even for adversarially large results.
    while !prefix.isEmpty {
      prefix = String(prefix.prefix(prefix.count / 2))
      let candidate = notice + prefix
      let candidateCount = try await tokenCount(candidate)
      try Task.checkCancellation()
      if candidateCount <= maximumTokens { return (candidate, true) }
    }
    return ("Tool result omitted because it exceeded the context budget.", true)
  }
}
