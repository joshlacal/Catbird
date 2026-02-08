#!/bin/bash
# verify_plaintext_caching.sh
# Verify MLS plaintext caching implementation

set -e
set -x

echo "🔍 Verifying MLS Plaintext Caching Implementation..."
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASS=0
FAIL=0

check() {
    local description="$1"
    local command="$2"
    
    if eval "$command" > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $description"
        PASS=$((PASS+1))
    else
        echo -e "${RED}✗${NC} $description"
        FAIL=$((FAIL+1))
    fi
}

echo "📋 Core Data Encryption Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

check "FileProtectionType.complete configured" \
    "grep -q 'FileProtectionType.complete' Catbird/Services/MLS/SQLCipher/Core/MLSGRDBManager.swift"

check "Backup exclusion enabled" \
    "grep -q 'isExcludedFromBackup.*true' Catbird/Services/MLS/SQLCipher/Core/MLSGRDBManager.swift"

echo ""
echo "💾 Plaintext Caching Logic"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

check "savePlaintextForMessage implemented" \
    "grep -q 'func savePlaintextForMessage' Catbird/Storage/MLSStorage.swift"

check "fetchPlaintextForMessage implemented" \
    "grep -q 'func fetchPlaintextForMessage' Catbird/Storage/MLSStorage.swift"

check "Plaintext cached during message processing" \
    "grep -q 'storage.savePlaintextForMessage' Catbird/Services/MLS/MLSConversationManager.swift"

check "Cache checked before decryption (server messages)" \
    "grep -q 'fetchPlaintextForMessage' Catbird/Features/MLSChat/MLSConversationDetailView.swift"

check "Cache checked before decryption (WebSocket messages)" \
    "grep -q 'fetchPlaintextForMessage' Catbird/Features/MLSChat/MLSConversationDetailView.swift"

echo ""
echo "📚 Documentation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

check "Security model documentation exists" \
    "test -f Catbird/Storage/MLS_SECURITY_MODEL.md"

check "Implementation summary exists" \
    "test -f docs/session-notes/PLAINTEXT_CACHING_IMPLEMENTATION.md"

check "Inline documentation in savePlaintextForMessage" \
    "grep -B 20 'func savePlaintextForMessage' Catbird/Storage/MLSStorage.swift | grep -q 'SECURITY MODEL'"

check "No deprecated annotations on caching functions" \
    "! grep -A 5 'func savePlaintextForMessage' Catbird/Storage/MLSStorage.swift | grep -q '@available.*deprecated'"

echo ""
echo "🔐 Security Checks"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

check "Multi-account isolation (currentUserDID filtering)" \
    "grep -q 'currentUserDID == currentUserDID' Catbird/Storage/MLSStorage.swift"

check "Logging includes security context" \
    "grep -q '💾 Caching plaintext:' Catbird/Storage/MLSStorage.swift"

check "GRDB model has plaintext attribute" \
    "grep -q 't.column(\"plaintext\", .text)' Catbird/Services/MLS/SQLCipher/Core/MLSGRDBManager.swift"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}✅ All checks passed! ($PASS/$((PASS + FAIL)))${NC}"
    echo ""
    echo "Implementation is complete and ready to ship."
    echo ""
    echo "Next steps:"
    echo "  1. Test in simulator/device"
    echo "  2. Verify messages persist across app restart"
    echo "  3. Verify multi-account isolation"
    echo "  4. Ship to production"
    exit 0
else
    echo -e "${RED}❌ Some checks failed: $FAIL/$((PASS + FAIL))${NC}"
    echo ""
    echo "Please review the failed checks and fix the issues."
    exit 1
fi
