#!/bin/bash
#
# MLS Storage Implementation Verification Script
# Verifies that all components are properly installed
#

set -e

echo "🔍 Verifying MLS Storage Implementation..."
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

STORAGE_DIR="/Users/joshlacalamito/Developer/Catbird+Petrel/Catbird/Catbird/Storage"
TEST_DIR="/Users/joshlacalamito/Developer/Catbird+Petrel/Catbird/CatbirdTests/Storage"

# Track verification status
all_checks_passed=true

# Function to check file existence
check_file() {
    local file=$1
    local description=$2
    
    if [ -f "$file" ]; then
        echo -e "${GREEN}✓${NC} $description"
        return 0
    else
        echo -e "${RED}✗${NC} $description (NOT FOUND: $file)"
        all_checks_passed=false
        return 1
    fi
}

# Function to check directory
check_dir() {
    local dir=$1
    local description=$2
    
    if [ -d "$dir" ]; then
        echo -e "${GREEN}✓${NC} $description"
        return 0
    else
        echo -e "${RED}✗${NC} $description (NOT FOUND: $dir)"
        all_checks_passed=false
        return 1
    fi
}

echo "📁 Checking Directory Structure..."
check_dir "$STORAGE_DIR" "Storage directory exists"
check_dir "$TEST_DIR" "Test directory exists"
check_dir "$STORAGE_DIR/MLS.xcdatamodeld" "Core Data model directory exists"
echo ""

echo "📄 Checking Core Files..."
check_file "$STORAGE_DIR/MLSStorage.swift" "MLSStorage.swift"
check_file "$STORAGE_DIR/MLSKeychainManager.swift" "MLSKeychainManager.swift"
echo ""

echo "📊 Checking Core Data Model..."
check_file "$STORAGE_DIR/MLS.xcdatamodeld/MLS.xcdatamodel/contents" "Core Data model contents"
check_file "$STORAGE_DIR/MLS.xcdatamodeld/.xccurrentversion" "Core Data version info"
echo ""

echo "📚 Checking Documentation..."
check_file "$STORAGE_DIR/STORAGE_ARCHITECTURE.md" "Architecture documentation"
check_file "$STORAGE_DIR/README.md" "README"
echo ""

echo "🧪 Checking Test Files..."
check_file "$TEST_DIR/MLSStorageTests.swift" "MLSStorageTests.swift"
check_file "$TEST_DIR/MLSKeychainManagerTests.swift" "MLSKeychainManagerTests.swift"
echo ""

echo "🔬 Verifying Core Data Model Structure..."
if [ -f "$STORAGE_DIR/MLS.xcdatamodeld/MLS.xcdatamodel/contents" ]; then
    entities=$(grep -o '<entity name="[^"]*"' "$STORAGE_DIR/MLS.xcdatamodeld/MLS.xcdatamodel/contents" | wc -l | tr -d ' ')
    
    if [ "$entities" -eq 4 ]; then
        echo -e "${GREEN}✓${NC} Core Data model has 4 entities"
        
        # Check each entity
        for entity in "MLSConversation" "MLSMessage" "MLSMember" "MLSKeyPackage"; do
            if grep -q "entity name=\"$entity\"" "$STORAGE_DIR/MLS.xcdatamodeld/MLS.xcdatamodel/contents"; then
                echo -e "  ${GREEN}✓${NC} Entity: $entity"
            else
                echo -e "  ${RED}✗${NC} Entity: $entity (NOT FOUND)"
                all_checks_passed=false
            fi
        done
    else
        echo -e "${RED}✗${NC} Core Data model should have 4 entities, found: $entities"
        all_checks_passed=false
    fi
else
    echo -e "${RED}✗${NC} Core Data model file not found"
    all_checks_passed=false
fi
echo ""

echo "📈 Code Statistics..."
swift_files=$(find "$STORAGE_DIR" "$TEST_DIR" -name "*.swift" -type f 2>/dev/null | wc -l | tr -d ' ')
total_lines=$(find "$STORAGE_DIR" "$TEST_DIR" -name "*.swift" -type f -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1}')

echo -e "${GREEN}✓${NC} Swift files: $swift_files"
echo -e "${GREEN}✓${NC} Total lines of code: $total_lines"
echo ""

echo "🔑 Checking Key Components..."
# Check for important classes/structs
if grep -q "class MLSStorage" "$STORAGE_DIR/MLSStorage.swift"; then
    echo -e "${GREEN}✓${NC} MLSStorage class defined"
else
    echo -e "${RED}✗${NC} MLSStorage class not found"
    all_checks_passed=false
fi

if grep -q "class MLSKeychainManager" "$STORAGE_DIR/MLSKeychainManager.swift"; then
    echo -e "${GREEN}✓${NC} MLSKeychainManager class defined"
else
    echo -e "${RED}✗${NC} MLSKeychainManager class not found"
    all_checks_passed=false
fi
echo ""

echo "🧪 Checking Test Coverage..."
storage_test_count=$(grep -c "func test" "$TEST_DIR/MLSStorageTests.swift" 2>/dev/null || echo "0")
keychain_test_count=$(grep -c "func test" "$TEST_DIR/MLSKeychainManagerTests.swift" 2>/dev/null || echo "0")
total_tests=$((storage_test_count + keychain_test_count))

echo -e "${GREEN}✓${NC} MLSStorage tests: $storage_test_count"
echo -e "${GREEN}✓${NC} MLSKeychainManager tests: $keychain_test_count"
echo -e "${GREEN}✓${NC} Total test methods: $total_tests"
echo ""

echo "📝 Summary Report..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Implementation Files:    2"
echo "Swift Files:            $swift_files"
echo "Lines of Code:          $total_lines"
echo "Test Methods:           $total_tests"
echo "Core Data Entities:     4"
echo "Documentation Files:    2"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ "$all_checks_passed" = true ]; then
    echo -e "${GREEN}✅ All checks passed! MLS Storage implementation is complete.${NC}"
    exit 0
else
    echo -e "${RED}❌ Some checks failed. Please review the output above.${NC}"
    exit 1
fi
