#!/bin/bash
# Quick incremental build

if [ -f "Package.swift" ]; then
    echo "📦 Building Swift Package..."
    swift build
elif [ -n "$(find . -name "*.xcworkspace" | head -1)" ]; then
    echo "🏗️ Using incremental build system..."
    # This will use the faster incremental build
    claude --no-ui <<< "build_mac_ws { workspacePath: \"$(find . -name "*.xcworkspace" | head -1)\", scheme: \"$1\" }"
else
    echo "🏗️ Using swift build for package..."
    swift build
fi
