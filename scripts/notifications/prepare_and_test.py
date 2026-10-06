#!/usr/bin/env python3
"""Run bounded notification tests against exact spans of the production Swift file.

The generated package has no external dependencies. Its platform and network
seams are fake; the selected NotificationManager declarations are copied without
rewriting their bodies. Nothing contacts a device, account, or live endpoint.
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


def declaration_end(source: str, start: int) -> int:
    """Find the closing brace while ignoring strings and comments.

    Swift interpolations in these declarations are wholly inside normal string
    literals, so braces within them cannot close the declaration. Nested block
    comments are handled, and unknown raw/multiline literals fail explicitly.
    """
    brace = source.index("{", start)
    depth = 0
    index = brace
    while index < len(source):
        if source.startswith("//", index):
            end = source.find("\n", index)
            index = len(source) if end < 0 else end + 1
            continue
        if source.startswith("/*", index):
            nesting = 1
            index += 2
            while nesting:
                if source.startswith("/*", index):
                    nesting += 1
                    index += 2
                elif source.startswith("*/", index):
                    nesting -= 1
                    index += 2
                else:
                    index += 1
                if index >= len(source):
                    raise ValueError("Unclosed block comment")
            continue
        if source.startswith('"""', index) or source.startswith('#"', index):
            raise ValueError("Update extractor for raw/multiline Swift strings")
        if source[index] == '"':
            index += 1
            while index < len(source):
                if source[index] == "\\":
                    index += 2
                elif source[index] == '"':
                    index += 1
                    break
                else:
                    index += 1
            continue
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    raise ValueError(f"Unclosed declaration starting at offset {start}")


def prepare(repo: Path, output: Path) -> None:
    template_dir = Path(__file__).resolve().parent
    source_path = repo / "Catbird/Features/Notifications/Services/NotificationManager.swift"
    source = source_path.read_text()
    class_start = source.index("@Observable\nfinal class NotificationManager:")
    properties_end = source.index("  // MARK: - Initialization", class_start)
    spans: list[tuple[str, int, int]] = [("class-and-properties", class_start, properties_end)]

    names = [
        "updateClient", "configureNotificationServiceRouting", "notificationServiceDID",
        "refreshNotificationPreferences", "fetchNotificationPreferences",
        "applyNotificationPreferencesSnapshot", "currentNotificationPreferencesSnapshot",
        "syncChatNotificationPreferenceFromPreferences", "updatePreferences",
        "performPreferencesMutation", "registerDeviceToken", "unregisterDeviceToken", "hexString",
        "disableNotifications",
    ]
    for name in names:
        matches = list(re.finditer(
            rf"^  (?:(?:private|public|internal|fileprivate) )?func {name}\(", source, re.MULTILINE
        ))
        if not matches:
            raise ValueError(f"Required production method missing: {name}")
        for number, match in enumerate(matches):
            if match.start() < properties_end:
                continue
            # Keep production attributes such as @MainActor and @discardableResult.
            start = match.start()
            while start > 0:
                previous = source.rfind("\n", 0, start - 1) + 1
                if source[previous:start].strip().startswith("@"):
                    start = previous
                else:
                    break
            spans.append((f"{name}-{number}", start, declaration_end(source, match.start())))
    for name in ["pushPlatform", "pushAppID"]:
        match = re.search(rf"^  private var {name}:.*\{{", source, re.MULTILINE)
        if not match:
            raise ValueError(f"Required production property missing: {name}")
        spans.append((name, match.start(), declaration_end(source, match.start())))

    def copied(span: tuple[str, int, int]) -> str:
        _, start, end = span
        line = source.count("\n", 0, start) + 1
        return f"#sourceLocation(file: {json.dumps(str(source_path))}, line: {line})\n" + source[start:end] + "\n#sourceLocation()\n"

    # State injection and untested platform side effects are explicit seams.
    members = "\n".join(copied(span) for span in spans)
    members += (template_dir / "ManagerTestSeams.swift").read_text() + "\n}\n"
    for name, pattern in [
        ("NotificationPreferences", r"^public struct NotificationPreferences:"),
        ("RegistrationCoordinator", r"^private actor RegistrationCoordinator"),
    ]:
        match = re.search(pattern, source, re.MULTILINE)
        if not match:
            raise ValueError(f"Required production type missing: {name}")
        span = (name, match.start(), declaration_end(source, match.start()))
        spans.append(span)
        members += copied(span)

    target = output / "Sources/NotificationHarness"
    tests = output / "Tests/NotificationHarnessTests"
    target.mkdir(parents=True, exist_ok=True)
    tests.mkdir(parents=True, exist_ok=True)
    (target / "ExtractedNotificationManager.swift").write_text(
        "// Generated by prepare_and_test.py; edit production sources instead.\n"
        "import Foundation\nimport Observation\n\n" + members
    )
    shutil.copyfile(template_dir / "TestDoubles.swift", target / "TestDoubles.swift")
    shutil.copyfile(template_dir / "NotificationPreferenceTests.swift", tests / "NotificationPreferenceTests.swift")
    (output / "Package.swift").write_text(
        '// swift-tools-version: 6.0\nimport PackageDescription\n'
        'let package = Package(name: "NotificationHarness", platforms: [.macOS(.v14)], '
        'products: [], targets: [.target(name: "NotificationHarness"), '
        '.testTarget(name: "NotificationHarnessTests", dependencies: ["NotificationHarness"])], '
        'swiftLanguageModes: [.v5])\n'
    )
    manifest = {
        "source": str(source_path),
        "sourceSha256": hashlib.sha256(source.encode()).hexdigest(),
        "languageMode": "5 (matching Catbird project SWIFT_VERSION)",
        "spans": [
            {"name": name, "line": source.count("\n", 0, start) + 1,
             "sha256": hashlib.sha256(source[start:end].encode()).hexdigest()}
            for name, start, end in spans
        ],
        "boundary": "Exact selected production members; fake Petrel/network, defaults, AppState and platform/MLS side effects. No app or device qualification.",
    }
    (output / "extraction-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Prepared {len(spans)} exact production source spans from {source_path}", flush=True)
    print(f"Source SHA-256: {manifest['sourceSha256']}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    output = args.output or Path(tempfile.mkdtemp(prefix="catbird-notifications-"))
    prepare(args.repo.resolve(), output.resolve())
    print(f"Harness: {output.resolve()}", flush=True)
    if not args.prepare_only:
        command = ["swift", "test", "--package-path", str(output.resolve()), "--jobs", "2"]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        assert process.stdout is not None
        with (output / "test.log").open("w") as log:
            for line in process.stdout:
                print(line, end="", flush=True)
                log.write(line)
        code = process.wait()
        manifest = json.loads((output / "extraction-manifest.json").read_text())
        unchanged = hashlib.sha256(Path(manifest["source"]).read_bytes()).hexdigest() == manifest["sourceSha256"]
        result = {
            "command": command,
            "exitCode": code,
            "sourceUnchangedDuringRun": unchanged,
            "sourceSha256": manifest["sourceSha256"],
            "swiftVersion": subprocess.run(["swift", "--version"], capture_output=True, text=True, check=True).stdout.strip(),
        }
        (output / "test-result.json").write_text(json.dumps(result, indent=2) + "\n")
        if code != 0:
            raise subprocess.CalledProcessError(code, command)
        if not unchanged:
            raise RuntimeError("Production source changed during the run; regenerate and rerun")


if __name__ == "__main__":
    main()
