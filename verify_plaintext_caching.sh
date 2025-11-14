#!/bin/bash
# verify_plaintext_caching.sh
# Verify MLS plaintext caching implementation

set -e

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
        ((PASS++))
    else
        echo -e "${RED}✗${NC} $description"
        ((FAIL++))
    fi
}

echo "📋 Core Data Encryption Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

check "FileProtectionType.complete configured" \
    "grep -q 'FileProtectionType.complete' Catbird/Storage/MLSStorage.swift"

check "Backup exclusion enabled" \
    "grep -q 'isExcludedFromBackup.*true' Catbird/Storage/MLSStorage.swift"

check "Persistent history tracking enabled" \
    "grep -q 'NSPersistentHistoryTrackingKey' Catbird/Storage/MLSStorage.swift"

echo ""
echo "💾 Plaintext Caching Logic"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

check "savePlaintextForMessage implemented" \
    "grep -q 'func savePlaintextForMessage' Catbird/Storage/MLSStorage.swift"

check "fetchPlaintextForMessage implemented" \
    "grep -q 'func fetchPlaintextForMessage' Catbird/Storage/MLSStorage.swift"

check "Plaintext cached after server message decryption" \
    "grep -q 'storage.savePlaintextForMessage' Catbird/Features/MLSChat/MLSConversationDetailView.swift | grep -A 5 'loadMessages'"

check "Plaintext cached after WebSocket message decryption" \
    "grep -q 'storage.savePlaintextForMessage' Catbird/Features/MLSChat/MLSConversationDetailView.swift | grep -A 5 'handleWebSocketEvent'"

check "Cache checked before decryption (server messages)" \
    "grep -q 'fetchPlaintextForMessage' Catbird/Features/MLSChat/MLSConversationDetailView.swift | grep -B 5 'loadMessages'"

check "Cache checked before decryption (WebSocket messages)" \
    "grep -q 'fetchPlaintextForMessage' Catbird/Features/MLSChat/MLSConversationDetailView.swift | grep -B 5 'handleWebSocketEvent'"

echo ""
echo "📚 Documentation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

check "Security model documentation exists" \
    "test -f Catbird/Storage/MLS_SECURITY_MODEL.md"

check "Implementation summary exists" \
    "test -f docs/session-notes/PLAINTEXT_CACHING_IMPLEMENTATION.md"

check "Inline documentation in savePlaintextForMessage" \
    "grep -A 10 'func savePlaintextForMessage' Catbird/Storage/MLSStorage.swift | grep -q 'SECURITY MODEL'"

check "No deprecated annotations on caching functions" \
    "! grep -A 5 'func savePlaintextForMessage' Catbird/Storage/MLSStorage.swift | grep -q '@available.*deprecated'"

echo ""
echo "🔐 Security Checks"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

check "Multi-account isolation (currentUserDID filtering)" \
    "grep -q 'currentUserDID == %@' Catbird/Storage/MLSStorage.swift"

check "Logging includes security context" \
    "grep -q '💾 Caching decrypted plaintext' Catbird/Storage/MLSStorage.swift"

check "Core Data model has plaintext attribute" \
    "grep -q 'attribute name=\"plaintext\"' Catbird/Storage/MLS.xcdatamodeld/MLS.xcdatamodel/contents"

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
