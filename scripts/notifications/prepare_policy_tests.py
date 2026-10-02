#!/usr/bin/env python3
"""Qualify exact production notification policy and cache/pagination members.

The existing preference suite remains unchanged. The actual Catbird policy test
body is copied with import-only substitutions. External DTOs/network/hydration
are fake; production policy, grouping, projection and paging methods are not.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from prepare_and_test import declaration_end, prepare


def replace_once(text: str, before: str, after: str) -> str:
    if text.count(before) != 1:
        raise ValueError(f"Expected exactly one fake seam: {before!r}")
    return text.replace(before, after)


def prepare_policy(repo: Path, output: Path) -> dict:
    templates = Path(__file__).resolve().parent
    prepare(repo, output)
    target = output / "Sources/NotificationHarness"
    test_target = output / "Tests/NotificationHarnessTests"

    # Extend only the fake DTO/API surface in this separate generated package.
    # Original first-harness scripts and receipts are left untouched.
    doubles_path = target / "TestDoubles.swift"
    doubles = doubles_path.read_text()
    doubles = replace_once(doubles,
        '  public let didString: String\n  public init(didString: String) throws { self.didString = didString }',
        '  private let rawDID: String\n  public init(didString: String) throws { rawDID = didString }\n  public func didString() -> String { rawDID }')
    doubles = doubles.replace('_ message: String', '_ message: HarnessLogMessage')
    doubles = replace_once(doubles, '  var getHandler: (() async throws -> GetReply)?',
        '  var listHandler: ((AppBskyNotificationListNotifications.Parameters) async throws -> ListReply)?\n'
        '  private(set) var listInputs: [AppBskyNotificationListNotifications.Parameters] = []\n'
        '  var getHandler: (() async throws -> GetReply)?')
    doubles = replace_once(doubles,
        '  func getPreferences(input: AppBskyNotificationGetPreferences.Input) async throws -> GetReply {',
        '  func listNotifications(input: AppBskyNotificationListNotifications.Parameters) async throws -> ListReply {\n'
        '    listInputs.append(input)\n'
        '    if let listHandler { return try await listHandler(input) }\n'
        '    return (200, .init(cursor: nil, notifications: []))\n'
        '  }\n\n'
        '  func getPreferences(input: AppBskyNotificationGetPreferences.Input) async throws -> GetReply {')
    doubles_path.write_text(doubles)
    shutil.copyfile(templates / "PolicyTestDoubles.swift", target / "PolicyTestDoubles.swift")

    source_path = repo / "Catbird/Features/Notifications/ViewModels/NotificationsViewModel.swift"
    source = source_path.read_text()
    start = source.index("enum NotificationType:")
    end = source.index("  // MARK: - Initialization", start)
    spans = [("models-caches-and-view-model-properties", start, end)]
    init = re.search(r"^  init\(client:", source, re.MULTILINE)
    if not init:
        raise ValueError("Production view model initializer missing")
    spans.append(("init", init.start(), declaration_end(source, init.start())))
    methods = [
        "loadNotifications", "refreshNotifications", "loadMoreNotifications", "ensureEnoughNotifications",
        "setFilter", "clearError", "cleanupCache", "fetchNotifications", "groupNotifications",
        "viaRepostGroupingSubject", "classifyFollowNotification", "mapReasonToNotificationType",
        "followRecordCreatedAt",
    ]
    for name in methods:
        match = re.search(rf"^  (?:(?:private|public|internal) )?(?:static )?func {name}\(", source, re.MULTILINE)
        if not match:
            raise ValueError(f"Production view model method missing: {name}")
        spans.append((name, match.start(), declaration_end(source, match.start())))
    def copied(span: tuple[str, int, int]) -> str:
        _, start, end = span
        line = source.count("\n", 0, start) + 1
        return f"#sourceLocation(file: {json.dumps(str(source_path))}, line: {line})\n" + source[start:end] + "\n#sourceLocation()\n"
    extracted = "import Foundation\nimport Observation\n" + "\n".join(copied(span) for span in spans)
    extracted += (templates / "PolicyViewModelTestSeams.swift").read_text() + "\n}\n"
    (target / "ExtractedNotificationsViewModel.swift").write_text(extracted)

    policy_path = source_path.with_name("NotificationListVisibilityPolicy.swift")
    test_path = repo / "CatbirdTests/NotificationListVisibilityPolicyTests.swift"
    policy = policy_path.read_text()
    policy_tests = test_path.read_text()
    (target / "NotificationListVisibilityPolicy.swift").write_text(
        replace_once(policy, "import Petrel\n", "// Petrel types supplied by inert harness DTOs.\n")
    )
    rewritten_tests = replace_once(policy_tests, "import Petrel\n", "// Petrel types supplied by NotificationHarness.\n")
    rewritten_tests = replace_once(rewritten_tests, "@testable import Catbird\n", "@testable import NotificationHarness\n")
    def without_imports(text: str) -> str:
        return "\n".join(line for line in text.splitlines() if not (
            line.startswith("import ") or line.startswith("@testable import ")
            or line == "// Petrel types supplied by NotificationHarness."
        ))
    if without_imports(policy_tests) != without_imports(rewritten_tests):
        raise ValueError("Production policy test body changed beyond imports")
    (test_target / "NotificationListVisibilityPolicyTests.swift").write_text(rewritten_tests)
    shutil.copyfile(templates / "NotificationProjectionTests.swift", test_target / "NotificationProjectionTests.swift")

    manager_path = repo / "Catbird/Features/Notifications/Services/NotificationManager.swift"
    paths = [manager_path, source_path, policy_path, test_path]
    manifest = {
        "sources": {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths},
        "viewModelSpans": [
            {"name": name, "line": source.count("\n", 0, start) + 1,
             "sha256": hashlib.sha256(source[start:end].encode()).hexdigest()}
            for name, start, end in spans
        ],
        "productionPolicyTestCount": len(re.findall(r"^  @Test", policy_tests, re.MULTILINE)),
        "productionPolicyTestBodySha256": hashlib.sha256(without_imports(policy_tests).encode()).hexdigest(),
        "generatedPolicyTestBodySha256": hashlib.sha256(without_imports(rewritten_tests).encode()).hexdigest(),
        "productionTransformations": ["Policy import Petrel replaced by comment", "Test import Petrel replaced by comment", "Test @testable import Catbird renamed to NotificationHarness"],
        "boundary": "Exact production policy, model, grouping, cache and cursor members; fake typed DTOs/network, inert post/follow hydration and manager platform/MLS effects. Observation invalidation is tested; SwiftUI rendering is not.",
    }
    (output / "policy-extraction-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Prepared {len(spans)} exact VM spans and {manifest['productionPolicyTestCount']} actual production policy tests", flush=True)
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    output = (args.output or Path(tempfile.mkdtemp(prefix="catbird-notification-policy-"))).resolve()
    manifest = prepare_policy(args.repo.resolve(), output)
    print(f"Harness: {output}", flush=True)
    if args.prepare_only:
        return
    command = ["swift", "test", "--package-path", str(output), "--jobs", "2"]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    assert process.stdout is not None
    with (output / "test.log").open("w") as log:
        for line in process.stdout:
            print(line, end="", flush=True)
            log.write(line)
    code = process.wait()
    unchanged = all(hashlib.sha256(Path(path).read_bytes()).hexdigest() == digest for path, digest in manifest["sources"].items())
    result = {
        "command": command, "exitCode": code, "sourcesUnchangedDuringRun": unchanged,
        "sourceSha256": manifest["sources"],
        "swiftVersion": subprocess.run(["swift", "--version"], capture_output=True, text=True, check=True).stdout.strip(),
    }
    (output / "test-result.json").write_text(json.dumps(result, indent=2) + "\n")
    if code != 0:
        raise subprocess.CalledProcessError(code, command)
    if not unchanged:
        raise RuntimeError("Production source changed during run; qualification needs review")


if __name__ == "__main__":
    main()
