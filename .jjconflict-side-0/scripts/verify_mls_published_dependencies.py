"""Validate the ordinary Xcode package graph and actual selected MLS test results."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
REPORTS = ROOT / "validation"
RESOLVED = ROOT / "Catbird.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
SUITES = ("MLSSendBlockingTests", "MLSConversationIdentityBoundaryTests", "MLSSystemMessageAdapterTests")


def write(name, value):
    (REPORTS / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def pins():
    return {pin["identity"]: pin for pin in json.loads(RESOLVED.read_text())["pins"]}


def before():
    assert not os.environ.get("CATBIRD_MLS_LOCAL_INTEGRATION"), "Local integration must be disabled"
    project = (ROOT / "Catbird.xcodeproj/project.pbxproj").read_text()
    assert "XCLocalSwiftPackageReference" not in project, "Only published packages may be used"
    expected = pins()
    for identity, repository in (("catbirdmlscore", "CatbirdMLSCore"), ("petrelcatbird", "PetrelCatbird"), ("petrel", "Petrel")):
        pin = expected[identity]
        revision = pin["state"]["revision"]
        assert re.fullmatch(r"[0-9a-f]{40}", revision)
        block = re.search(r'repositoryURL = "https://github.com/joshlacal/' + repository + r'(?:\.git)?";\s*requirement = \{(.*?)\};', project, re.S)
        assert block and f"revision = {revision};" in block[1], f"Project/lock disagree: {identity}"
    write("expected-pins.json", expected)
    counts = {suite: len(re.findall(r"@Test\b", (ROOT / "CatbirdTests" / f"{suite}.swift").read_text())) for suite in SUITES}
    assert all(counts.values())
    write("expected-tests.json", counts)


def resolved():
    expected = json.loads((REPORTS / "expected-pins.json").read_text())
    assert pins() == expected, "Resolution changed committed package versions"
    packages = Path(os.environ["RUNNER_TEMP"]) / "SourcePackages"
    state = json.loads((packages / "workspace-state.json").read_text())["object"]
    checked = []
    for dependency in state["dependencies"]:
        package = dependency["packageRef"]
        identity = package["identity"]
        assert package["kind"] == "remoteSourceControl", f"Nonremote dependency: {identity}"
        assert identity in expected, f"Unpinned dependency: {identity}"
        assert package["location"].startswith("https://"), f"Local repository mirror: {identity}"
        assert package["location"].removesuffix(".git").rstrip("/") == expected[identity]["location"].removesuffix(".git").rstrip("/"), f"Unexpected repository: {identity}"
        checkout = packages / "checkouts" / dependency["subpath"]
        revision = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
        assert revision == expected[identity]["state"]["revision"], f"Wrong checkout: {identity}"
        checked.append({"identity": identity, "revision": revision, "location": package["location"]})
    assert {item["identity"] for item in checked} == set(expected), "Incomplete package graph"
    core = next(packages / "checkouts" / d["subpath"] for d in state["dependencies"] if d["packageRef"]["identity"] == "catbirdmlscore")
    manifest = (core / "Package.swift").read_text()
    assert 'path: "Sources/CatbirdMLSFFI.xcframework"' not in manifest
    assert 'releases/download/v1.5.18/CatbirdMLSFFI.xcframework.zip' in manifest
    write("resolved-checkouts.json", checked)
    write("core-manifest.json", {"sha256": hashlib.sha256(manifest.encode()).hexdigest(), "published_binary": True})


def simulator():
    devices = json.loads((REPORTS / "simulators.json").read_text())["devices"]
    for runtime, candidates in sorted(devices.items(), reverse=True):
        for device in candidates:
            if "iOS" in runtime and device.get("isAvailable") and device["name"].startswith("iPhone"):
                (REPORTS / "simulator-id.txt").write_text(device["udid"] + "\n")
                write("selected-simulator.json", {"runtime": runtime, **device})
                return
    raise AssertionError("No available iPhone simulator")


def tests():
    def walk(value):
        if isinstance(value, dict):
            yield value
            for child in value.values():
                yield from walk(child)
        elif isinstance(value, list):
            for child in value:
                yield from walk(child)
    expected = json.loads((REPORTS / "expected-tests.json").read_text())
    cases = [node for node in walk(json.loads((REPORTS / "tests.json").read_text())) if node.get("nodeType") == "Test Case"]
    result = {}
    for suite in SUITES:
        selected = [case for case in cases if case.get("nodeIdentifier", "").startswith(f"{suite}/")]
        assert len(selected) == expected[suite], f"Incomplete executed suite: {suite}"
        assert len({case["nodeIdentifier"] for case in selected}) == expected[suite], f"Duplicate test result: {suite}"
        assert all(case.get("result") == "Passed" for case in selected), f"Nonpassing result: {suite}"
        result[suite] = len(selected)
    write("test-summary.json", {"passed": sum(result.values()), "suites": result})


if __name__ == "__main__":
    {"before": before, "resolved": resolved, "simulator": simulator, "tests": tests}[sys.argv[1]]()
