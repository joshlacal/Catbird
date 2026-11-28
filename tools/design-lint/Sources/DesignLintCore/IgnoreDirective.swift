import Foundation
import SwiftSyntax

/// Parses inline suppression directives (`design-lint:ignore` and `swiftlint:disable`)
/// and validates that every pragma carries an explicit `-- reason:` and a ticket/decision reference.
public struct IgnoreDirectiveIndex: Sendable {
    public let suppressedRulesByLine: [Int: Set<String>]
    public let unreasonedViolations: [Violation]

    private static let referencePattern = try! NSRegularExpression(
        pattern: #"(#[0-9]+|DECISIONS\.md|DEC-[0-9]+|ADR-[0-9]+|DESIGN_DEBT_APPROVED)"#,
        options: []
    )

    public static func scan(source: String, file: String) -> IgnoreDirectiveIndex {
        var suppressed: [Int: Set<String>] = [:]
        var unreasoned: [Violation] = []

        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (idx, rawLine) in lines.enumerated() {
            let lineNumber = idx + 1
            let line = String(rawLine)
            guard let commentStart = findCommentStart(in: line) else { continue }
            let comment = String(line[commentStart...])

            if let range = comment.range(of: "design-lint:ignore") {
                let col = line.distance(from: line.startIndex, to: commentStart) + 1
                let tail = String(comment[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let (isNext, rest) = parseNextModifier(tail)
                let (rules, validReason) = parseRulesAndReason(rest)

                if validReason {
                    let targetLine = isNext ? (lineNumber + 1) : lineNumber
                    for rule in rules {
                        suppressed[targetLine, default: []].insert(rule)
                    }
                } else {
                    unreasoned.append(
                        Violation(
                            file: file,
                            line: lineNumber,
                            column: col,
                            rule: .unreasonedLintDisable,
                            message: "design-lint:ignore requires `-- reason: <explanation> (<#issue|DECISIONS.md|DEC-N|ADR-N|DESIGN_DEBT_APPROVED>)`."
                        )
                    )
                }
            }

            if let range = comment.range(of: "swiftlint:disable") {
                let col = line.distance(from: line.startIndex, to: commentStart) + 1
                let tail = String(comment[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let (_, rest) = parseNextModifier(tail)
                let (_, validReason) = parseRulesAndReason(rest)
                if !validReason {
                    unreasoned.append(
                        Violation(
                            file: file,
                            line: lineNumber,
                            column: col,
                            rule: .unreasonedLintDisable,
                            message: "swiftlint:disable requires `-- reason: <explanation> (<#issue|DECISIONS.md|DEC-N|ADR-N|DESIGN_DEBT_APPROVED>)`."
                        )
                    )
                }
            }
        }

        return IgnoreDirectiveIndex(suppressedRulesByLine: suppressed, unreasonedViolations: unreasoned)
    }

    public func isSuppressed(rule: LintRuleID, line: Int) -> Bool {
        guard let set = suppressedRulesByLine[line] else { return false }
        return set.contains("all") || set.contains(rule.rawValue)
    }

    private static func findCommentStart(in line: String) -> String.Index? {
        var inString = false
        var escaped = false
        var idx = line.startIndex
        while idx < line.endIndex {
            let ch = line[idx]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                idx = line.index(after: idx)
                continue
            }
            if ch == "\"" {
                inString = true
                idx = line.index(after: idx)
                continue
            }
            let next = line.index(after: idx)
            if ch == "/", next < line.endIndex, line[next] == "/" || line[next] == "*" {
                return idx
            }
            idx = next
        }
        return nil
    }

    private static func parseNextModifier(_ tail: String) -> (Bool, String) {
        if tail.hasPrefix(":next") {
            let rest = String(tail.dropFirst(":next".count)).trimmingCharacters(in: .whitespaces)
            return (true, rest)
        }
        if tail.hasPrefix(":this") {
            let rest = String(tail.dropFirst(":this".count)).trimmingCharacters(in: .whitespaces)
            return (false, rest)
        }
        if tail.hasPrefix(":previous") {
            let rest = String(tail.dropFirst(":previous".count)).trimmingCharacters(in: .whitespaces)
            return (false, rest)
        }
        return (false, tail)
    }

    private static func parseRulesAndReason(_ rest: String) -> ([String], Bool) {
        guard let marker = rest.range(of: "-- reason:") else {
            return ([], false)
        }
        let rulePart = String(rest[..<marker.lowerBound])
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        let reasonPart = String(rest[marker.upperBound...])
            .replacingOccurrences(of: "*/", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !rulePart.isEmpty, reasonPart.count >= 6 else {
            return (rulePart, false)
        }
        let nsRange = NSRange(reasonPart.startIndex..<reasonPart.endIndex, in: reasonPart)
        let hasRef = referencePattern.firstMatch(in: reasonPart, options: [], range: nsRange) != nil
        return (rulePart, hasRef)
    }
}
