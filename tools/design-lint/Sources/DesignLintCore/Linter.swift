import Foundation
import SwiftParser
import SwiftSyntax

public struct DesignLinter: Sendable {
    public static let defaultTargetDirs = [
        "Catbird",
        "CatbirdFeedWidget",
        "CatbirdNotificationWidget",
        "NotificationServiceExtension",
        "SharedDraftImporter",
    ]

    public static let excludedPathFragments = [
        "/_trash/",
        "/.build/",
        "/DerivedData/",
        "/Pods/",
        "/.git/",
        "/tools/",
        "/Core/UI/Kit/",
        "/Packages/CatbirdDesignSystem/",
    ]

    public init() {}

    public func isExcluded(relativePath: String) -> Bool {
        let normalized = "/" + relativePath.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for fragment in Self.excludedPathFragments {
            if normalized.contains(fragment) {
                return true
            }
        }
        return false
    }

    public func discoverSwiftFiles(root: URL) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []

        for dirName in Self.defaultTargetDirs {
            let dirURL = root.appendingPathComponent(dirName, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            guard let enumerator = fm.enumerator(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "swift" else { continue }
                let rel = relativePath(of: fileURL, under: root)
                if isExcluded(relativePath: rel) { continue }
                results.append(fileURL)
            }
        }

        return results.sorted { $0.path < $1.path }
    }

    public func lint(source: String, relativePath: String) -> [Violation] {
        if isExcluded(relativePath: relativePath) {
            return []
        }
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: relativePath, tree: tree)
        let ignores = IgnoreDirectiveIndex.scan(source: source, file: relativePath)
        let exemptions = FileRuleExemptions.forPath(relativePath)
        let visitor = DesignLintVisitor(
            file: relativePath,
            converter: converter,
            ignores: ignores,
            exemptions: exemptions
        )
        visitor.walk(tree)
        return visitor.violations.sorted()
    }

    public func lintFile(at url: URL, root: URL) throws -> [Violation] {
        let rel = relativePath(of: url, under: root)
        if isExcluded(relativePath: rel) {
            return []
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        return lint(source: source, relativePath: rel)
    }

    public func lintFiles(_ urls: [URL], root: URL) throws -> [Violation] {
        var all: [Violation] = []
        for url in urls {
            all.append(contentsOf: try lintFile(at: url, root: root))
        }
        return all.sorted()
    }

    public func lintRoot(_ root: URL) throws -> [Violation] {
        let files = discoverSwiftFiles(root: root)
        return try lintFiles(files, root: root)
    }

    /// Parses SwiftLint `--reporter json` output and converts entries into `Violation`s
    /// prefixed with `swiftlint.` so they participate in the exact same monotonic ratchet budget.
    public func parseSwiftLintJSON(_ data: Data, root: URL) throws -> [Violation] {
        struct SwiftLintEntry: Decodable {
            let file: String
            let line: Int?
            let character: Int?
            let rule_id: String
            let reason: String
        }
        guard !data.isEmpty else { return [] }
        let entries = try JSONDecoder().decode([SwiftLintEntry].self, from: data)
        return entries.compactMap { entry in
            let url = URL(fileURLWithPath: entry.file)
            let rel = relativePath(of: url, under: root)
            if isExcluded(relativePath: rel) { return nil }
            return Violation(
                file: rel,
                line: entry.line ?? 1,
                column: entry.character ?? 1,
                rule: "swiftlint.\(entry.rule_id)",
                message: entry.reason
            )
        }.sorted()
    }

    public func relativePath(of fileURL: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return filePath
    }
}
