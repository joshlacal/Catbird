import Foundation

public enum LintRuleID: String, CaseIterable, Codable, Sendable, Comparable {
    case rawCornerRadius = "raw_corner_radius"
    case rawSpacing = "raw_spacing"
    case offGridSpacing = "off_grid_spacing"
    case rawFont = "raw_font"
    case rawColor = "raw_color"
    case legacyMaterial = "legacy_material"
    case rawAnimation = "raw_animation"
    case legacyDesignTokens = "legacy_design_tokens"
    case smallTapTarget = "small_tap_target"
    case unreasonedLintDisable = "unreasoned_lint_disable"

    public static func < (lhs: LintRuleID, rhs: LintRuleID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct Violation: Codable, Equatable, Sendable, Comparable {
    public let file: String
    public let line: Int
    public let column: Int
    public let rule: String
    public let message: String

    public init(file: String, line: Int, column: Int, rule: String, message: String) {
        self.file = file
        self.line = line
        self.column = column
        self.rule = rule
        self.message = message
    }

    public init(file: String, line: Int, column: Int, rule: LintRuleID, message: String) {
        self.init(file: file, line: line, column: column, rule: rule.rawValue, message: message)
    }

    public static func < (lhs: Violation, rhs: Violation) -> Bool {
        if lhs.file != rhs.file { return lhs.file < rhs.file }
        if lhs.line != rhs.line { return lhs.line < rhs.line }
        if lhs.column != rhs.column { return lhs.column < rhs.column }
        if lhs.rule != rhs.rule { return lhs.rule < rhs.rule }
        return lhs.message < rhs.message
    }

    public var xcodeFormatted: String {
        "\(file):\(line):\(column): error: [\(rule)] \(message)"
    }
}

public struct DesignLintBudget: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let totalViolations: Int
    public let ruleTotals: [String: Int]
    public let files: [String: [String: Int]]

    public init(
        schemaVersion: Int = 1,
        files: [String: [String: Int]]
    ) {
        self.schemaVersion = schemaVersion
        var cleanedFiles: [String: [String: Int]] = [:]
        var totals: [String: Int] = [:]
        var grandTotal = 0

        for (file, rules) in files {
            let nonZero = rules.filter { $0.value > 0 }
            guard !nonZero.isEmpty else { continue }
            cleanedFiles[file] = nonZero
            for (rule, count) in nonZero {
                totals[rule, default: 0] += count
                grandTotal += count
            }
        }

        self.files = cleanedFiles
        self.ruleTotals = totals
        self.totalViolations = grandTotal
    }

    public static func from(violations: [Violation]) -> DesignLintBudget {
        var counts: [String: [String: Int]] = [:]
        for violation in violations {
            counts[violation.file, default: [:]][violation.rule, default: 0] += 1
        }
        return DesignLintBudget(files: counts)
    }
}

public struct RatchetIssue: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case regression
        case newFileViolation = "new_file_violation"
        case unratchetedDrop = "unratcheted_drop"
        case staleFileEntry = "stale_file_entry"
    }

    public let kind: Kind
    public let file: String
    public let rule: String
    public let budgeted: Int
    public let actual: Int

    public init(kind: Kind, file: String, rule: String, budgeted: Int, actual: Int) {
        self.kind = kind
        self.file = file
        self.rule = rule
        self.budgeted = budgeted
        self.actual = actual
    }

    public var description: String {
        switch kind {
        case .regression:
            return "REGRESSION \(file) [\(rule)]: budgeted \(budgeted) -> actual \(actual) (+\(actual - budgeted))"
        case .newFileViolation:
            return "NEW FILE VIOLATION \(file) [\(rule)]: budgeted 0 -> actual \(actual)"
        case .unratchetedDrop:
            return "UNRATCHETED DROP \(file) [\(rule)]: budgeted \(budgeted) -> actual \(actual) (-\(budgeted - actual)); run `./scripts/design_lint.sh --write-budget` to lock in the improvement"
        case .staleFileEntry:
            return "STALE BUDGET ENTRY \(file) [\(rule)]: budgeted \(budgeted) -> file absent/clean (0); run `./scripts/design_lint.sh --write-budget`"
        }
    }
}

public struct RatchetEvaluation: Codable, Equatable, Sendable {
    public let passed: Bool
    public let issues: [RatchetIssue]
    public let totalBudgeted: Int
    public let totalActual: Int

    public init(passed: Bool, issues: [RatchetIssue], totalBudgeted: Int, totalActual: Int) {
        self.passed = passed
        self.issues = issues
        self.totalBudgeted = totalBudgeted
        self.totalActual = totalActual
    }
}
