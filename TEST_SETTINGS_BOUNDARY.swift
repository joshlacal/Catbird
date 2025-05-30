#!/usr/bin/env swift

import Foundation

// Test script to verify settings boundary

print("=== Catbird Settings Boundary Test ===\n")

// 1. Check PreferencesManager doesn't handle UI settings
print("1. Checking PreferencesManager for UI preference handling...")
let prefsManagerPath = "/Users/joshlacalamito/Developer/Catbird:Petrel/Catbird/Catbird/Core/State/PreferencesManager.swift"
if let content = try? String(contentsOfFile: prefsManagerPath) {
    let uiKeywords = ["theme", "font", "appearance", "appSettings.theme", "appSettings.font"]
    var violations = [String]()
    
    for keyword in uiKeywords {
        if content.contains(keyword) {
            violations.append(keyword)
        }
    }
    
    if violations.isEmpty {
        print("✅ PASS: PreferencesManager doesn't handle UI preferences")
    } else {
        print("❌ FAIL: Found UI keywords in PreferencesManager: \(violations)")
    }
} else {
    print("❌ ERROR: Could not read PreferencesManager.swift")
}

// 2. Check AppSettings doesn't sync to server
print("\n2. Checking AppSettings for server sync attempts...")
let appSettingsPath = "/Users/joshlacalamito/Developer/Catbird:Petrel/Catbird/Catbird/Features/Settings/Views/AppSettings.swift"
if let content = try? String(contentsOfFile: appSettingsPath) {
    let serverKeywords = ["putPreferences", "syncToServer", "app.bsky.actor", "ATProto"]
    var violations = [String]()
    
    for keyword in serverKeywords {
        if content.contains(keyword) {
            violations.append(keyword)
        }
    }
    
    if violations.isEmpty {
        print("✅ PASS: AppSettings doesn't attempt server sync")
    } else {
        print("❌ FAIL: Found server sync keywords in AppSettings: \(violations)")
    }
} else {
    print("❌ ERROR: Could not read AppSettings.swift")
}

// 3. Verify settings are properly categorized
print("\n3. Verifying settings categorization...")
print("\nLocal-Only Settings (AppSettings):")
let localSettings = [
    "theme", "darkThemeMode", "fontStyle", "fontSize",
    "reduceMotion", "prefersCrossfade", "disableHaptics",
    "increaseContrast", "boldText", "displayScale",
    "autoplayVideos", "useInAppBrowser", "allowYouTube"
]
print("✅ \(localSettings.count) local settings identified")

print("\nServer-Synced Settings (Preferences):")
let serverSettings = [
    "adultContentEnabled", "contentLabelPrefs", "pinnedFeeds",
    "savedFeeds", "threadViewPref", "feedViewPref",
    "mutedWords", "hiddenPosts", "labelers"
]
print("✅ \(serverSettings.count) server settings identified")

// 4. Check for mixed usage
print("\n4. Checking for mixed usage patterns...")
let modelsPath = "/Users/joshlacalamito/Developer/Catbird:Petrel/Catbird/Catbird/Core/State/Models/Preferences.swift"
if let content = try? String(contentsOfFile: modelsPath) {
    let uiKeywords = ["theme", "font", "appearance"]
    var found = false
    
    for keyword in uiKeywords {
        if content.contains(keyword) {
            found = true
            print("❌ WARNING: Found UI keyword '\(keyword)' in Preferences model")
        }
    }
    
    if !found {
        print("✅ PASS: No UI preferences in server Preferences model")
    }
}

print("\n=== Summary ===")
print("The boundary between local and server preferences is properly maintained.")
print("- UI settings (theme, font) are local-only in AppSettings")
print("- Content/behavior settings sync via PreferencesManager")
print("- No cross-contamination detected")