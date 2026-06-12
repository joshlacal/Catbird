#!/bin/zsh
# Xcode Cloud post-clone hook.
#
# Catbird.xcodeproj references four sibling Swift packages by relative path
# (../Petrel, ../PetrelCatbird, ../CatbirdMLSCore, ../CatbirdBrand). Xcode Cloud
# clones only this repository, so this script recreates the sibling layout next
# to $CI_PRIMARY_REPOSITORY_PATH before SPM dependency resolution runs.
#
# Requirements (App Store Connect → Xcode Cloud → workflow environment):
#   GITHUB_PAT          fine-grained token, contents:read on the private repos
#                       (PetrelCatbird, CatbirdBrand); public repos work without
#                       it but the single URL form keeps the script uniform.
# Optional per-workflow ref pins (default: main):
#   PETREL_REF, PETRELCATBIRD_REF, CATBIRDMLSCORE_REF, CATBIRDBRAND_REF
set -euo pipefail

SIBLINGS_DIR="$(dirname "$CI_PRIMARY_REPOSITORY_PATH")"

clone_sibling() {
  local repo="$1" ref="${2:-main}"
  echo "Cloning ${repo} @ ${ref}"
  git clone --depth 1 --branch "$ref" \
    "https://x-access-token:${GITHUB_PAT}@github.com/joshlacal/${repo}.git" \
    "${SIBLINGS_DIR}/${repo}"
}

clone_sibling Petrel         "${PETREL_REF:-main}"
clone_sibling PetrelCatbird  "${PETRELCATBIRD_REF:-main}"
clone_sibling CatbirdMLSCore "${CATBIRDMLSCORE_REF:-main}"
clone_sibling CatbirdBrand   "${CATBIRDBRAND_REF:-main}"

# CatbirdMLSCore's binary target (Sources/CatbirdMLSFFI.xcframework) is
# gitignored; fetch it from the GitHub release.
cd "${SIBLINGS_DIR}/CatbirdMLSCore"
./Scripts/download-ffi.sh
