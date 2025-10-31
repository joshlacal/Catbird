#!/bin/bash
set -e

echo "🔨 Building MLS FFI Library"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$PROJECT_DIR/.." && pwd)"
TARGET_DIR="$WORKSPACE_DIR/target"
BUILD_DIR="$PROJECT_DIR/build"
INCLUDE_DIR="$PROJECT_DIR/include"

# Targets
TARGETS=(
    "aarch64-apple-ios"           # iOS Device (ARM64)
    "x86_64-apple-ios"            # iOS Simulator (Intel)
    "aarch64-apple-ios-sim"       # iOS Simulator (Apple Silicon)
)

# Parse arguments
BUILD_TYPE="release"
UNIVERSAL_LIB=false
RUN_TESTS=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --debug)
            BUILD_TYPE="debug"
            shift
            ;;
        --universal)
            UNIVERSAL_LIB=true
            shift
            ;;
        --test)
            RUN_TESTS=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--debug] [--universal] [--test]"
            exit 1
            ;;
    esac
done

# Create build directory
mkdir -p "$BUILD_DIR"
mkdir -p "$INCLUDE_DIR"

echo -e "${BLUE}Build type: $BUILD_TYPE${NC}"

# Install targets if needed
echo -e "${BLUE}Checking Rust targets...${NC}"
for target in "${TARGETS[@]}"; do
    if ! rustup target list | grep -q "$target (installed)"; then
        echo "Installing target: $target"
        rustup target add "$target"
    fi
done

# Run tests first if requested
if [ "$RUN_TESTS" = true ]; then
    echo -e "${BLUE}Running tests...${NC}"
    cargo test --lib
    echo -e "${GREEN}✓ Tests passed${NC}"
fi

# Build for each target
BUILD_FLAG=""
if [ "$BUILD_TYPE" = "release" ]; then
    BUILD_FLAG="--release"
fi

for target in "${TARGETS[@]}"; do
    echo -e "${BLUE}Building for $target...${NC}"
    cargo build $BUILD_FLAG --target "$target"
    
    # Copy to build directory
    LIB_NAME="libmls_ffi.a"
    SRC_PATH="$TARGET_DIR/$target/$BUILD_TYPE/$LIB_NAME"
    DEST_PATH="$BUILD_DIR/$LIB_NAME.$target"
    
    cp "$SRC_PATH" "$DEST_PATH"
    echo -e "${GREEN}✓ Built: $DEST_PATH${NC}"
done

# Generate C header
echo -e "${BLUE}Generating C header...${NC}"
cargo build $BUILD_FLAG
echo -e "${GREEN}✓ Header generated: $INCLUDE_DIR/mls_ffi.h${NC}"

# Create universal library if requested
if [ "$UNIVERSAL_LIB" = true ]; then
    echo -e "${BLUE}Creating universal library...${NC}"
    
    # Device library (ARM64 only)
    cp "$BUILD_DIR/libmls_ffi.a.aarch64-apple-ios" "$BUILD_DIR/libmls_ffi_device.a"
    echo -e "${GREEN}✓ Device library: $BUILD_DIR/libmls_ffi_device.a${NC}"
    
    # Simulator universal library (Intel + ARM64)
    lipo -create \
        "$BUILD_DIR/libmls_ffi.a.x86_64-apple-ios" \
        "$BUILD_DIR/libmls_ffi.a.aarch64-apple-ios-sim" \
        -output "$BUILD_DIR/libmls_ffi_sim.a"
    echo -e "${GREEN}✓ Simulator library: $BUILD_DIR/libmls_ffi_sim.a${NC}"
    
    # Create XCFramework
    echo -e "${BLUE}Creating XCFramework...${NC}"
    XCFRAMEWORK_PATH="$BUILD_DIR/mls_ffi.xcframework"
    rm -rf "$XCFRAMEWORK_PATH"
    
    xcodebuild -create-xcframework \
        -library "$BUILD_DIR/libmls_ffi_device.a" \
        -headers "$INCLUDE_DIR" \
        -library "$BUILD_DIR/libmls_ffi_sim.a" \
        -headers "$INCLUDE_DIR" \
        -output "$XCFRAMEWORK_PATH"
    
    echo -e "${GREEN}✓ XCFramework created: $XCFRAMEWORK_PATH${NC}"
fi

# Print summary
echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}Build completed successfully!${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo "Output files:"
echo "  - C Header: $INCLUDE_DIR/mls_ffi.h"
for target in "${TARGETS[@]}"; do
    echo "  - $target: $BUILD_DIR/libmls_ffi.a.$target"
done

if [ "$UNIVERSAL_LIB" = true ]; then
    echo "  - Device library: $BUILD_DIR/libmls_ffi_device.a"
    echo "  - Simulator library: $BUILD_DIR/libmls_ffi_sim.a"
    echo "  - XCFramework: $BUILD_DIR/mls_ffi.xcframework"
fi

echo ""
echo "Integration:"
echo "  1. Add the appropriate .a file to your Xcode project"
echo "  2. Add mls_ffi.h to your bridging header"
echo "  3. See FFI_INTEGRATION_GUIDE.md for detailed instructions"
