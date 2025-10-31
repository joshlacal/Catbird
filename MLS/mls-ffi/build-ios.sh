#!/bin/bash
set -e

echo "🔧 Building MLS FFI for iOS targets..."
echo ""

# Add iOS targets if not already added
echo "📦 Adding iOS targets..."
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios

echo ""
echo "🏗️  Building for iOS Device (ARM64)..."
cargo build --target aarch64-apple-ios --release

echo ""
echo "🏗️  Building for iOS Simulator (ARM64)..."
cargo build --target aarch64-apple-ios-sim --release

echo ""
echo "🏗️  Building for iOS Simulator (x86_64)..."
cargo build --target x86_64-apple-ios --release

echo ""
echo "✅ All builds complete!"
echo ""
echo "📍 Build artifacts:"
echo "   - Device:      target/aarch64-apple-ios/release/libmls_ffi.a"
echo "   - Simulator (ARM): target/aarch64-apple-ios-sim/release/libmls_ffi.a"
echo "   - Simulator (x86): target/x86_64-apple-ios/release/libmls_ffi.a"
echo ""
echo "🎯 Next step: Run ./create-xcframework.sh to package for Xcode"
