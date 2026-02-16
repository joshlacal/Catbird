#!/usr/bin/env bash
set -euo pipefail

# Entitlement Audit Script
# Checks that only expected app groups and keychain access groups are configured.
# Run from repo root: ./scripts/audit_entitlements.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="$REPO_ROOT"

# Expected values (add new ones here when intentionally adding entitlements)
ALLOWED_APP_GROUPS=(
    "group.blue.catbird.shared"
)
ALLOWED_KEYCHAIN_GROUPS=(
    '$(AppIdentifierPrefix)blue.catbird'
    '$(AppIdentifierPrefix)blue.catbird.shared'
)

ERRORS=0

echo "Auditing entitlements in $TARGET_DIR"

# Find all entitlements files
ENTITLEMENT_FILES=$(find "$TARGET_DIR" -name "*.entitlements" -type f 2>/dev/null)

if [ -z "$ENTITLEMENT_FILES" ]; then
    echo "No entitlements files found"
    exit 1
fi

for file in $ENTITLEMENT_FILES; do
    rel_path="${file#$REPO_ROOT/}"
    echo "Checking: $rel_path"

    # Extract app groups using PlistBuddy
    app_groups=$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups" "$file" 2>/dev/null || echo "")

    if [ -n "$app_groups" ]; then
        while IFS= read -r group; do
            group=$(echo "$group" | xargs)
            if [ -z "$group" ] || [ "$group" = "Array {" ] || [ "$group" = "}" ]; then
                continue
            fi

            found=0
            for allowed in "${ALLOWED_APP_GROUPS[@]}"; do
                if [ "$group" = "$allowed" ]; then
                    found=1
                    break
                fi
            done

            if [ "$found" -eq 0 ]; then
                echo "  UNEXPECTED app group: $group"
                ERRORS=$((ERRORS + 1))
            else
                echo "  App group ok: $group"
            fi
        done <<< "$app_groups"
    fi

    # Extract keychain access groups
    keychain_groups=$(/usr/libexec/PlistBuddy -c "Print :keychain-access-groups" "$file" 2>/dev/null || echo "")

    if [ -n "$keychain_groups" ]; then
        while IFS= read -r group; do
            group=$(echo "$group" | xargs)
            if [ -z "$group" ] || [ "$group" = "Array {" ] || [ "$group" = "}" ]; then
                continue
            fi

            found=0
            for allowed in "${ALLOWED_KEYCHAIN_GROUPS[@]}"; do
                if [ "$group" = "$allowed" ]; then
                    found=1
                    break
                fi
            done

            if [ "$found" -eq 0 ]; then
                echo "  UNEXPECTED keychain group: $group"
                ERRORS=$((ERRORS + 1))
            else
                echo "  Keychain group ok: $group"
            fi
        done <<< "$keychain_groups"
    fi

done

if [ "$ERRORS" -gt 0 ]; then
    echo "FAILED: $ERRORS unexpected entitlement(s) found"
    exit 1
fi

echo "PASSED: All entitlements match the allowlist"
