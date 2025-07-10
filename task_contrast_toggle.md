# Task: Fix Accessibility Low Contrast Toggle

## Priority: MEDIUM

## Issue Description
Accessibility low contrast toggle is not working, preventing users from adjusting contrast settings.

## Investigation Steps
1. Find accessibility settings implementation
2. Check contrast toggle logic
3. Review theme system integration
4. Test contrast changes across the app

## Key Files to Examine
- `Catbird/Features/Settings/Views/AccessibilitySettingsView.swift`
- `Catbird/Core/State/ThemeManager.swift`
- `Catbird/Core/UI/ThemeColors.swift`
- `Catbird/Core/State/PreferencesManager.swift`

## Expected Outcome
Low contrast toggle should affect app-wide contrast settings.