#!/bin/bash
# Quick error check without building

echo "🔍 Checking for Swift errors..."

# Method 1: Use xcode_monitor if available
if command -v claude &> /dev/null; then
    echo "Using Xcode monitor..."
    claude --no-ui <<< "xcode_monitor:get_diagnostics"
else
    echo "Claude Code not available, using sourcekit-lsp..."
    # Method 2: Use sourcekit-lsp directly
    if command -v sourcekit-lsp &> /dev/null; then
        find . -name "*.swift" -exec sourcekit-lsp diagnose {} \; 2>/dev/null | grep -E "(error|warning):"
    else
        echo "sourcekit-lsp not found. Install Xcode command line tools."
    fi
fi
