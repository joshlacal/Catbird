#!/bin/bash
# Fast Swift error checking without full builds
# Uses xcodebuild's analyze action which is much faster than build

PROJECT_PATH="${1:-.}"
cd "$PROJECT_PATH"

# Find workspace or project
WORKSPACE=$(find . -name "*.xcworkspace" -maxdepth 1 | head -1)
PROJECT=$(find . -name "*.xcodeproj" -maxdepth 1 | head -1)

if [ -z "$WORKSPACE" ] && [ -z "$PROJECT" ]; then
    echo "❌ No Xcode workspace or project found"
    exit 1
fi

# Get the first scheme
if [ -n "$WORKSPACE" ]; then
    SCHEME=$(xcodebuild -list -workspace "$WORKSPACE" -json 2>/dev/null | jq -r '.workspace.schemes[0]' 2>/dev/null)
    BUILD_CMD="xcodebuild -workspace $WORKSPACE"
else
    SCHEME=$(xcodebuild -list -project "$PROJECT" -json 2>/dev/null | jq -r '.project.schemes[0]' 2>/dev/null)
    BUILD_CMD="xcodebuild -project $PROJECT"
fi

if [ -z "$SCHEME" ]; then
    echo "❌ No scheme found"
    exit 1
fi

echo "🔍 Quick error check for scheme: $SCHEME"
echo "📍 Using: $(basename ${WORKSPACE:-$PROJECT})"
echo ""

# Method 1: Use -dry-run to just check configuration
echo "1️⃣ Checking project configuration..."
$BUILD_CMD -scheme "$SCHEME" -configuration Debug -dry-run 2>&1 | grep -E "(error:|warning:)" | head -20

# Method 2: Use analyze action (faster than build, catches more than dry-run)
echo ""
echo "2️⃣ Running static analysis (faster than build)..."
$BUILD_CMD -scheme "$SCHEME" -configuration Debug analyze \
    -derivedDataPath /tmp/swift-check-dd \
    COMPILER_INDEX_STORE_ENABLE=NO \
    2>&1 | grep -E "(error:|warning:|note:)" | grep -v "note: Using" | head -50

# Method 3: Just parse without building using swift-frontend
echo ""
echo "3️⃣ Quick syntax check on modified files..."

# Get recently modified Swift files
RECENT_FILES=$(find . -name "*.swift" -not -path "./Pods/*" -not -path "./build/*" -mtime -1 | head -10)

if [ -n "$RECENT_FILES" ]; then
    for file in $RECENT_FILES; do
        echo "Checking: $file"
        xcrun swift-frontend -typecheck -parse-as-library "$file" 2>&1 | grep -E "(error:|warning:)" | head -5
    done
else
    echo "No recently modified Swift files found"
fi

# Clean up
rm -rf /tmp/swift-check-dd

echo ""
echo "✅ Quick check complete!"
echo ""
echo "💡 Tips:"
echo "   - This shows syntax/type errors without doing a full build"
echo "   - For real-time checking in your editor, use sourcekit-lsp"
echo "   - For the absolute fastest checks, use: xcrun swift-frontend -parse <file.swift>"
