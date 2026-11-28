#!/usr/bin/env bash
# Unified Catbird design-system linter entrypoint.
#
# Runs BOTH:
#   1. SwiftLint strict design-only config (`.swiftlint-design.yml`)
#   2. SwiftSyntax AST linter (`tools/design-lint`)
# and enforces the monotonic per-(file, rule) budget (`.design-lint-budget.json`).
#
# Usage:
#   ./scripts/design_lint.sh                      # Full repo + strict monotonic ratchet (--check-ratchet)
#   ./scripts/design_lint.sh --check-ratchet      # Same as default
#   ./scripts/design_lint.sh --file <path> [...]  # Single/multi-file fast check (hooks)
#   ./scripts/design_lint.sh --diff [base-ref]    # Changed Swift files vs base (pre-push / Xcode)
#   ./scripts/design_lint.sh --write-budget       # Regenerate sorted .design-lint-budget.json
#   ./scripts/design_lint.sh --diff-budgets A B   # Compare two budget files for ceiling increases
#   ./scripts/design_lint.sh --no-budget --file X # Zero-tolerance check ignoring budget
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFTLINT_CONFIG="$REPO_ROOT/.swiftlint-design.yml"
BUDGET_FILE="$REPO_ROOT/.design-lint-budget.json"
TOOL_DIR="$REPO_ROOT/tools/design-lint"

MODE="full"
CHECK_RATCHET=1
USE_BUDGET=1
JSON_OUT=0
DIFF_BASE="main"
TARGET_FILES=()
DIFF_BUDGET_A=""
DIFF_BUDGET_B=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-ratchet)
      MODE="full"
      CHECK_RATCHET=1
      shift
      ;;
    --write-budget)
      MODE="write-budget"
      shift
      ;;
    --file)
      MODE="files"
      CHECK_RATCHET=0
      shift
      [[ $# -gt 0 ]] || { echo "error: --file requires a path" >&2; exit 2; }
      TARGET_FILES+=("$1")
      shift
      ;;
    --diff)
      MODE="diff"
      CHECK_RATCHET=0
      shift
      if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
        DIFF_BASE="$1"
        shift
      fi
      ;;
    --diff-budgets)
      MODE="diff-budgets"
      shift
      [[ $# -ge 2 ]] || { echo "error: --diff-budgets requires <base> <head>" >&2; exit 2; }
      DIFF_BUDGET_A="$1"
      DIFF_BUDGET_B="$2"
      shift 2
      ;;
    --no-budget)
      USE_BUDGET=0
      shift
      ;;
    --json)
      JSON_OUT=1
      shift
      ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    *)
      echo "error: unknown option '$1'" >&2
      exit 2
      ;;
  esac
done

ensure_design_lint_bin() {
  if [[ -n "${DESIGN_LINT_BIN:-}" && -x "$DESIGN_LINT_BIN" ]]; then
    printf '%s' "$DESIGN_LINT_BIN"
    return 0
  fi

  local release_bin="$TOOL_DIR/.build/release/design-lint"
  local debug_bin="$TOOL_DIR/.build/debug/design-lint"
  local bin="$debug_bin"
  local build_config="debug"

  # Prefer an up-to-date release binary when available or requested; otherwise use debug for fast cold builds.
  if [[ "${DESIGN_LINT_FORCE_RELEASE:-0}" == "1" ]]; then
    bin="$release_bin"
    build_config="release"
  elif [[ -x "$release_bin" ]]; then
    bin="$release_bin"
    build_config="release"
  fi

  local needs_build=0
  if [[ ! -x "$bin" ]]; then
    needs_build=1
  elif find "$TOOL_DIR/Package.swift" "$TOOL_DIR/Sources" -type f -newer "$bin" 2>/dev/null | grep -q .; then
    needs_build=1
  fi

  if [[ "$needs_build" -eq 1 ]]; then
    echo "Building tools/design-lint ($build_config)..." >&2
    (cd "$TOOL_DIR" && swift build -c "$build_config" --product design-lint >/dev/null)
    bin="$TOOL_DIR/.build/$build_config/design-lint"
  fi

  printf '%s' "$bin"
}

DESIGN_LINT_EXE="$(ensure_design_lint_bin)"

if [[ "$MODE" == "diff-budgets" ]]; then
  if [[ "$JSON_OUT" -eq 1 ]]; then
    exec "$DESIGN_LINT_EXE" --diff-budgets "$DIFF_BUDGET_A" "$DIFF_BUDGET_B" --json
  else
    exec "$DESIGN_LINT_EXE" --diff-budgets "$DIFF_BUDGET_A" "$DIFF_BUDGET_B"
  fi
fi

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "error: swiftlint not found on PATH (install via 'brew install swiftlint')" >&2
  exit 2
fi

if [[ ! -f "$SWIFTLINT_CONFIG" ]]; then
  echo "error: missing $SWIFTLINT_CONFIG" >&2
  exit 2
fi

# Resolve diff file list if --diff requested.
if [[ "$MODE" == "diff" ]]; then
  changed_raw=""
  if command -v jj >/dev/null 2>&1 && [[ -d "$REPO_ROOT/.jj" ]]; then
    # Changed files relative to base bookmark if resolvable, else working-copy diff.
    if jj -R "$REPO_ROOT" log -r "$DIFF_BASE" --no-graph -T 'commit_id' >/dev/null 2>&1; then
      changed_raw="$(jj -R "$REPO_ROOT" diff --from "$DIFF_BASE" --to @ --name-only 2>/dev/null || true)"
    else
      changed_raw="$(jj -R "$REPO_ROOT" diff --name-only 2>/dev/null || true)"
    fi
  else
    changed_raw="$(
      {
        git -C "$REPO_ROOT" diff --name-only --diff-filter=ACMR "$DIFF_BASE"...HEAD 2>/dev/null || true
        git -C "$REPO_ROOT" diff --name-only --diff-filter=ACMR 2>/dev/null || true
        git -C "$REPO_ROOT" ls-files --others --exclude-standard 2>/dev/null || true
      } | sort -u
    )"
  fi

  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    [[ "$rel" == *.swift ]] || continue
    case "$rel" in
      Catbird/*|CatbirdFeedWidget/*|CatbirdNotificationWidget/*|NotificationServiceExtension/*|SharedDraftImporter/*)
        [[ -f "$REPO_ROOT/$rel" ]] && TARGET_FILES+=("$REPO_ROOT/$rel")
        ;;
    esac
  done <<< "$changed_raw"

  if [[ ${#TARGET_FILES[@]} -eq 0 ]]; then
    echo "design-lint: PASS (no changed Swift UI target files vs $DIFF_BASE)."
    exit 0
  fi
fi

# Normalize --file paths and filter out non-existent/non-Swift files.
NORMALIZED_FILES=()
if [[ "$MODE" == "files" || "$MODE" == "diff" ]]; then
  for f in "${TARGET_FILES[@]}"; do
    if [[ "$f" != /* ]]; then
      f="$REPO_ROOT/$f"
    fi
    [[ -f "$f" && "$f" == *.swift ]] || continue
    NORMALIZED_FILES+=("$f")
  done
  if [[ ${#NORMALIZED_FILES[@]} -eq 0 ]]; then
    echo "design-lint: PASS (no lintable Swift files in target set)."
    exit 0
  fi
fi

TMP_SL_JSON="$(mktemp "${TMPDIR:-/tmp}/catbird-swiftlint-design.XXXXXX")"
TMP_SL_ERR="$(mktemp "${TMPDIR:-/tmp}/catbird-swiftlint-err.XXXXXX")"
trap 'rm -f "$TMP_SL_JSON" "$TMP_SL_ERR"' EXIT

# 1. Run SwiftLint strict design config and capture JSON violations.
#    Note: SwiftLint exits 2 when any `severity: error` violation is present;
#    exits 1 with "No lintable files found" when every --file target is in `excluded` (e.g. Core/UI/Kit/).
sl_rc=0
if [[ "$MODE" == "files" || "$MODE" == "diff" ]]; then
  (cd "$REPO_ROOT" && swiftlint lint --config "$SWIFTLINT_CONFIG" --strict --force-exclude --reporter json --quiet "${NORMALIZED_FILES[@]}" > "$TMP_SL_JSON" 2> "$TMP_SL_ERR") || sl_rc=$?
else
  (cd "$REPO_ROOT" && swiftlint lint --config "$SWIFTLINT_CONFIG" --strict --reporter json --quiet > "$TMP_SL_JSON" 2> "$TMP_SL_ERR") || sl_rc=$?
fi

if [[ "$sl_rc" -eq 1 ]] && grep -q "No lintable files found" "$TMP_SL_ERR"; then
  printf '[]\n' > "$TMP_SL_JSON"
  sl_rc=0
elif [[ "$sl_rc" -ne 0 && "$sl_rc" -ne 2 ]]; then
  echo "error: swiftlint failed with exit code $sl_rc" >&2
  cat "$TMP_SL_ERR" >&2
  cat "$TMP_SL_JSON" >&2
  exit "$sl_rc"
fi
if [[ ! -s "$TMP_SL_JSON" ]]; then
  printf '[]\n' > "$TMP_SL_JSON"
fi

# 2. Run SwiftSyntax AST design-lint + unified monotonic ratchet.
DL_ARGS=(--root "$REPO_ROOT" --swiftlint-json "$TMP_SL_JSON")
[[ "$JSON_OUT" -eq 1 ]] && DL_ARGS+=(--json)

if [[ "$MODE" == "write-budget" ]]; then
  DL_ARGS+=(--write-budget "$BUDGET_FILE")
  exec "$DESIGN_LINT_EXE" "${DL_ARGS[@]}"
fi

if [[ "$MODE" == "files" || "$MODE" == "diff" ]]; then
  for f in "${NORMALIZED_FILES[@]}"; do
    DL_ARGS+=(--file "$f")
  done
fi

if [[ "$USE_BUDGET" -eq 1 ]]; then
  if [[ ! -f "$BUDGET_FILE" ]]; then
    echo "error: missing budget file $BUDGET_FILE (generate with ./scripts/design_lint.sh --write-budget)" >&2
    exit 2
  fi
  DL_ARGS+=(--budget "$BUDGET_FILE")
  if [[ "$CHECK_RATCHET" -eq 1 ]]; then
    DL_ARGS+=(--check-ratchet)
  fi
else
  DL_ARGS+=(--fail-on-any)
fi

exec "$DESIGN_LINT_EXE" "${DL_ARGS[@]}"
