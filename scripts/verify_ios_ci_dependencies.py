"""Verify the pinned sibling package layout used by iOS CI, without changing it.

The workflow checks out the manifest revisions with actions/checkout. This helper
rejects drift before resolution, records the effective public native artifact,
and verifies the resolved graph against the app's committed Package.resolved.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / ".github/ci/ios-dependencies.json"
RESOLVED = ROOT / "Catbird.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
NAMES = {"Petrel", "PetrelCatbird", "CatbirdMLSCore"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def write(reports, name, value):
    reports.mkdir(parents=True, exist_ok=True)
    (reports / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def manifest():
    value = json.loads(MANIFEST.read_text())
    require(value["schemaVersion"] == 1, "Unsupported iOS dependency manifest")
    require(set(value["packages"]) == NAMES, "Expected exactly the three sibling packages")
    for name, package in value["packages"].items():
        require(package["repository"] == f"joshlacal/{name}", f"Unexpected repository for {name}")
        require(re.fullmatch(r"[0-9a-f]{40}", package["revision"]), f"A full immutable revision is required for {name}")
    artifact = value["nativeArtifact"]
    require(artifact["url"].startswith("https://github.com/joshlacal/CatbirdMLSCore/releases/download/"), "Expected a published native artifact")
    require(re.fullmatch(r"[0-9a-f]{64}", artifact["checksum"]), "Invalid native artifact checksum")
    return value


def checkouts(expected, reports):
    require(os.environ.get("CATBIRD_MLS_LOCAL_INTEGRATION") == "1", "CI must use the pinned sibling SDKs")
    require(not os.environ.get("CATBIRD_MLS_FFI_PATH"), "CI must use the published native artifact")
    project = (ROOT / "Catbird.xcodeproj/project.pbxproj").read_text()
    paths = set(re.findall(r"relativePath = \.\./([^;]+);", project))
    require(paths == NAMES, f"Project sibling paths differ from the manifest: {paths}")
    checked = {}
    for name, package in expected["packages"].items():
        path = ROOT.parent / name
        require(path.is_dir() and path.resolve() == path, f"Missing or symlinked sibling: {path}")
        revision = command("git", "-C", str(path), "rev-parse", "HEAD")
        require(revision == package["revision"], f"Wrong {name} revision: {revision}")
        origin = command("git", "-C", str(path), "remote", "get-url", "origin")
        require(origin.removesuffix(".git") == f'https://github.com/{package["repository"]}', f"Wrong {name} origin: {origin}")
        require(not command("git", "-C", str(path), "status", "--porcelain"), f"Modified sibling checkout: {name}")
        checked[name] = {**package, "packageManifestSHA256": sha256(path / "Package.swift")}

    # Confirm the wrappers' public SDK revisions agree even though this CI lane
    # uses exact sibling overrides. Never silently mix a feature SDK with main.
    for owner, dependencies in (("PetrelCatbird", ("Petrel",)), ("CatbirdMLSCore", ("Petrel", "PetrelCatbird"))):
        source = (ROOT.parent / owner / "Package.swift").read_text()
        for dependency in dependencies:
            package = expected["packages"][dependency]
            pattern = r'url:\s*"https://github.com/' + re.escape(package["repository"]) + r'(?:\.git)?",\s*revision:\s*"' + package["revision"] + '"'
            require(re.search(pattern, source), f"{owner}'s published {dependency} pin disagrees with CI")

    core = json.loads(command("swift", "package", "--package-path", str(ROOT.parent / "CatbirdMLSCore"), "dump-package"))
    targets = {target["name"]: target for target in core["targets"]}
    ffi = targets["CatbirdMLSFFI"]
    require(all(ffi.get(key) == value for key, value in expected["nativeArtifact"].items()), "Core did not select the pinned public native artifact")
    require(targets["CatbirdMLS"].get("path") == "Sources/CatbirdMLS", "Core selected incompatible Spaces bindings")
    require("CATBIRD_MLS_VERIFIED_SPACE_FFI" not in json.dumps(core), "Public native CI must not enable Spaces capability")
    write(reports, "dependencies-before-resolution.json", {
        "appRevision": command("git", "-C", str(ROOT), "rev-parse", "HEAD"),
        "dependencyManifestSHA256": sha256(MANIFEST),
        "packages": checked,
        "nativeArtifact": expected["nativeArtifact"],
        "resolvedPins": json.loads(RESOLVED.read_text())["pins"],
    })


def resolved(expected, reports, packages):
    before = json.loads((reports / "dependencies-before-resolution.json").read_text())
    pins = {pin["identity"]: pin for pin in before["resolvedPins"]}
    require(json.loads(RESOLVED.read_text())["pins"] == before["resolvedPins"], "Resolution changed the committed package pins")
    state = json.loads((packages / "workspace-state.json").read_text())["object"]
    seen = set()
    siblings = {name.lower(): name for name in NAMES}
    for dependency in state["dependencies"]:
        package = dependency["packageRef"]
        identity = package["identity"]
        require(identity not in seen, f"Duplicate resolved dependency: {identity}")
        seen.add(identity)
        if identity in siblings:
            path = ROOT.parent / siblings[identity]
            require(package["kind"] == "fileSystem" and Path(package["location"]) == path, f"Wrong sibling resolution: {identity}")
            require(command("git", "-C", str(path), "rev-parse", "HEAD") == expected["packages"][siblings[identity]]["revision"], f"Sibling moved during resolution: {identity}")
        else:
            require(identity in pins and package["kind"] == "remoteSourceControl", f"Unpinned dependency: {identity}")
            require(package["location"].removesuffix(".git") == pins[identity]["location"].removesuffix(".git"), f"Unexpected repository: {identity}")
            checkout = packages / "checkouts" / dependency["subpath"]
            require(command("git", "-C", str(checkout), "rev-parse", "HEAD") == pins[identity]["state"]["revision"], f"Wrong resolved revision: {identity}")
    require(seen == set(pins) | set(siblings), "Resolved graph is incomplete")
    ffi = [artifact for artifact in state["artifacts"] if artifact["packageRef"]["identity"] == "catbirdmlscore" and artifact["targetName"] == "CatbirdMLSFFI"]
    require(len(ffi) == 1, "Expected exactly one resolved MLS native artifact")
    require(ffi[0]["source"] == {"type": "remote", **expected["nativeArtifact"]}, "Resolved native artifact drifted")
    write(reports, "dependencies-after-resolution.json", state)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("manifest", "checkouts", "resolved"))
    parser.add_argument("--reports", type=Path)
    parser.add_argument("--source-packages", type=Path)
    args = parser.parse_args()
    expected = manifest()
    if args.stage == "manifest":
        for name, package in expected["packages"].items():
            print(f"{name.lower()}_revision={package['revision']}")
    else:
        require(args.reports is not None, "--reports is required")
        if args.stage == "checkouts":
            checkouts(expected, args.reports)
        else:
            require(args.source_packages is not None, "--source-packages is required")
            resolved(expected, args.reports, args.source_packages)


if __name__ == "__main__":
    main()
