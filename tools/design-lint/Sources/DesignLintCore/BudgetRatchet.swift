import Foundation

public enum BudgetRatchet {
    public static func encode(_ budget: DesignLintBudget) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(budget)
        data.append(0x0A) // trailing newline
        return data
    }

    public static func decode(_ data: Data) throws -> DesignLintBudget {
        try JSONDecoder().decode(DesignLintBudget.self, from: data)
    }

    /// Evaluates actual violations against a committed budget.
    ///
    /// - Parameters:
    ///   - budget: Committed per-(file, rule) ceiling.
    ///   - violations: Violations discovered in this run.
    ///   - scopedFiles: If non-nil (e.g. `--file` or `--diff` mode), evaluates ONLY those files
    ///     (and does not flag untouched files as stale). If nil (full-repo mode), checks all files
    ///     including stale entries for deleted or now-clean files.
    ///   - enforceShrink: When `true` (`--check-ratchet`), any drop below the budgeted count
    ///     or stale file entry fails so freed budget is locked in immediately.
    public static func evaluate(
        budget: DesignLintBudget,
        violations: [Violation],
        scopedFiles: Set<String>? = nil,
        enforceShrink: Bool = true
    ) -> RatchetEvaluation {
        var actualByFile: [String: [String: Int]] = [:]
        for v in violations {
            actualByFile[v.file, default: [:]][v.rule, default: 0] += 1
        }

        let filesToCheck: Set<String>
        if let scoped = scopedFiles {
            filesToCheck = scoped.union(actualByFile.keys)
        } else {
            filesToCheck = Set(budget.files.keys).union(actualByFile.keys)
        }

        var issues: [RatchetIssue] = []
        var totalBudgeted = 0
        var totalActual = 0

        for file in filesToCheck.sorted() {
            let budgetedRules = budget.files[file] ?? [:]
            let actualRules = actualByFile[file] ?? [:]
            let isNewToBudget = budget.files[file] == nil

            let allRules = Set(budgetedRules.keys).union(actualRules.keys).sorted()
            for rule in allRules {
                let budgetedCount = budgetedRules[rule] ?? 0
                let actualCount = actualRules[rule] ?? 0
                totalBudgeted += budgetedCount
                totalActual += actualCount

                if actualCount > budgetedCount {
                    issues.append(
                        RatchetIssue(
                            kind: isNewToBudget ? .newFileViolation : .regression,
                            file: file,
                            rule: rule,
                            budgeted: budgetedCount,
                            actual: actualCount
                        )
                    )
                } else if actualCount < budgetedCount && enforceShrink {
                    let kind: RatchetIssue.Kind = (actualRules.isEmpty && scopedFiles == nil) ? .staleFileEntry : .unratchetedDrop
                    issues.append(
                        RatchetIssue(
                            kind: kind,
                            file: file,
                            rule: rule,
                            budgeted: budgetedCount,
                            actual: actualCount
                        )
                    )
                }
            }
        }

        return RatchetEvaluation(
            passed: issues.isEmpty,
            issues: issues,
            totalBudgeted: totalBudgeted,
            totalActual: totalActual
        )
    }

    /// Compares two budgets (e.g. PR base vs PR head in CI) and returns every `(file, rule)`
    /// whose ceiling increased.
    public static func budgetIncreases(from base: DesignLintBudget, to head: DesignLintBudget) -> [RatchetIssue] {
        var increases: [RatchetIssue] = []
        for file in head.files.keys.sorted() {
            let baseRules = base.files[file] ?? [:]
            let headRules = head.files[file] ?? [:]
            let isNew = base.files[file] == nil
            for rule in headRules.keys.sorted() {
                let b = baseRules[rule] ?? 0
                let h = headRules[rule] ?? 0
                if h > b {
                    increases.append(
                        RatchetIssue(
                            kind: isNew ? .newFileViolation : .regression,
                            file: file,
                            rule: rule,
                            budgeted: b,
                            actual: h
                        )
                    )
                }
            }
        }
        return increases
    }
}
