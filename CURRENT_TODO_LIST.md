# Catbird Release Todo List

## Status: PRE-RELEASE BUG FIXES REQUIRED
*Last Updated: January 30, 2025*

## ✅ RECENTLY RESOLVED (Commits 5e3be1c, 3ee8636)

### 1. Emoji Picker Functionality ✅
- **Status**: WORKING - Fully functional with responsive design
- **Fixed**: Both general emoji picker and chat reactions
- **Features**: Search, categories, responsive grid layout

### 2. Chat Error Alert Loop ✅
- **Status**: RESOLVED - No more recurring "Chat Error cancelled" alerts
- **Fixed**: Proper error filtering, Task cancellation handling
- **Implementation**: `shouldShowError()` helper filters cancellation errors

### 3. Tab Bar Translucency ✅
- **Status**: FIXED - Consistent appearance across all screens
- **Fixed**: Removed conflicting toolbar modifiers, proper theme integration
- **Result**: Proper material effects in light/dark/dim modes

### 4. Notifications Header ✅
- **Status**: WORKING - Header compacts properly on scroll
- **Implementation**: Large title with proper scroll behavior
- **Features**: Pull-to-refresh, pagination, filter integration

## 🔴 REMAINING CRITICAL ISSUES

### 5. Font Settings 🔄
- **Issue**: Font system partially implemented, missing advanced accessibility options
- **Working**: Basic font style/size selection, Dynamic Type integration
- **Missing**: Line spacing controls, display scale, increased contrast, bold text
- **Status**: Core system working, needs completion

### 6. Content Settings 🚫
- **Issue**: Toggles don't affect app behavior
- **Impact**: Broken user expectations
- **File**: `ContentMediaSettingsView.swift`
- **Status**: Needs feed filtering integration

### 7. Biometric Authentication Settings 🚫
- **Issue**: Backend fully implemented but no UI settings
- **Impact**: Feature invisible to users
- **Missing**: Settings toggle in Privacy & Security
- **Status**: Needs UI implementation only

## ✅ COMPLETED

### Core Infrastructure
- ✅ **Authentication System** - OAuth retry, biometric auth, error handling
- ✅ **Feed Performance** - Thread consolidation, smooth scrolling, prefetching
- ✅ **Chat Enhancements** - Real-time delivery, typing indicators, reactions
- ✅ **Theme System** - Working light/dark/dim switching
- ✅ **StateInvalidationBus** - Central event coordination
- ✅ **FeedTuner Algorithm** - React Native pattern implementation

## 🟢 DEFERRED (Post-Release)

### Thread & Account Management
- Thread replies don't show immediately (needs refresh)
- Account switching doesn't refresh feeds/chat
- Search history persists across accounts

### Polish & Enhancement
- Feed headers for unsubscribed feeds
- Notification badges for messages tab
- Local polling for chat messages
- Spacing consistency throughout app
- Video thumbnails for non-autoplay
- External media embeds (YouTube, Vimeo)

---

## Release Success Criteria

**Required for Release:**
- ✅ Emoji picker works in chat
- ✅ No recurring error alerts
- ✅ Tab bar appearance consistent
- ✅ Notifications header compacts properly
- ✅ Font settings functional and accessible
- ✅ Content settings affect app behavior

**Post-Release Improvements:**
- Enhanced thread management
- Better account switching UX
- Advanced feed features
- Design consistency polish

## Implementation Order

**Week 1**: Critical fixes (emoji, chat errors, tab bar)
**Week 2**: UX improvements (notifications header, font settings)  
**Week 3**: Functional settings (content filters)
**Week 4**: Testing & release preparation

*See `RELEASE_IMPLEMENTATION_GUIDE.md` for detailed implementation steps.*