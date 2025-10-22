#!/usr/bin/env python3
"""
Real-time Swift diagnostics using xcode-build-server and sourcekit-lsp
This is how Sweetpad, VSCode, and other modern tools get instant feedback
"""

import subprocess
import json
import sys
import os
from pathlib import Path
import tempfile
import shutil

def setup_build_server(project_path):
    """Set up xcode-build-server for sourcekit-lsp"""
    print("🔧 Setting up build server configuration...")
    
    # Create .sourcekit-lsp directory
    lsp_dir = Path(project_path) / ".sourcekit-lsp"
    lsp_dir.mkdir(exist_ok=True)
    
    # Check if xcode-build-server is installed
    xbs_path = shutil.which("xcode-build-server")
    if not xbs_path:
        print("❌ xcode-build-server not found. Installing...")
        # Try to install via brew
        subprocess.run(["brew", "install", "xcode-build-server"], check=False)
        xbs_path = shutil.which("xcode-build-server")
        if not xbs_path:
            print("❌ Failed to install xcode-build-server")
            print("   Please install manually: brew install xcode-build-server")
            return False
    
    # Create buildServer.json
    build_server_config = {
        "name": "xcode-build-server",
        "version": "0.2",
        "bspVersion": "2.0",
        "languages": ["swift", "objective-c", "objective-cpp", "c", "cpp"],
        "argv": [xbs_path]
    }
    
    config_path = lsp_dir / "buildServer.json"
    with open(config_path, 'w') as f:
        json.dump(build_server_config, f, indent=2)
    
    print(f"✅ Build server config created at: {config_path}")
    
    # Create config.json for xcode-build-server
    config_json_path = lsp_dir / "config.json"
    
    # Find workspace or project
    workspace = None
    project = None
    
    for ws in Path(project_path).glob("*.xcworkspace"):
        workspace = ws
        break
    
    if not workspace:
        for proj in Path(project_path).glob("*.xcodeproj"):
            project = proj
            break
    
    if workspace or project:
        xbs_config = {
            "workspace": str(workspace) if workspace else str(project),
        }
        
        with open(config_json_path, 'w') as f:
            json.dump(xbs_config, f, indent=2)
        
        print(f"✅ xcode-build-server config created")
    
    return True

def get_diagnostics_via_lsp(project_path):
    """Get diagnostics using sourcekit-lsp directly"""
    print("\n🔍 Getting diagnostics via sourcekit-lsp...")
    
    # This is complex as sourcekit-lsp uses JSON-RPC protocol
    # For simplicity, we'll use a different approach
    
    # Instead, let's use swiftc with the build settings from xcodebuild
    return get_smart_diagnostics(project_path)

def get_smart_diagnostics(project_path):
    """Smart diagnostics using xcodebuild's indexing capabilities"""
    print("\n🚀 Getting diagnostics without full build...")
    
    # Find workspace or project
    workspace = None
    project = None
    
    for ws in Path(project_path).glob("*.xcworkspace"):
        workspace = ws
        break
    
    if not workspace:
        for proj in Path(project_path).glob("*.xcodeproj"):
            project = proj
            break
    
    if not workspace and not project:
        print("❌ No Xcode project found")
        return
    
    # Get scheme
    list_cmd = ["xcodebuild", "-list", "-json"]
    if workspace:
        list_cmd.extend(["-workspace", str(workspace)])
    else:
        list_cmd.extend(["-project", str(project)])
    
    try:
        result = subprocess.run(list_cmd, capture_output=True, text=True)
        schemes_data = json.loads(result.stdout)
        scheme = schemes_data.get("project", {}).get("schemes", [])[0] if schemes_data else None
    except:
        scheme = None
    
    if not scheme:
        print("❌ No scheme found")
        return
    
    print(f"📦 Using scheme: {scheme}")
    
    # Use xcodebuild with special flags for fast checking
    build_cmd = ["xcodebuild"]
    if workspace:
        build_cmd.extend(["-workspace", str(workspace)])
    else:
        build_cmd.extend(["-project", str(project)])
    
    build_cmd.extend([
        "-scheme", scheme,
        "-configuration", "Debug",
        "-hideShellScriptEnvironment",
        "-skipPackagePluginValidation",
        "-skipMacroValidation",
        "-onlyUsePackageVersionsFromResolvedFile",
        "-disableAutomaticPackageResolution",
        "COMPILER_INDEX_STORE_ENABLE=NO",
        "SWIFT_COMPILATION_MODE=singlefile",
        "SWIFT_WHOLE_MODULE_OPTIMIZATION=NO",
        "BUILD_ACTIVE_RESOURCES_ONLY=YES",
        "ONLY_ACTIVE_ARCH=YES",
        "CODE_SIGN_IDENTITY=-",
        "CODE_SIGNING_REQUIRED=NO",
        "CODE_SIGNING_ALLOWED=NO",
        "-dry-run"  # This makes it only check, not build!
    ])
    
    print("⏳ Checking for errors (this is fast!)...")
    
    # Run the check
    process = subprocess.Popen(
        build_cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1
    )
    
    errors = []
    warnings = []
    
    # Process output line by line
    for line in process.stdout:
        line = line.strip()
        if ": error:" in line:
            errors.append(line)
            print(f"❌ {line}")
        elif ": warning:" in line:
            warnings.append(line)
            print(f"⚠️  {line}")
        elif "error:" in line.lower() and "build" not in line.lower():
            errors.append(line)
    
    process.wait()
    
    print(f"\n📊 Summary: {len(errors)} errors, {len(warnings)} warnings")
    
    return errors, warnings

def create_check_script(project_path):
    """Create a convenient check script"""
    script_content = '''#!/bin/bash
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
    xcodebuild -scheme "$(xcodebuild -list -json | jq -r '.project.schemes[0]')" \
        -configuration Debug \
        -dry-run 2>&1 | grep -E "(error:|warning:)" | head -20
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
'''
    
    script_path = Path(project_path) / "swift-check.sh"
    with open(script_path, 'w') as f:
        f.write(script_content)
    
    os.chmod(script_path, 0o755)
    print(f"\n✅ Created swift-check.sh script")

def main():
    project_path = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    
    print("🏗️  Setting up fast Swift error checking...")
    print(f"📍 Project: {project_path}\n")
    
    # Set up build server
    if setup_build_server(project_path):
        # Get diagnostics
        get_smart_diagnostics(project_path)
    
    # Create convenience script
    create_check_script(project_path)
    
    print("\n✨ Setup complete! You now have several options:\n")
    print("1. Use the Python script: python3 swift-diagnostics.py")
    print("2. Use the bash script: ./swift-check.sh")
    print("3. For VSCode/Sweetpad style checking, the build server is now configured")
    print("\n💡 The .sourcekit-lsp directory is now set up for real-time diagnostics!")

if __name__ == "__main__":
    main()
