#!/bin/zsh
# Xcode Cloud post-clone hook.
#
# Catbird.xcodeproj references four sibling Swift packages by relative path
# (../Petrel, ../PetrelCatbird, ../CatbirdMLSCore, ../CatbirdBrand). Xcode Cloud
# clones only this repository, so this script recreates the sibling layout next
# to $CI_PRIMARY_REPOSITORY_PATH before SPM dependency resolution runs.
#
# Environment (App Store Connect → Xcode Cloud → workflow → Environment):
#   GITHUB_PAT          REQUIRED for the private repos (PetrelCatbird,
#                       CatbirdBrand): fine-grained token with contents:read.
#                       Public repos clone without it.
# Optional per-workflow ref pins (default: main):
#   PETREL_REF, PETRELCATBIRD_REF, CATBIRDMLSCORE_REF, CATBIRDBRAND_REF
set -euo pipefail

SIBLINGS_DIR="$(dirname "$CI_PRIMARY_REPOSITORY_PATH")"

clone_sibling() {
  local repo="$1" ref="${2:-main}" visibility="${3:-public}" url
  if [[ -n "${GITHUB_PAT:-}" ]]; then
    url="https://x-access-token:${GITHUB_PAT}@github.com/joshlacal/${repo}.git"
  elif [[ "$visibility" == "private" ]]; then
    echo "error: ${repo} is a private repo and GITHUB_PAT is not set." >&2
    echo "Add GITHUB_PAT as a secret environment variable on this Xcode Cloud" >&2
    echo "workflow (fine-grained token, contents:read on joshlacal/${repo})." >&2
    exit 1
  else
    url="https://github.com/joshlacal/${repo}.git"
  fi
  echo "Cloning ${repo} @ ${ref}"
  git clone --quiet --depth 1 --branch "$ref" "$url" "${SIBLINGS_DIR}/${repo}"
}

clone_sibling Petrel         "${PETREL_REF:-main}"         public
clone_sibling CatbirdMLSCore "${CATBIRDMLSCORE_REF:-main}" public
clone_sibling CatbirdBrand   "${CATBIRDBRAND_REF:-main}"   private
clone_sibling PetrelCatbird  "${PETRELCATBIRD_REF:-main}"  private

# CatbirdMLSCore's binary target (Sources/CatbirdMLSFFI.xcframework) is
# gitignored; fetch it from the GitHub release (public).
cd "${SIBLINGS_DIR}/CatbirdMLSCore"
./Scripts/download-ffi.sh
