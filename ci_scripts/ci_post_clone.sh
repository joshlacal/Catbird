#!/bin/bash
# Xcode Cloud post-clone hook.
#
# Catbird.xcodeproj references three sibling Swift packages by relative path
# (../Petrel, ../PetrelCatbird, ../CatbirdMLSCore). Xcode Cloud clones only this
# repository, so this script recreates that sibling layout next to
# $CI_PRIMARY_REPOSITORY_PATH before Swift package resolution runs.
#
# Each sibling is checked out at the exact 40-character revision recorded in
# .github/ci/ios-dependencies.json, the same manifest the GitHub Actions iOS
# workflow uses. All three repositories are public, so no credentials are used.
#
# The CatbirdMLSFFI binary target is a remote, checksummed artifact on the
# public CatbirdMLSCore release (nativeArtifact in the manifest), which Swift
# Package Manager downloads itself; nothing extra is fetched here.
set -euo pipefail

: "${CI_PRIMARY_REPOSITORY_PATH:?CI_PRIMARY_REPOSITORY_PATH must be set (Xcode Cloud provides it)}"

REPO_ROOT="$CI_PRIMARY_REPOSITORY_PATH"
SIBLINGS_DIR="$(dirname "$REPO_ROOT")"
MANIFEST="$REPO_ROOT/.github/ci/ios-dependencies.json"
VERIFIER="$REPO_ROOT/scripts/verify_ios_ci_dependencies.py"
PACKAGES=(Petrel PetrelCatbird CatbirdMLSCore)

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ -f "$MANIFEST" ]] || fail "missing dependency manifest: $MANIFEST"
[[ -f "$VERIFIER" ]] || fail "missing manifest verifier: $VERIFIER"

# Reuse the GitHub Actions parser: it validates the schema, the exact package
# set, each repository name and each full revision, then prints
# "<lowercased name>_revision=<sha>" lines.
manifest_output="$(python3 "$VERIFIER" manifest)" || fail "dependency manifest failed validation"

# Every sibling the project references by relative path must be in the manifest.
project_paths="$(sed -n 's/.*relativePath = \.\.\/\([^;]*\);.*/\1/p' "$REPO_ROOT/Catbird.xcodeproj/project.pbxproj" | sort -u | tr '\n' ' ')"
expected_paths="$(printf '%s\n' "${PACKAGES[@]}" | sort -u | tr '\n' ' ')"
[[ "$project_paths" == "$expected_paths" ]] ||
  fail "project sibling paths ($project_paths) differ from the CI package set ($expected_paths)"

revision_for() {
  local key line
  key="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')_revision"
  line="$(printf '%s\n' "$manifest_output" | grep -E "^${key}=" || true)"
  [[ -n "$line" ]] || fail "no revision for $1 in the manifest"
  printf '%s' "${line#*=}"
}

checkout_sibling() {
  local name="$1" revision="$2" dest url actual
  dest="$SIBLINGS_DIR/$name"
  url="https://github.com/joshlacal/${name}.git"

  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || fail "$name revision is not a full 40-character SHA: $revision"

  if [[ -e "$dest" ]]; then
    # Accept an existing checkout only if it is already exactly right.
    actual="$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)"
    [[ "$actual" == "$revision" ]] ||
      fail "$dest already exists at '${actual:-not a git checkout}', expected $revision"
    [[ -z "$(git -C "$dest" status --porcelain)" ]] || fail "$dest has local modifications"
    echo "$name already at $revision"
    return
  fi

  echo "Fetching $name @ $revision"
  git init --quiet "$dest"
  git -C "$dest" remote add origin "$url"
  git -C "$dest" fetch --quiet --depth 1 origin "$revision" ||
    fail "could not fetch $name revision $revision from $url"
  git -C "$dest" -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD

  actual="$(git -C "$dest" rev-parse HEAD)"
  [[ "$actual" == "$revision" ]] || fail "$name checked out $actual, expected $revision"
  [[ -f "$dest/Package.swift" ]] || fail "$name has no Package.swift at $revision"
}

for name in "${PACKAGES[@]}"; do
  checkout_sibling "$name" "$(revision_for "$name")"
done

echo "Sibling packages ready in $SIBLINGS_DIR:"
for name in "${PACKAGES[@]}"; do
  echo "  $name $(git -C "$SIBLINGS_DIR/$name" rev-parse HEAD)"
done
