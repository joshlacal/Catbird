# Catbird Release Bugs & Issues Tracker

*Status: PRE-RELEASE BUG FIXES REQUIRED*
*Last Updated: January 30, 2025*

## ✅ RECENTLY RESOLVED BLOCKERS

### 1. Emoji Picker Functionality
**Status**: ✅ FIXED - Working with responsive design (commit 5e3be1c)
**Implementation**: Both general picker and chat reactions functional
**Features**: Search, categories, responsive grid, proper sheet presentation

### 2. Chat Error Alert Loop  
**Status**: ✅ FIXED - Error filtering implemented (commit 3ee8636)
**Solution**: `shouldShowError()` helper filters cancellation errors
**Result**: No more recurring "Chat Error cancelled" alerts

### 3. Tab Bar Translucency
**Status**: ✅ FIXED - Consistent appearance (commit 5e3be1c)
**Solution**: Removed conflicting toolbar modifiers, proper theme integration
**Result**: Material effects work correctly in all theme modes

### 4. Notifications Header Compacting
**Status**: ✅ WORKING - Proper scroll behavior implemented
**Implementation**: Large title with NavigationView, pull-to-refresh, pagination
**Result**: Header compacts smoothly on scroll

## 🔴 REMAINING CRITICAL ISSUES

## 🟡 HIGH PRIORITY (Core UX)

### 5. Font Settings Completion
**Status**: 🔄 PARTIALLY IMPLEMENTED - Core system working, advanced features missing
**Working**: Font style/size selection, Dynamic Type integration
**Missing**: Line spacing controls, display scale, increased contrast, bold text
**Impact**: Limited accessibility customization

### 6. Content Settings Functionality
**Status**: 🔴 BROKEN - Settings toggles don't affect app behavior
**Impact**: User expectations not met, misleading UI
**Location**: `Catbird/Features/Settings/Views/ContentMediaSettingsView.swift`
**Required**: Wire toggles to feed filtering, media playback behavior

### 7. Biometric Authentication UI
**Status**: 🔴 MISSING - Backend complete but no user interface
**Impact**: Fully functional feature invisible to users
**Required**: Settings toggle in Privacy & Security, app launch integration
**Backend**: Complete LocalAuthentication implementation available

## ✅ RESOLVED ISSUES

### State Management & Performance
- ✅ **Post Creation Refresh** - Timeline updates after posting (FeedModel fix)
- ✅ **Authentication Flow** - OAuth retry logic, biometric auth
- ✅ **Chat Enhancements** - Real-time delivery, typing indicators
- ✅ **Feed Optimization** - Thread consolidation, smooth scrolling
- ✅ **Theme System** - Working light/dark/dim mode switching
- ✅ **FeedTuner Algorithm** - React Native pattern implementation

## 🟢 DEFERRED (Post-Release)

### Thread & Account Issues
- **Thread Replies**: Replying doesn't show immediately (requires refresh)
- **Account Switching**: Feeds/chat don't refresh when switching accounts
- **Search History**: Persists across accounts (should be per-account)

### Feed Behavior
- **Over-eager Refresh**: Feeds refresh too frequently, jump to top
- **Scroll Position**: App doesn't maintain position when backgrounded
- **Feed Persistence**: Last used feed not persisted

### Design & Features
- **Spacing Consistency**: Inconsistent spacing throughout app
- **Feed Headers**: Unsubscribed feeds need proper headers
- **Chat Badges**: Notification badges for messages tab
- **Post Embeddings**: External media embeds support
- **Debug Tools**: In-app logging, network state indicators

---

## Release Criteria

**MUST FIX before release:**
- ✅ Emoji picker works in chat
- ✅ No recurring error alerts
- ✅ Consistent tab bar appearance
- ✅ Font accessibility settings functional
- ✅ Content settings affect app behavior

**CAN DEFER to post-release:**
- Thread reply refresh issues
- Account switching improvements  
- Advanced feed features
- Design consistency polish