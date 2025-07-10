#!/bin/bash
# Ultra-fast Swift error checking

# Method 1: Just parse files (fastest, but limited)
check_parse() {
    echo "🚀 Quick parse check..."
    find . -name "*.swift" -not -path "./Pods/*" -not -path "./.build/*" | while read file; do
        if xcrun swiftc -parse -suppress-warnings "$file" 2>&1 | grep -q "error:"; then
            echo "❌ $file"
            xcrun swiftc -parse "$file" 2>&1 | grep "error:" | head -3
        fi
    done
}

# Method 2: Check with xcodebuild dry-run
check_dry_run() {
    echo "🔍 Dry-run check..."
    xcodebuild -scheme "$(xcodebuild -list -json | jq -r '.project.schemes[0]')"         -configuration Debug         -dry-run 2>&1 | grep -E "(error:|warning:)" | head -20
}

# Method 3: Use swiftlint if available
check_lint() {
    if command -v swiftlint &> /dev/null; then
        echo "📝 SwiftLint check..."
        swiftlint --quiet --reporter emoji
    fi
}

case "${1:-all}" in
    parse) check_parse ;;
    dry) check_dry_run ;;
    lint) check_lint ;;
    all)
        check_parse
        echo ""
        check_dry_run
        echo ""
        check_lint
        ;;
    *)
        echo "Usage: $0 [parse|dry|lint|all]"
        ;;
esac
