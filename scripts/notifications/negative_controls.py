#!/usr/bin/env python3
"""Check test sensitivity using deliberately broken external source copies only."""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
from pathlib import Path
import re
import subprocess

from prepare_and_test import declaration_end, prepare


def rewrite_method(source: str, name: str, before: str, after: str) -> str:
    matches = list(re.finditer(
        rf"^  (?:(?:private|public|internal|fileprivate) )?func {name}\(", source, re.MULTILINE
    ))
    matching = []
    for match in matches:
        end = declaration_end(source, match.start())
        body = source[match.start():end]
        if before in body:
            matching.append((match.start(), end, body))
    if len(matching) != 1:
        raise ValueError(f"Expected exactly one {name} containing {before!r}")
    start, end, body = matching[0]
    return source[:start] + body.replace(before, after) + source[end:]


def run_control(repo: Path, output: Path, name: str, original: str, mutated: str, expected_tests: list[str]) -> dict:
    source_repo = output / name / "source"
    source_path = source_repo / "Catbird/Features/Notifications/Services/NotificationManager.swift"
    source_path.parent.mkdir(parents=True, exist_ok=True)
    source_path.write_text(mutated)
    (output / name / "mutation.diff").write_text("".join(difflib.unified_diff(
        original.splitlines(keepends=True), mutated.splitlines(keepends=True),
        fromfile="production/NotificationManager.swift", tofile="negative-control/NotificationManager.swift",
    )))
    package = output / name / "package"
    prepare(source_repo, package)
    command = ["swift", "test", "--package-path", str(package), "--jobs", "2", "--filter", "|".join(expected_tests)]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    assert process.stdout is not None
    chunks = []
    with (output / name / "test.log").open("w") as log:
        for line in process.stdout:
            print(line, end="", flush=True)
            log.write(line)
            chunks.append(line)
    code = process.wait()
    text = "".join(chunks)
    failures = {test: f"Test {test}() failed" in text for test in expected_tests}
    result = {
        "name": name,
        "command": command,
        "exitCode": code,
        "buildCompleted": "Build complete!" in text,
        "expectedTestFailures": failures,
        "confirmedSensitive": code != 0 and "Build complete!" in text and all(failures.values()),
        "originalSha256": hashlib.sha256(original.encode()).hexdigest(),
        "mutatedSha256": hashlib.sha256(mutated.encode()).hexdigest(),
        "productionSource": str(repo / "Catbird/Features/Notifications/Services/NotificationManager.swift"),
    }
    (output / name / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    if not result["confirmedSensitive"]:
        raise RuntimeError(f"Negative control {name} did not produce its expected assertion failures")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    repo = args.repo.resolve()
    output = args.output.resolve()
    if output == repo or repo in output.parents:
        raise ValueError("Negative controls must be outside the production checkout")
    source_path = repo / "Catbird/Features/Notifications/Services/NotificationManager.swift"
    original = source_path.read_text()

    master = original
    for method in ["updateClient", "registerDeviceToken"]:
        master = rewrite_method(master, method, "isMasterPushEnabled()", "true")
    results = [run_control(repo, output, "master-guards-removed", original, master, [
        "persistedMasterDisabledWithCachedTokenNeverRegistersPush",
    ])]

    mirrors = rewrite_method(original, "applyNotificationPreferencesSnapshot", "    syncChatNotificationPreferenceFromPreferences()\n", "")
    mirrors = rewrite_method(mirrors, "updatePreferences", "          self.syncChatNotificationPreferenceFromPreferences()\n", "")
    results.append(run_control(repo, output, "snapshot-rollback-mirror-sync-removed", original, mirrors, [
        "refreshSynchronizesChatMirrorAndDefaultsWithoutPutLoop",
        "failedPutRestoresPreferencesChatMirrorAndDefaults",
    ]))
    if source_path.read_text() != original:
        raise RuntimeError("Production source changed during controls; qualification needs review")
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print("Both negative controls produced the required test assertion failures; production source is unchanged.")


if __name__ == "__main__":
    main()
