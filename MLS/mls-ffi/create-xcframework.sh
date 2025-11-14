#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

echo "📦 Building MLS FFI with UniFFI for iOS"
echo "========================================"
echo ""

# Clean previous builds
rm -rf MLSFFIFramework.xcframework
rm -rf build/frameworks
rm -rf build/bindings

# Detect host architecture
HOST_ARCH=$(uname -m)
if [ "$HOST_ARCH" = "arm64" ]; then
    HOST_TARGET="aarch64-apple-darwin"
else
    HOST_TARGET="x86_64-apple-darwin"
fi

echo "🔧 Step 1: Build host library for metadata extraction"
echo "Target: $HOST_TARGET"
cargo build --release --target "$HOST_TARGET"

echo ""
echo "🧠 Step 2: Generate Swift bindings from compiled library"
mkdir -p build/bindings

# The target directory is local to mls-ffi crate
LIBRARY_PATH="target/$HOST_TARGET/release/libmls_ffi.dylib"

# Use the in-workspace uniffi-bindgen binary
cargo run --bin uniffi-bindgen generate \
    --library "$LIBRARY_PATH" \
    --language swift \
    --out-dir build/bindings \
    --config uniffi.toml

echo ""
echo "📦 Step 3: Add iOS targets"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-ios-macabi x86_64-apple-ios-macabi

echo ""
echo "🏗️  Step 4: Build iOS static libraries"
echo "Building for iOS Device (ARM64)..."
cargo build --release --target aarch64-apple-ios

echo "Building for iOS Simulator (ARM64)..."
cargo build --release --target aarch64-apple-ios-sim

echo "Building for iOS Simulator (x86_64)..."
cargo build --release --target x86_64-apple-ios

echo "Building for Mac Catalyst (arm64)..."
cargo build --release --target aarch64-apple-ios-macabi

echo "Building for Mac Catalyst (x86_64)..."
cargo build --release --target x86_64-apple-ios-macabi

echo ""
echo "📦 Step 5: Create XCFramework structure"

# Create framework structure for device
mkdir -p build/frameworks/ios-arm64/MLSFFI.framework/{Headers,Modules}
cp target/aarch64-apple-ios/release/libmls_ffi.a \
   build/frameworks/ios-arm64/MLSFFI.framework/MLSFFI

# Create framework structure for simulator (fat binary)
mkdir -p build/frameworks/ios-simulator/MLSFFI.framework/{Headers,Modules}
lipo -create \
    target/aarch64-apple-ios-sim/release/libmls_ffi.a \
    target/x86_64-apple-ios/release/libmls_ffi.a \
    -output build/frameworks/ios-simulator/MLSFFI.framework/MLSFFI

# Create framework structure for Mac Catalyst (fat binary) - DEEP BUNDLE
# Mac Catalyst requires Versions/Current/Resources structure
CATALYST_FW=build/frameworks/ios-maccatalyst/MLSFFI.framework
mkdir -p "$CATALYST_FW/Versions/A"/{Headers,Modules,Resources}

lipo -create \
    target/aarch64-apple-ios-macabi/release/libmls_ffi.a \
    target/x86_64-apple-ios-macabi/release/libmls_ffi.a \
    -output "$CATALYST_FW/Versions/A/MLSFFI"

# Create symlinks for deep bundle structure
cd "$CATALYST_FW"
ln -sf A Versions/Current
ln -sf Versions/Current/Headers Headers
ln -sf Versions/Current/Modules Modules
ln -sf Versions/Current/Resources Resources
ln -sf Versions/Current/MLSFFI MLSFFI
cd - > /dev/null

# Copy generated headers and modulemap to device and simulator frameworks
for FRAMEWORK_DIR in build/frameworks/ios-{arm64,simulator}/MLSFFI.framework; do
    cp build/bindings/MLSFFIFFI.h "$FRAMEWORK_DIR/Headers/"
    cp build/bindings/MLSFFIFFI.modulemap "$FRAMEWORK_DIR/Modules/module.modulemap"

    # Create Info.plist (shallow bundle for iOS)
    cat > "$FRAMEWORK_DIR/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>MLSFFI</string>
    <key>CFBundleIdentifier</key>
    <string>com.exytechat.mlsffi</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MLSFFI</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
EOF
done

# Copy headers and modulemap to Mac Catalyst framework (deep bundle structure)
cp build/bindings/MLSFFIFFI.h "$CATALYST_FW/Versions/A/Headers/"
cp build/bindings/MLSFFIFFI.modulemap "$CATALYST_FW/Versions/A/Modules/module.modulemap"

# Create Info.plist in Resources directory for Mac Catalyst
cat > "$CATALYST_FW/Versions/A/Resources/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>MLSFFI</string>
    <key>CFBundleIdentifier</key>
    <string>com.exytechat.mlsffi</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MLSFFI</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
</dict>
</plist>
EOF

echo ""
echo "🎁 Step 6: Create XCFramework"
xcodebuild -create-xcframework \
    -framework build/frameworks/ios-arm64/MLSFFI.framework \
    -framework build/frameworks/ios-simulator/MLSFFI.framework \
    -framework build/frameworks/ios-maccatalyst/MLSFFI.framework \
    -output MLSFFIFramework.xcframework

echo ""
echo "✅ Build complete!"
echo ""
echo "📍 Generated files:"
echo "   - XCFramework:     MLSFFIFramework.xcframework/"
echo "   - Swift bindings:  build/bindings/MLSFFI.swift"
echo "   - C headers:       build/bindings/MLSFFIFFI.h"
echo "   - Module map:      build/bindings/MLSFFIFFI.modulemap"
echo ""
echo "🎯 Next steps:"
echo "   1. Add MLSFFIFramework.xcframework to your Xcode project"
echo "   2. Copy build/bindings/MLSFFI.swift to your Swift sources"
echo "   3. Import MLSFFI in your Swift code"
echo ""
