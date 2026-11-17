#!/bin/bash
set -euo pipefail

# Compile the Foundation-only deletion state/sequence boundary and provider resolver.
# Runtime CatbirdMLS/Petrel adapters stay in the app target and are covered by CatbirdTests.
# No application, simulator, package download, account API, or real URL opener runs.
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_root="${1:-$(mktemp -d "${TMPDIR:-/tmp}/catbird-account-deletion.XXXXXX")}"
mkdir -p "$test_root/Sources/Catbird" "$test_root/Tests/CatbirdTests" "$test_root/module-cache"
cp "$repo_root/Catbird/Features/Settings/Models/AccountDeletionDomain.swift" "$test_root/Sources/Catbird/"
cp "$repo_root/Catbird/Features/Settings/Models/AccountManagementPageResolver.swift" "$test_root/Sources/Catbird/"
cp "$repo_root/CatbirdTests/AccountDeletionDomainTests.swift" "$test_root/Tests/CatbirdTests/"
cat > "$test_root/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "AccountDeletionIsolation",
  platforms: [.macOS(.v13)],
  targets: [
    .target(name: "Catbird"),
    .testTarget(name: "CatbirdTests", dependencies: ["Catbird"])
  ]
)
SWIFT
CLANG_MODULE_CACHE_PATH="$test_root/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$test_root/module-cache" \
swift test --package-path "$test_root" --scratch-path "$test_root/.build" --disable-sandbox --build-system native --jobs 2
