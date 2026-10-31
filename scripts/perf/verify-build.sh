#!/bin/bash
# verify-build.sh - Verify a binary or app bundle has no code-coverage instrumentation.
# Usage: ./verify-build.sh <path-to-app-or-binary>
#
# Exits with 0 if no __llvm_prf or __llvm_covmap sections are found.
# Exits with 1 if coverage sections are found in the main binary or any embedded .appex/.framework.
# Compatible with bash 3.2+.

set -eu

if [ $# -lt 1 ]; then
  echo "Usage: $0 <path-to-app-or-binary>" >&2
  exit 1
fi

TARGET="$1"

if [ ! -e "$TARGET" ]; then
  echo "Error: Target not found at '$TARGET'" >&2
  exit 1
fi

FAILURES=0
CHECKED_COUNT=0

check_single_binary() {
  local binary="$1"

  if [ ! -f "$binary" ]; then
    return 0
  fi

  # Skip symlinks
  if [ -L "$binary" ]; then
    return 0
  fi

  # Verify file is a Mach-O binary
  if ! file "$binary" 2>/dev/null | grep -q "Mach-O"; then
    return 0
  fi

  CHECKED_COUNT=$((CHECKED_COUNT + 1))

  # Check with size -m
  local size_matches
  size_matches=$(size -m "$binary" 2>/dev/null | grep -E "(__llvm_prf|__llvm_covmap)" || true)
  if [ -n "$size_matches" ]; then
    echo "❌ FAILED: Coverage section found in $binary (size -m):" >&2
    echo "$size_matches" | sed 's/^/    /' >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi

  # Check with otool -l
  local otool_matches
  otool_matches=$(otool -l "$binary" 2>/dev/null | grep -E "sectname (__llvm_prf|__llvm_covmap)" || true)
  if [ -n "$otool_matches" ]; then
    echo "❌ FAILED: Coverage section found in $binary (otool -l):" >&2
    echo "$otool_matches" | sed 's/^/    /' >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi

  echo "  ✓ Clean: $binary"
  return 0
}

echo "=== Verifying build for coverage instrumentation ==="
echo "Target: $TARGET"

if [ -f "$TARGET" ]; then
  # Direct binary file check
  check_single_binary "$TARGET" || true
elif [ -d "$TARGET" ]; then
  # Directory/bundle check (e.g. .app, .appex, .framework)
  # 1. Main executable if bundle
  if [ -f "$TARGET/Info.plist" ]; then
    BUNDLE_EXEC=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$TARGET/Info.plist" 2>/dev/null || true)
    if [ -n "$BUNDLE_EXEC" ] && [ -f "$TARGET/$BUNDLE_EXEC" ]; then
      check_single_binary "$TARGET/$BUNDLE_EXEC" || true
    fi
  fi

  # 2. Find all Mach-O files in the bundle (covers appex, frameworks, dylibs, helper binaries)
  while IFS= read -r candidate; do
    # Skip if we already checked the main bundle exec
    if [ -n "${BUNDLE_EXEC:-}" ] && [ "$candidate" = "$TARGET/$BUNDLE_EXEC" ]; then
      continue
    fi
    check_single_binary "$candidate" || true
  done < <(find "$TARGET" -type f \( -perm +111 -o -name "*.dylib" -o -name "*.framework" -o -name "*.appex" \) 2>/dev/null)
fi

echo "Checked $CHECKED_COUNT Mach-O binary/binaries."

if [ "$FAILURES" -gt 0 ]; then
  echo "❌ Verification failed: $FAILURES binary/binaries have coverage instrumentation!" >&2
  exit 1
fi

if [ "$CHECKED_COUNT" -eq 0 ]; then
  echo "⚠️ Warning: No Mach-O binaries found to verify in '$TARGET'." >&2
  exit 1
fi

echo "✅ Build verified clean: No coverage instrumentation found."
exit 0
