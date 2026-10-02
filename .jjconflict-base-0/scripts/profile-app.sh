#!/bin/bash
# profile-app.sh - Automated Instruments trace capture for Catbird
# Usage: ./profile-app.sh [template] [duration] [output-name]
#
# Templates: time-profiler, allocations, leaks, swiftui, app-launch, swift-concurrency
# Default: time-profiler for 30s

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACES_DIR="${PROJECT_ROOT}/../build/traces"
DERIVED_DATA="${PROJECT_ROOT}/../build/DerivedData"

# Default values
TEMPLATE_KEY="${1:-time-profiler}"
DURATION="${2:-30s}"
OUTPUT_NAME="${3:-}"
SIMULATOR="iPhone 17 Pro"

# Map template keys to Instruments template names
declare -A TEMPLATE_MAP=(
  ["time-profiler"]="Time Profiler"
  ["allocations"]="Allocations"
  ["leaks"]="Leaks"
  ["swiftui"]="SwiftUI"
  ["app-launch"]="App Launch"
  ["swift-concurrency"]="Swift Concurrency"
  ["animation"]="Animation Hitches"
  ["network"]="Network"
)

TEMPLATE="${TEMPLATE_MAP[$TEMPLATE_KEY]:-$TEMPLATE_KEY}"

# Generate output filename
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
if [[ -z "$OUTPUT_NAME" ]]; then
  OUTPUT_NAME="${TEMPLATE_KEY}-${TIMESTAMP}"
fi
OUTPUT_PATH="${TRACES_DIR}/${OUTPUT_NAME}.trace"

# Ensure traces directory exists
mkdir -p "$TRACES_DIR"

echo "=== Catbird Performance Profiling ==="
echo "Template:    $TEMPLATE"
echo "Duration:    $DURATION"
echo "Simulator:   $SIMULATOR"
echo "Output:      $OUTPUT_PATH"
echo ""

# Find the built app
APP_PATH=$(find "$DERIVED_DATA" -name "Catbird.app" -path "*Debug-iphonesimulator*" 2>/dev/null | head -1)

if [[ -z "$APP_PATH" ]]; then
  echo "⚠️  Catbird.app not found in DerivedData. Building first..."
  cd "$PROJECT_ROOT"
  xcodebuild -project Catbird.xcodeproj \
    -scheme Catbird \
    -destination "platform=iOS Simulator,name=$SIMULATOR" \
    -derivedDataPath "$DERIVED_DATA" \
    -configuration Debug \
    build \
    -quiet
  
  APP_PATH=$(find "$DERIVED_DATA" -name "Catbird.app" -path "*Debug-iphonesimulator*" 2>/dev/null | head -1)
  
  if [[ -z "$APP_PATH" ]]; then
    echo "❌ Build failed or app not found"
    exit 1
  fi
fi

echo "📱 App:       $APP_PATH"
echo ""

# Boot simulator if needed
SIMULATOR_ID=$(xcrun simctl list devices | grep "$SIMULATOR" | grep -oE "[A-F0-9-]{36}" | head -1)
if [[ -z "$SIMULATOR_ID" ]]; then
  echo "❌ Simulator '$SIMULATOR' not found"
  exit 1
fi

SIMULATOR_STATE=$(xcrun simctl list devices | grep "$SIMULATOR_ID" | grep -o "(Booted)" || true)
if [[ -z "$SIMULATOR_STATE" ]]; then
  echo "🔄 Booting simulator..."
  xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
  sleep 3
fi

# For App Launch template, we launch the app via xctrace
# For other templates, we can attach to a running app or launch fresh
if [[ "$TEMPLATE_KEY" == "app-launch" ]]; then
  echo "🚀 Recording App Launch trace..."
  xcrun xctrace record \
    --template "$TEMPLATE" \
    --device "$SIMULATOR_ID" \
    --launch -- "$APP_PATH" \
    --output "$OUTPUT_PATH" \
    --time-limit "$DURATION"
else
  # Install and launch the app first
  echo "📲 Installing app..."
  xcrun simctl install "$SIMULATOR_ID" "$APP_PATH"
  
  echo "🚀 Launching app..."
  xcrun simctl launch "$SIMULATOR_ID" blue.catbird.Catbird
  sleep 2
  
  # Get the PID
  APP_PID=$(xcrun simctl spawn "$SIMULATOR_ID" launchctl list | grep catbird | awk '{print $1}' || true)
  
  if [[ -z "$APP_PID" || "$APP_PID" == "-" ]]; then
    # Fallback: find by process name
    APP_PID=$(pgrep -f "Catbird.app" | head -1 || true)
  fi
  
  if [[ -z "$APP_PID" ]]; then
    echo "⚠️  Could not find app PID, recording by launch instead..."
    xcrun xctrace record \
      --template "$TEMPLATE" \
      --device "$SIMULATOR_ID" \
      --launch -- "$APP_PATH" \
      --output "$OUTPUT_PATH" \
      --time-limit "$DURATION"
  else
    echo "📊 Recording trace (PID: $APP_PID)..."
    xcrun xctrace record \
      --template "$TEMPLATE" \
      --attach "$APP_PID" \
      --output "$OUTPUT_PATH" \
      --time-limit "$DURATION"
  fi
fi

echo ""
echo "✅ Trace saved: $OUTPUT_PATH"
echo ""
echo "To open in Instruments:"
echo "  open \"$OUTPUT_PATH\""
