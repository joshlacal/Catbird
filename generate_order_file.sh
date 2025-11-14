#!/bin/bash

# Simple Order File Generation for Simulator Only
# This avoids linking FaultOrdering to the main app

set -e

PROJECT_DIR="/Users/joshlacalamito/Developer/Catbird+Petrel/Catbird"
cd "$PROJECT_DIR"

echo "🚀 Generating Order File (Simulator Only)"
echo "=========================================="
echo ""

# Step 1: Ensure we have the linkmap (already exists in project root)
if [ ! -f "Linkmap.txt" ]; then
    echo "❌ Linkmap.txt not found. Please build the app first:"
    echo "   xcodebuild -project Catbird.xcodeproj -scheme Catbird build"
    echo ""
    echo "Then copy the linkmap from DerivedData:"
    echo "   cp ~/Library/Developer/Xcode/DerivedData/Catbird-*/Build/Intermediates.noindex/Catbird.build/*/Catbird.build/DerivedSources/Catbird-*-LinkMap.txt ./Linkmap.txt"
    exit 1
fi

echo "✅ Found Linkmap.txt ($(wc -l < Linkmap.txt) lines)"
echo ""

# Step 2: Run UI test with FaultOrdering (simulator only)
echo "🧪 Running FaultOrdering UI test on simulator..."
echo "This will take 2-3 minutes..."
echo ""

xcodebuild test \
    -project Catbird.xcodeproj \
    -scheme Catbird \
    -configuration Release \
    -sdk iphonesimulator \
    -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
    -only-testing:CatbirdUITests/FaultOrderingLaunchTest/testGenerateOrderFile \
    -resultBundlePath ./fault_ordering_output/test_results.xcresult

# Step 3: Extract order file from test results
echo ""
echo "📄 Extracting order file from test results..."

RESULT_BUNDLE="./fault_ordering_output/test_results.xcresult"

if [ ! -d "$RESULT_BUNDLE" ]; then
    echo "❌ Test result bundle not found at: $RESULT_BUNDLE"
    exit 1
fi

# Extract order file from xcresult Data directory
# Look for text files containing symbol names
ORDER_FILE=""
for datafile in "$RESULT_BUNDLE"/Data/data.*; do
    if [ -f "$datafile" ]; then
        # Check if file contains symbol-like data
        if head -1 "$datafile" 2>/dev/null | grep -q "^_\|^#.*order"; then
            ORDER_FILE="$datafile"
            break
        fi
    fi
done

if [ -z "$ORDER_FILE" ]; then
    echo "❌ Order file not found in test results"
    echo ""
    echo "This usually means:"
    echo "1. Linkmap.txt wasn't added to UI test Copy Bundle Resources"
    echo "2. The test didn't run successfully"
    echo ""
    echo "Open the test results to check:"
    echo "  open $RESULT_BUNDLE"
    echo ""
    echo "Or check the test logs for errors"
    exit 1
fi

# Copy to project root
cp "$ORDER_FILE" ./order-file.txt
echo "✅ Order file extracted to: $PROJECT_DIR/order-file.txt"

echo ""
echo "📊 Order file statistics:"
wc -l order-file.txt
echo ""
echo "First 20 symbols:"
head -20 order-file.txt

echo ""
echo "=========================================="
echo "✅ Order file generation complete!"
echo ""
echo "Next steps:"
echo "1. The order file is at: order-file.txt"
echo "2. It's already configured in build settings"
echo "3. Rebuild to apply optimizations:"
echo "   xcodebuild -project Catbird.xcodeproj -scheme Catbird build"
echo ""
echo "Expected improvement: 10-30% faster startup"
echo "=========================================="
