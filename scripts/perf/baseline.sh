#!/bin/bash
# baseline.sh - Build clean Release device binary and run Instruments trace baselines.
#
# Usage:
#   ./baseline.sh [options] [template1 template2 ...]
#
# Options:
#   -d, --derived-data <path>  DerivedData output path (default: ../build/DerivedData-baseline)
#   --duration <duration>      Trace duration (e.g. 30s, default: 30s)
#   --device <id>              Device UDID (required, or set DEVICE_UDID env var)
#   --skip-build               Skip xcodebuild and use existing built app
#   --output-dir <path>        Directory to store traces (default: ../build/traces)
#
# Examples:
#   ./baseline.sh "Time Profiler" "Animation Hitches"
#   ./baseline.sh -d /tmp/CatbirdDD "App Launch"
#
# Compatible with bash 3.2+.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Device identifiers
# Physical device: iPhone UDID (required via env DEVICE_UDID or --device <id>)
DEVICE_UDID="${DEVICE_UDID:-}"

DERIVED_DATA="${PROJECT_ROOT}/../build/DerivedData-baseline"
TRACES_DIR="${PROJECT_ROOT}/../build/traces"
DURATION="30s"
SKIP_BUILD=0
TEMPLATES=()

cleanup_instruments_leftovers() {
  local tmp_dir="${TMPDIR:-/tmp}"
  echo "Cleaning up Instruments leftover ktrace files in '$tmp_dir'..."
  rm -rf "$tmp_dir"/instruments*.ktrace 2>/dev/null || true
  rm -rf /tmp/instruments*.ktrace 2>/dev/null || true
}

# Ensure cleanup on script exit
trap cleanup_instruments_leftovers EXIT

resolve_template_name() {
  case "$1" in
    time-profiler|"Time Profiler") echo "Time Profiler" ;;
    allocations|"Allocations") echo "Allocations" ;;
    leaks|"Leaks") echo "Leaks" ;;
    swiftui|"SwiftUI") echo "SwiftUI" ;;
    app-launch|"App Launch") echo "App Launch" ;;
    animation-hitches|"Animation Hitches") echo "Animation Hitches" ;;
    system-trace|"System Trace") echo "System Trace" ;;
    *) echo "$1" ;;
  esac
}

# Parse options
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
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [options] [template1 template2 ...]"
      exit 0
      ;;
    *)
      TEMPLATES+=("$1")
      shift
      ;;
  esac
done

if [ -z "$DEVICE_UDID" ]; then
  echo "Error: Device UDID is required. Set DEVICE_UDID env var or pass --device <UDID>." >&2
  exit 1
fi

if [ ${#TEMPLATES[@]} -eq 0 ]; then
  TEMPLATES=("Time Profiler")
fi

mkdir -p "$TRACES_DIR"
mkdir -p "$DERIVED_DATA"

echo "=== Catbird Performance Baseline ==="
echo "Project root:    $PROJECT_ROOT"
echo "Device UDID:     $DEVICE_UDID"
echo "DerivedData:     $DERIVED_DATA"
echo "Traces dir:      $TRACES_DIR"
echo "Duration:        $DURATION"
echo "Templates:       ${TEMPLATES[*]}"
echo ""

# Step 1: Build Release for physical device with code coverage disabled
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
fi

# Step 2: Locate built app
APP_PATH=$(find "$DERIVED_DATA/Build/Products" -name "Catbird.app" -path "*Release-iphoneos*" 2>/dev/null | head -1)

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
  # Fallback search anywhere in derived data
  APP_PATH=$(find "$DERIVED_DATA" -name "Catbird.app" 2>/dev/null | head -1)
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
  echo "❌ Error: Could not find Catbird.app in $DERIVED_DATA" >&2
  exit 1
fi

echo "📱 Found built app: $APP_PATH"
echo ""

# Step 3: Run verify-build.sh to ensure no coverage instrumentation
echo "🔍 Verifying binary has no coverage instrumentation..."
"$SCRIPT_DIR/verify-build.sh" "$APP_PATH"

echo "✓ Build verified clean."
echo ""

# Step 4: Run each xctrace template
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

for tmpl_raw in "${TEMPLATES[@]}"; do
  TMPL=$(resolve_template_name "$tmpl_raw")
  TMPL_SLUG=$(echo "$TMPL" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
  OUTPUT_TRACE="${TRACES_DIR}/baseline-${TMPL_SLUG}-${TIMESTAMP}.trace"

  echo "⏱️ Recording trace with template '$TMPL' for $DURATION..."
  echo "   Output: $OUTPUT_TRACE"

  # xctrace device flag uses Device UDID
  TARGET_DEVICE="$DEVICE_UDID"

  if [ "$TMPL" = "App Launch" ]; then
    xcrun xctrace record \
      --template "$TMPL" \
      --device "$TARGET_DEVICE" \
      --time-limit "$DURATION" \
      --output "$OUTPUT_TRACE" \
      --launch -- "$APP_PATH" || true
  else
    # Try attaching first, or launch if not running
    xcrun xctrace record \
      --template "$TMPL" \
      --device "$TARGET_DEVICE" \
      --time-limit "$DURATION" \
      --output "$OUTPUT_TRACE" \
      --attach "Catbird" || \
    xcrun xctrace record \
      --template "$TMPL" \
      --device "$TARGET_DEVICE" \
      --time-limit "$DURATION" \
      --output "$OUTPUT_TRACE" \
      --launch -- "$APP_PATH" || true
  fi

  echo "✓ Trace recorded: $OUTPUT_TRACE"

  # Clean up huge leftover ktrace files after each run
  cleanup_instruments_leftovers
done

echo ""
echo "✅ All baseline recordings complete."
