# Catbird Settings Implementation Plan

## Executive Summary

**The Problem**: Catbird currently has beautiful, professional-looking settings UI that doesn't actually work. Users can toggle switches, change selections, and adjust sliders, but these changes don't affect the app's behavior. This creates a frustrating user experience and undermines trust in the application.

**The Solution**: Implement a phased approach to make settings actually functional, starting with the most visible features (theme, font) and gradually expanding. Hide non-functional settings until they're properly implemented to maintain user trust.

## Current State Assessment (Brutal Honesty)

### ❌ COMPLETELY NON-FUNCTIONAL
**Account Settings**:
- ❌ Email editing (OAuth limitation - impossible)
- ❌ Handle editing (AT Protocol capability unknown)
- ❌ Password changes (possible but not implemented)
- ❌ App passwords (possible but not implemented)

**Appearance Settings**:
- ❌ Theme switching (ThemeManager exists but doesn't work)
- ❌ Font scaling (FontScaleManager exists but text doesn't use it)
- ❌ Font style switching (no views use the font design)

**Content & Media Settings**:
- ❌ Autoplay videos (video players ignore setting)
- ❌ Open links in-app (URLHandler ignores setting)
- ❌ Show trending topics/videos (not connected to discovery)
- ❌ Hide replies/reposts (not connected to feed display)
- ❌ Thread sort order (not connected to thread rendering)

**Accessibility Settings**:
- ❌ Motion reduction (animations unchanged)
- ❌ Auto-play videos (duplicate setting, not working)
- ❌ Display settings (no UI changes)
- ❌ Alt text requirements (composer ignores setting)

### ✅ PARTIALLY FUNCTIONAL
- ✅ Settings persistence (AppSettings saves to SwiftData)
- ✅ Server preference sync (PreferencesManager works for server settings)
- ✅ Settings UI navigation (looks professional)

## Immediate Actions (This Week)

### 1. Hide Misleading Settings
```swift
// AccountSettingsView.swift - Hide OAuth-impossible features
Section("ACCOUNT INFORMATION") {
    // Hide email editing entirely for OAuth users
    if authManager.authType != .oauth {
        EmailSettingRow()
    }
    
    // Show handle editing as "Coming Soon"
    HStack {
        Text("Handle")
        Spacer()
        Text("Coming Soon")
            .foregroundStyle(.secondary)
    }
}
```

### 2. Fix Theme Switching
**Problem**: ThemeManager exists but doesn't propagate changes properly.

**Solution**:
```swift
// Fix ThemeManager to work with SwiftUI environment
@Observable final class ThemeManager {
    @Published var currentTheme: ColorScheme?
    
    func applyTheme(theme: String, darkMode: String) {
        // Apply to all windows immediately
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene {
                for window in windowScene.windows {
                    switch theme {
                    case "light": window.overrideUserInterfaceStyle = .light
                    case "dark": window.overrideUserInterfaceStyle = .dark
                    default: window.overrideUserInterfaceStyle = .unspecified
                    }
                }
            }
        }
    }
}
```

### 3. Fix Font Scaling
**Problem**: Views use `.font()` instead of `.scaledFont()`.

**Solution**: Convert high-impact views first:
```swift
// Priority order for font conversion:
1. PostView.swift - Most visible text
2. FeedPost.swift - Timeline content
3. ThreadView.swift - Thread content
4. Navigation titles and headers
5. Settings screens themselves
```

### 4. Add Setting Status Indicators
```swift
struct SettingRow: View {
    let title: String
    let isImplemented: Bool
    
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if !isImplemented {
                Text("Coming Soon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
```

## Implementation Roadmap

### Phase 1: Core UI Settings (Week 1-2)
**Goal**: Make theme and font settings actually work

**Tasks**:
1. ✅ Fix ThemeManager to properly apply themes
2. ✅ Convert PostView to use scaledFont
3. ✅ Convert FeedPost to use scaledFont  
4. ✅ Test theme switching with navigation, sheets, alerts
5. ✅ Test font scaling throughout the app
6. ✅ Add true black vs dim dark mode switching

**Success Criteria**:
- Theme changes are immediately visible app-wide
- Font size changes affect all text
- Settings persist across app restarts
- No visual glitches or inconsistencies

### Phase 2: Content & Media Settings (Week 3-4)
**Goal**: Make content filtering and media settings functional

**Tasks**:
1. Connect autoplay setting to VideoCoordinator
2. Connect link handling to URLHandler
3. Implement feed filtering (hide replies/reposts)
4. Connect thread sort order to ThreadManager
5. Wire up external media toggles

**Success Criteria**:
- Videos respect autoplay setting
- Links open in-app or externally based on setting
- Feed content is filtered according to preferences
- Thread sorting actually changes order

### Phase 3: Accessibility Settings (Week 5-6)
**Goal**: Make accessibility settings affect app behavior

**Tasks**:
1. Implement motion reduction (replace animations with crossfade)
2. Add display contrast/bold text support
3. Integrate alt text requirements with composer
4. Add haptic feedback controls
5. Test with VoiceOver and accessibility tools

**Success Criteria**:
- Motion settings actually reduce animations
- Display settings improve visibility
- Alt text enforcement works in composer
- App meets accessibility guidelines

### Phase 4: Account Management (Week 7-8)
**Goal**: Implement possible account features

**Tasks**:
1. Research AT Protocol handle changing capability
2. Implement password change functionality
3. Add app password management
4. Implement data export feature
5. Add account deletion flow (if possible)

**Success Criteria**:
- Password changes work securely
- Data export provides comprehensive user data
- Account management matches Bluesky web capabilities

## Technical Implementation Details

### Theme Switching Architecture
```swift
// AppState integration
class AppState {
    @Published var themeManager = ThemeManager()
    
    init() {
        // Observe setting changes and apply immediately
        $appSettings.theme.sink { theme in
            themeManager.applyTheme(theme, darkMode: appSettings.darkThemeMode)
        }
    }
}

// View integration
struct ContentView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        // Apply theme environment
        MainView()
            .preferredColorScheme(appState.themeManager.currentScheme)
            .onAppear {
                appState.themeManager.applyInitialTheme()
            }
    }
}
```

### Font Scaling Implementation
```swift
// Convert existing text views
// BEFORE:
Text("Hello World")
    .font(.headline)

// AFTER:
Text("Hello World")
    .scaledFont(size: Typography.Size.headline, weight: .semibold)

// Systematic replacement strategy:
1. Use grep to find all .font() usages
2. Replace with .scaledFont() based on context
3. Test each conversion for proper scaling
4. Ensure Dynamic Type compatibility
```

### Content Filtering Integration
```swift
// Connect settings to content display
struct PostView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        // Check content filtering settings
        if shouldShowPost() {
            PostContentView(post: post)
        } else {
            ContentFilteredView(reason: filterReason)
        }
    }
    
    private func shouldShowPost() -> Bool {
        // Check AppSettings for local filtering
        if post.isReply && !appState.appSettings.showReplies {
            return false
        }
        
        // Check server preferences for content labels
        return appState.preferencesManager.shouldShowContent(post)
    }
}
```

## Testing & Validation Strategy

### Automated Testing
```swift
// Unit tests for managers
func testThemeManager() {
    let manager = ThemeManager()
    manager.applyTheme("dark", darkMode: "black")
    XCTAssertEqual(manager.useTrueBlack, true)
}

// Integration tests for settings
func testSettingsPersistence() {
    appSettings.theme = "dark"
    // Restart app simulation
    let newAppSettings = AppSettings()
    XCTAssertEqual(newAppSettings.theme, "dark")
}
```

### Manual Testing Checklist
- [ ] Theme changes apply immediately to all screens
- [ ] Font changes affect all text throughout app
- [ ] Settings persist after app restart
- [ ] Navigation, sheets, alerts respect theme
- [ ] Content filtering actually filters content
- [ ] Media settings affect video/link behavior
- [ ] Accessibility settings improve usability

### User Testing Protocol
1. Give user app with settings
2. Ask them to change theme - does it work?
3. Ask them to change font size - does it work?
4. Ask them to toggle content settings - does it work?
5. Note any confusion or frustration

## User Experience Guidelines

### Setting Status Communication
```swift
enum SettingStatus {
    case working           // ✅ Fully functional
    case comingSoon       // 🚧 Planned implementation
    case limitedByOAuth   // 🔒 OAuth restriction
    case serverControlled // 🌐 Managed by Bluesky
}

struct SettingRowView: View {
    let status: SettingStatus
    
    var statusIndicator: some View {
        switch status {
        case .working:
            EmptyView()
        case .comingSoon:
            Text("Coming Soon").foregroundStyle(.secondary)
        case .limitedByOAuth:
            Text("OAuth Limited").foregroundStyle(.orange)
        case .serverControlled:
            Text("Synced").foregroundStyle(.blue)
        }
    }
}
```

### Progressive Enhancement
1. **Week 1**: Show only working settings (theme, basic font)
2. **Week 2**: Add "Coming Soon" for planned features
3. **Week 3**: Gradually unhide implemented features
4. **Week 4**: Full settings experience

### Error Handling
```swift
// Provide feedback when settings fail to apply
func applyThemeSetting(_ theme: String) {
    do {
        try themeManager.applyTheme(theme)
        showToast("Theme applied successfully")
    } catch {
        showToast("Failed to apply theme: \(error.localizedDescription)")
        // Revert setting to previous value
        appSettings.theme = previousTheme
    }
}
```

## Long-Term Vision (6 months)

### Advanced Customization
- Custom accent colors
- Font family selection beyond system fonts
- Advanced accessibility options
- Export/import settings
- Per-account settings profiles

### Integration Excellence
- Seamless Dynamic Type support
- Perfect accessibility compliance
- System settings integration where appropriate
- Instant setting application with smooth transitions

### User Trust
- Every visible setting works
- Clear communication about feature status
- Reliable persistence and sync
- Professional, polished experience

## Accountability Measures

### Development Standards
1. **No setting is shown until it works**
2. **Every setting must have a test case**
3. **Settings must provide user feedback**
4. **Changes must be immediately visible**

### Quality Gates
- [ ] All theme changes apply within 100ms
- [ ] Font scaling works across all text sizes
- [ ] Settings persist across app kills
- [ ] No console errors related to settings
- [ ] Accessibility audit passes

### Success Metrics
- **User Satisfaction**: Settings work as expected
- **Feature Adoption**: Users actively customize their experience
- **Support Burden**: Reduced complaints about broken features
- **App Store Reviews**: Improved ratings for customization

## Resource Allocation

### High Impact, Low Effort (Priority 1)
- Hide OAuth-impossible account settings
- Fix theme switching
- Add "Coming Soon" labels

### High Impact, Medium Effort (Priority 2)
- Font scaling throughout app
- Content filtering integration
- Media playback settings

### Medium Impact, High Effort (Priority 3)
- Full accessibility implementation
- Advanced account management
- Data export functionality

### Low Impact (Future Consideration)
- Custom accent colors
- Advanced typography options
- Complex animation preferences

## Conclusion

The current settings experience undermines user trust by promising functionality that doesn't exist. This plan prioritizes rebuilding that trust through working features over impressive-looking but broken UI.

**Key Principles**:
1. **Under-promise, over-deliver** - Only show what works
2. **Immediate feedback** - Settings apply instantly with user confirmation
3. **Honest communication** - Clear status for all features
4. **Quality over quantity** - 3 working settings > 20 broken ones

**Next Steps**:
1. Implement Phase 1 (theme/font fixes) immediately
2. Hide all non-functional settings with appropriate messaging
3. Begin systematic testing of each setting
4. Gradually expand functionality based on user feedback

This approach will transform Catbird's settings from a source of frustration into a competitive advantage through genuinely functional customization.