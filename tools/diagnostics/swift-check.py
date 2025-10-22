#!/usr/bin/env python3
"""
Swift diagnostics checker using sourcekit-lsp
Gets real-time errors/warnings without building
"""

import json
import subprocess
import sys
import os
from pathlib import Path
import glob
import re

def find_swift_files(root_path):
    """Find all Swift files in the project"""
    swift_files = []
    for ext in ['*.swift']:
        swift_files.extend(glob.glob(f"{root_path}/**/{ext}", recursive=True))
    return swift_files

def get_compile_commands(project_path):
    """Try to get compile commands from various sources"""
    # First, try to use xcode-build-server to generate build settings
    workspace = None
    project = None
    
    # Find workspace or project
    for ws in Path(project_path).glob("*.xcworkspace"):
        workspace = ws
        break
    
    if not workspace:
        for proj in Path(project_path).glob("*.xcodeproj"):
            project = proj
            break
    
    # Get the scheme
    if workspace or project:
        target_path = workspace or project
        # List schemes
        schemes_cmd = ["xcodebuild", "-list", "-json"]
        if workspace:
            schemes_cmd.extend(["-workspace", str(workspace)])
        else:
            schemes_cmd.extend(["-project", str(project)])
        
        try:
            result = subprocess.run(schemes_cmd, capture_output=True, text=True)
            if result.returncode == 0:
                schemes_data = json.loads(result.stdout)
                if schemes_data.get("project", {}).get("schemes"):
                    return schemes_data["project"]["schemes"][0]  # Return first scheme
        except:
            pass
    
    return None

def check_file_with_swiftc(file_path, scheme=None, project_path=None):
    """Check a single file using swiftc -typecheck"""
    errors = []
    
    # Build the command
    cmd = [
        "xcrun", "swiftc",
        "-typecheck",
        "-sdk", subprocess.check_output(["xcrun", "--show-sdk-path"]).decode().strip(),
        "-target", "arm64-apple-macosx13.0",  # Adjust based on your project
        "-swift-version", "5",
        "-parse-as-library",
        file_path
    ]
    
    # Add framework search paths for common frameworks
    framework_paths = [
        "/System/Library/Frameworks",
        "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks"
    ]
    
    for path in framework_paths:
        cmd.extend(["-F", path])
    
    # If we have a project, try to get build settings
    if scheme and project_path:
        try:
            # Get build settings from xcodebuild
            settings_cmd = ["xcodebuild", "-showBuildSettings", "-scheme", scheme, "-configuration", "Debug"]
            if Path(project_path).glob("*.xcworkspace"):
                ws = list(Path(project_path).glob("*.xcworkspace"))[0]
                settings_cmd.extend(["-workspace", str(ws)])
            elif Path(project_path).glob("*.xcodeproj"):
                proj = list(Path(project_path).glob("*.xcodeproj"))[0]
                settings_cmd.extend(["-project", str(proj)])
            
            result = subprocess.run(settings_cmd, capture_output=True, text=True)
            if result.returncode == 0:
                # Parse build settings
                settings = {}
                for line in result.stdout.split('\n'):
                    if ' = ' in line:
                        key, value = line.strip().split(' = ', 1)
                        settings[key.strip()] = value.strip()
                
                # Add Swift flags
                if 'OTHER_SWIFT_FLAGS' in settings:
                    flags = settings['OTHER_SWIFT_FLAGS'].split()
                    cmd.extend(flags)
                
                # Add module name
                if 'PRODUCT_MODULE_NAME' in settings:
                    cmd.extend(["-module-name", settings['PRODUCT_MODULE_NAME']])
        except:
            pass
    
    # Run swiftc
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        
        # Parse errors from stderr
        for line in result.stderr.split('\n'):
            if ': error:' in line or ': warning:' in line:
                errors.append(line)
    except subprocess.TimeoutExpired:
        errors.append(f"Timeout checking {file_path}")
    except Exception as e:
        errors.append(f"Error checking {file_path}: {str(e)}")
    
    return errors

def check_with_sourcekit_lsp(file_path):
    """Try to use sourcekit-lsp directly"""
    # This is more complex as sourcekit-lsp uses JSON-RPC
    # For now, we'll use swiftc which is simpler
    pass

def main():
    if len(sys.argv) > 1:
        project_path = sys.argv[1]
    else:
        project_path = os.getcwd()
    
    print(f"🔍 Checking Swift files in: {project_path}")
    
    # Get scheme if available
    scheme = get_compile_commands(project_path)
    if scheme:
        print(f"📦 Using scheme: {scheme}")
    
    # Find all Swift files
    swift_files = find_swift_files(project_path)
    print(f"📄 Found {len(swift_files)} Swift files")
    
    # Check each file
    all_errors = []
    for i, file_path in enumerate(swift_files):
        rel_path = os.path.relpath(file_path, project_path)
        print(f"\r⏳ Checking {i+1}/{len(swift_files)}: {rel_path}", end='', flush=True)
        
        errors = check_file_with_swiftc(file_path, scheme, project_path)
        if errors:
            all_errors.extend(errors)
    
    print("\n")  # New line after progress
    
    # Report results
    if all_errors:
        print(f"\n❌ Found {len(all_errors)} issues:\n")
        for error in all_errors:
            print(error)
    else:
        print("✅ No errors found!")

if __name__ == "__main__":
    main()
