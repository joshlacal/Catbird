#!/bin/bash
# profile-app.sh - Automated Instruments trace capture for Catbird
# Usage: ./profile-app.sh [options] [template] [duration] [output-name]
#
# Templates: time-profiler, allocations, leaks, swiftui, app-launch, swift-concurrency, animation, network
# Default: time-profiler for 30s
# Device UDID: required via env DEVICE_UDID or --device <id>
#
# Compatible with bash 3.2+.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Device identifiers
# Physical device: iPhone UDID (required via env DEVICE_UDID or --device <id>)
DEVICE_UDID="${DEVICE_UDID:-}"

DERIVED_DATA="${DERIVED_DATA:-${PROJECT_ROOT}/../build/DerivedData-baseline}"
TRACES_DIR="${TRACES_DIR:-${PROJECT_ROOT}/../build/traces}"

TEMPLATE_KEY="time-profiler"
DURATION="30s"
OUTPUT_NAME=""
SKIP_BUILD=0

# Clean up instruments leftover files on exit
cleanup_instruments_leftovers() {
  local tmp_dir="${TMPDIR:-/tmp}"
  rm -rf "$tmp_dir"/instruments*.ktrace 2>/dev/null || true
  rm -rf /tmp/instruments*.ktrace 2>/dev/null || true
}
trap cleanup_instruments_leftovers EXIT

# Bash 3.2-compatible template name resolution
resolve_template() {
  case "$1" in
    time-profiler|"Time Profiler") echo "Time Profiler" ;;
    allocations|"Allocations") echo "Allocations" ;;
    leaks|"Leaks") echo "Leaks" ;;
    swiftui|"SwiftUI") echo "SwiftUI" ;;
    app-launch|"App Launch") echo "App Launch" ;;
    swift-concurrency|"Swift Concurrency") echo "Swift Concurrency" ;;
    animation|"animation-hitches"|"Animation Hitches") echo "Animation Hitches" ;;
    network|"Network") echo "Network" ;;
    system-trace|"System Trace") echo "System Trace" ;;
    *) echo "$1" ;;
  esac
}

# Parse options and positional arguments
POSITIONAL_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--derived-data)
      DERIVED_DATA="$2"
      shift 2
      ;;
    --duration)
      DURATION="$2"
      shift 2
      ;;
    --device)
      DEVICE_UDID="$2"
      shift 2
      ;;
    --output-dir)
      TRACES_DIR="$2"
      shift 2
      ;;
    --output-name)
      OUTPUT_NAME="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [options] [template] [duration] [output-name]"
      echo ""
      echo "Options:"
      echo "  -d, --derived-data <path>  DerivedData output path"
      echo "  --duration <duration>      Trace duration (default: 30s)"
      echo "  --device <id>              Device UDID (or set DEVICE_UDID env var)"
      echo "  --output-dir <path>        Directory to store traces"
      echo "  --output-name <name>       Custom output trace name"
      echo "  --skip-build               Skip xcodebuild"
      exit 0
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

if [ ${#POSITIONAL_ARGS[@]} -ge 1 ]; then
  TEMPLATE_KEY="${POSITIONAL_ARGS[0]}"
fi
if [ ${#POSITIONAL_ARGS[@]} -ge 2 ]; then
  DURATION="${POSITIONAL_ARGS[1]}"
fi
if [ ${#POSITIONAL_ARGS[@]} -ge 3 ]; then
  OUTPUT_NAME="${POSITIONAL_ARGS[2]}"
fi
if [ -z "$DEVICE_UDID" ]; then
  echo "Error: Device UDID is required. Set DEVICE_UDID env var or pass --device <UDID>." >&2
  exit 1
fi


TEMPLATE=$(resolve_template "$TEMPLATE_KEY")

mkdir -p "$TRACES_DIR"
mkdir -p "$DERIVED_DATA"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
if [ -z "$OUTPUT_NAME" ]; then
  TMPL_SLUG=$(echo "$TEMPLATE" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
  OUTPUT_NAME="${TMPL_SLUG}-${TIMESTAMP}"
fi
OUTPUT_PATH="${TRACES_DIR}/${OUTPUT_NAME}.trace"

echo "=== Catbird Performance Profiling ==="
echo "Template:    $TEMPLATE"
echo "Duration:    $DURATION"
echo "Device UDID: $DEVICE_UDID"
echo "DerivedData: $DERIVED_DATA"
echo "Output:      $OUTPUT_PATH"
echo ""

# Locate or build the app
APP_PATH=$(find "$DERIVED_DATA/Build/Products" -name "Catbird.app" -path "*Release-iphoneos*" 2>/dev/null | head -1)

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
  APP_PATH=$(find "$DERIVED_DATA" -name "Catbird.app" 2>/dev/null | head -1)
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ] || [ "$SKIP_BUILD" -eq 0 ]; then
  if [ "$SKIP_BUILD" -eq 0 ]; then
    echo "🔨 Building Catbird (Release-iphoneos, code coverage disabled)..."
    xcodebuild -project "$PROJECT_ROOT/Catbird.xcodeproj" \
      -scheme Catbird \
      -configuration Release \
      -destination "id=$DEVICE_UDID" \
      -derivedDataPath "$DERIVED_DATA" \
      ENABLE_CODE_COVERAGE=NO \
      CLANG_COVERAGE_MAPPING=NO \
      CLANG_ENABLE_CODE_COVERAGE=NO \
      build
    echo "✓ Build completed successfully."

    APP_PATH=$(find "$DERIVED_DATA/Build/Products" -name "Catbird.app" -path "*Release-iphoneos*" 2>/dev/null | head -1)
    if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
      APP_PATH=$(find "$DERIVED_DATA" -name "Catbird.app" 2>/dev/null | head -1)
    fi
  fi
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
  echo "❌ Error: Could not find Catbird.app in $DERIVED_DATA" >&2
  exit 1
fi

echo "📱 Found built app: $APP_PATH"
echo ""

# Verify binary has no coverage instrumentation
VERIFY_SCRIPT="$SCRIPT_DIR/perf/verify-build.sh"
if [ -f "$VERIFY_SCRIPT" ]; then
  echo "🔍 Verifying binary has no coverage instrumentation..."
  "$VERIFY_SCRIPT" "$APP_PATH"
  echo "✓ Build verified clean."
  echo ""
fi

# Record trace using xctrace
echo "⏱️ Recording trace with template '$TEMPLATE' for $DURATION..."
if [ "$TEMPLATE" = "App Launch" ]; then
  xcrun xctrace record \
    --template "$TEMPLATE" \
    --device "$DEVICE_UDID" \
    --time-limit "$DURATION" \
    --output "$OUTPUT_PATH" \
    --launch -- "$APP_PATH" || true
else
  xcrun xctrace record \
    --template "$TEMPLATE" \
    --device "$DEVICE_UDID" \
    --time-limit "$DURATION" \
    --output "$OUTPUT_PATH" \
    --attach "Catbird" || \
  xcrun xctrace record \
    --template "$TEMPLATE" \
    --device "$DEVICE_UDID" \
    --time-limit "$DURATION" \
    --output "$OUTPUT_PATH" \
    --launch -- "$APP_PATH" || true
fi

echo ""
echo "✅ Trace saved: $OUTPUT_PATH"
echo ""
echo "To open in Instruments:"
echo "  open \"$OUTPUT_PATH\""
