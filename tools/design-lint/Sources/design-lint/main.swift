import DesignLintCore
import Foundation

struct CLIOptions {
    var rootPath: String = FileManager.default.currentDirectoryPath
    var files: [String] = []
    var budgetPath: String?
    var writeBudgetPath: String?
    var checkRatchet: Bool = false
    var swiftLintJSONPath: String?
    var outputJSON: Bool = false
    var failOnAny: Bool = false
    var compareBudgetBase: String?
    var compareBudgetHead: String?
}

func printUsage() {
    let text = """
    design-lint — Catbird SwiftSyntax AST design-system linter & monotonic ratchet

    USAGE:
      design-lint [OPTIONS]

    OPTIONS:
      --root <dir>                Repository root to scan (default: cwd)
      --file <path>               Lint a single Swift file (repeatable; fast hook mode)
      --budget <path>             Compare against per-(file, rule) budget JSON
      --write-budget [path]       Write sorted budget JSON (defaults to --budget or .design-lint-budget.json)
      --check-ratchet             Fail if any budgeted count increased OR decreased without ratcheting
      --swiftlint-json <path>     Ingest SwiftLint `--reporter json` output into the same ratchet
      --json                      Emit machine-readable JSON output
      --fail-on-any               Fail if any violation exists (even without --budget)
      --diff-budgets <base> <head> Fail if <head> budget increases any (file, rule) count vs <base>
      -h, --help                  Show this help
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func parseArgs(_ args: [String]) -> CLIOptions? {
    var opts = CLIOptions()
    var i = 1
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-h", "--help":
            printUsage()
            return nil
        case "--root":
            i += 1
            guard i < args.count else { return nil }
            opts.rootPath = args[i]
        case "--file":
            i += 1
            guard i < args.count else { return nil }
            opts.files.append(args[i])
        case "--budget":
            i += 1
            guard i < args.count else { return nil }
            opts.budgetPath = args[i]
        case "--write-budget":
            if i + 1 < args.count && !args[i + 1].hasPrefix("-") {
                i += 1
                opts.writeBudgetPath = args[i]
            } else {
                opts.writeBudgetPath = ""
            }
        case "--check-ratchet":
            opts.checkRatchet = true
        case "--swiftlint-json":
            i += 1
            guard i < args.count else { return nil }
            opts.swiftLintJSONPath = args[i]
        case "--json":
            opts.outputJSON = true
        case "--fail-on-any":
            opts.failOnAny = true
        case "--diff-budgets":
            guard i + 2 < args.count else { return nil }
            opts.compareBudgetBase = args[i + 1]
            opts.compareBudgetHead = args[i + 2]
            i += 2
        default:
            FileHandle.standardError.write(Data("error: unknown argument '\(arg)'\n".utf8))
            return nil
        }
        i += 1
    }
    return opts
}

struct JSONOutput: Codable {
    let violations: [Violation]
    let evaluation: RatchetEvaluation?
}

func resolveURL(_ path: String, relativeTo root: URL) -> URL {
    if path.hasPrefix("/") {
        return URL(fileURLWithPath: path).standardizedFileURL
    }
    return root.appendingPathComponent(path).standardizedFileURL
}

do {
    guard let opts = parseArgs(CommandLine.arguments) else {
        exit(CommandLine.arguments.contains("-h") || CommandLine.arguments.contains("--help") ? 0 : 2)
    }

    // Special CI mode: compare two budget files to detect ceiling increases.
    if let basePath = opts.compareBudgetBase, let headPath = opts.compareBudgetHead {
        let baseData = try Data(contentsOf: URL(fileURLWithPath: basePath))
        let headData = try Data(contentsOf: URL(fileURLWithPath: headPath))
        let baseBudget = try BudgetRatchet.decode(baseData)
        let headBudget = try BudgetRatchet.decode(headData)
        let increases = BudgetRatchet.budgetIncreases(from: baseBudget, to: headBudget)
        if opts.outputJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(increases)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } else if increases.isEmpty {
            print("design-lint: budget diff clean (0 ceiling increases; total \(baseBudget.totalViolations) -> \(headBudget.totalViolations)).")
        } else {
            for issue in increases {
                FileHandle.standardError.write(Data((issue.description + "\n").utf8))
            }
        }
        exit(increases.isEmpty ? 0 : 1)
    }

    let rootURL = URL(fileURLWithPath: opts.rootPath, isDirectory: true).standardizedFileURL
    let linter = DesignLinter()

    var violations: [Violation]
    var scopedFiles: Set<String>? = nil

    if !opts.files.isEmpty {
        let fileURLs = opts.files.map { resolveURL($0, relativeTo: rootURL) }
        violations = try linter.lintFiles(fileURLs, root: rootURL)
        scopedFiles = Set(fileURLs.map { linter.relativePath(of: $0, under: rootURL) })
    } else {
        violations = try linter.lintRoot(rootURL)
    }

    if let slPath = opts.swiftLintJSONPath {
        let slURL = resolveURL(slPath, relativeTo: rootURL)
        let slData = try Data(contentsOf: slURL)
        var slViolations = try linter.parseSwiftLintJSON(slData, root: rootURL)
        if let scoped = scopedFiles {
            slViolations = slViolations.filter { scoped.contains($0.file) }
        }
        violations.append(contentsOf: slViolations)
        violations.sort()
    }

    if let writePath = opts.writeBudgetPath {
        let targetPath = writePath.isEmpty ? (opts.budgetPath ?? ".design-lint-budget.json") : writePath
        let targetURL = resolveURL(targetPath, relativeTo: rootURL)
        let budget = DesignLintBudget.from(violations: violations)
        let encoded = try BudgetRatchet.encode(budget)
        try encoded.write(to: targetURL, options: .atomic)
        print("Wrote design lint budget to \(targetURL.path) (\(budget.totalViolations) total across \(budget.files.count) files).")
        exit(0)
    }

    var evaluation: RatchetEvaluation? = nil
    if let budgetPath = opts.budgetPath {
        let budgetURL = resolveURL(budgetPath, relativeTo: rootURL)
        let budgetData = try Data(contentsOf: budgetURL)
        let budget = try BudgetRatchet.decode(budgetData)
        evaluation = BudgetRatchet.evaluate(
            budget: budget,
            violations: violations,
            scopedFiles: scopedFiles,
            enforceShrink: opts.checkRatchet
        )
    }

    if opts.outputJSON {
        let payload = JSONOutput(violations: violations, evaluation: evaluation)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    } else if let eval = evaluation {
        if eval.passed {
            let scopeDesc = scopedFiles.map { "\($0.count) scoped file(s)" } ?? "full repository"
            print("design-lint: PASS (\(scopeDesc); \(eval.totalActual) budgeted / \(eval.totalBudgeted) ceiling).")
        } else {
            let failingFiles = Set(eval.issues.map(\.file))
            let failingRulesByFile = Dictionary(grouping: eval.issues, by: \.file)
                .mapValues { Set($0.map(\.rule)) }
            for v in violations where failingFiles.contains(v.file) && (failingRulesByFile[v.file]?.contains(v.rule) == true) {
                FileHandle.standardError.write(Data((v.xcodeFormatted + "\n").utf8))
            }
            FileHandle.standardError.write(Data("\n--- Design Lint Ratchet Summary ---\n".utf8))
            for issue in eval.issues {
                FileHandle.standardError.write(Data((issue.description + "\n").utf8))
            }
        }
    } else {
        for v in violations {
            print(v.xcodeFormatted)
        }
    }

    if let eval = evaluation {
        exit(eval.passed ? 0 : 1)
    } else if opts.failOnAny && !violations.isEmpty {
        exit(1)
    }
    exit(0)
} catch {
    FileHandle.standardError.write(Data("design-lint error: \(error)\n".utf8))
    exit(2)
}
