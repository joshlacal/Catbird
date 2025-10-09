# Catbird Release Notes - December 2024

## Overview

This release includes major improvements to the post composer, feed filtering system, GIF picker, and developer tooling. We've fixed critical UX issues and added powerful new features while maintaining full backward compatibility.

**Release Date**: December 2024  
**Previous Release**: October 4, 2024  
**Total Changes**: 69 files changed, 8,851 insertions, 545 deletions

---

## 🎯 Major Features & Fixes

### 1. Post Composer Improvements

#### URL Embed Cards - Sticky Behavior ✅
**Problem Solved**: URL preview cards would disappear when editing text around the URL, causing frustration for users trying to compose posts with link embeds.

**What's Fixed**:
- URL embed cards now stay visible when you edit text before/after the URL
- Cards persist even if you delete the URL text (you can still post with just the embed)
- Cards are only removed when you explicitly click the X button
- Matches the intuitive behavior users expect from other social media platforms

**User Experience**:
- ✅ Paste URL → Card loads automatically
- ✅ Edit text anywhere → Card stays visible
- ✅ Delete URL text → Card remains, can post with embed
- ✅ Click X button → Card is removed

#### Mention Facets - Accurate Parsing ✅
**Problem Solved**: When typing `@josh.uno hello`, the mention highlight would incorrectly extend to include "hello" and continue growing as you typed.

**What's Fixed**:
- Mention facets now stop exactly at the handle boundary
- No more expanding facets when typing after a mention
- Supports hyphens in handles (e.g., `@user-name`)
- Proper whitespace detection terminates mentions correctly

**Examples**:
- `@josh.uno hello` → Only `@josh.uno` is highlighted
- `@user.bsky.social test` → Facet ends at "social"
- `@handle-with-dash` → Hyphen is included correctly

#### Enhanced Link Detection
- Now detects links in both embeds AND text facets
- Properly handles quote posts with external links
- Better facet parsing for rich text formatting

---

### 2. Feed Filtering System Overhaul

#### Thread-Aware Filtering ✅
**Problem Solved**: Quick filters only checked the main post, missing links/media in parent or root posts within threads.

**What's Fixed**:
- Filters now check ALL posts in a thread (main + parent + root)
- "Hide Link Posts" filters entire threads if ANY post has links
- "Only Media Posts" shows threads if ANY post has media
- "Only Text Posts" filters threads if ANY post has embeds

#### Improved Filter Detection
**Hide Link Posts**:
- ✅ Detects links in embeds (external cards)
- ✅ Detects links in text via facets
- ✅ Checks parent/root posts in reply threads
- ✅ Handles quote posts with external links

**Only Media Posts**:
- ✅ Detects images and videos in embeds
- ✅ Handles quote posts with media correctly
- ✅ Checks media in parent/root posts

**Only Text Posts**:
- ✅ Filters out any posts with embeds
- ✅ Checks entire thread for embeds
- ✅ Shows only pure text-only threads

#### System Integration
- QuickFilter settings now integrate seamlessly with permanent filters
- Filter settings persist across app sessions
- Filters update instantly when toggled
- No performance impact on feed scrolling

---

### 3. GIF Picker Performance Enhancements

#### Smooth Load More Behavior ✅
**Problem Solved**: GIF cells appeared with reduced opacity or fading effects during scroll, and it was unclear whether new GIFs were loading from top or bottom.

**What's Fixed**:
- Implemented intelligent batch updates using `performBatchUpdates`
- New GIFs clearly appear from the bottom (proper append behavior)
- No flicker or opacity changes when loading more
- Existing cells stay in place and don't reload

#### Performance Improvements
- **Before**: All visible cells reconfigured on every update (~160ms)
- **After**: Only new cells configure during append (~80ms)
- 50% faster updates for load more operations
- Eliminated visual artifacts during scroll

#### Technical Implementation
- Smart detection of append vs full data changes
- Batch inserts for new items only
- Explicit alpha = 1.0 on all cells
- Falls back gracefully for edge cases

---

### 4. @Mention Typeahead Fixes

#### Reply Mode Support ✅
**Problem Solved**: @mention typeahead suggestions wouldn't appear when typing mentions in reply mode, especially if there was already a mention earlier in the text.

**What's Fixed**:
- Cursor-aware mention detection (checks where you're actually typing)
- Fixed z-index positioning (overlay instead of inline)
- Works in both single post and thread composer modes
- Typeahead appears on top of all content

#### How It Works Now
- Detects `@` at your current cursor position
- Searches for handles only before the cursor
- Validates `@` is at word boundary
- Shows suggestions immediately
- Properly positioned below text editor

---

### 5. Developer Tooling - Copilot Runner

#### Headless Task Automation
New automation tools for running development tasks without manual interaction:

**Features**:
- **copilot-runner.sh** - Bash version (simple, no dependencies)
- **copilot-runner.py** - Python version (advanced features)
- Task definitions in JSON/YAML format
- Parallel and sequential execution modes
- Security controls with granular approval flags

**Example Usage**:
```bash
# Run syntax check
./copilot-runner.sh single "syntax-check" \
  "Check all Swift files for syntax errors" \
  "--allow-tool 'shell(swift)'"

# Parallel multi-platform build
./copilot-runner.sh parallel \
  "build-ios|Build for iOS simulator|--allow-all-tools" \
  "build-macos|Build for macOS|--allow-all-tools"

# CI/CD pipeline
./copilot-runner.py from-file copilot-tasks.example.json \
  --workflow ci-pipeline \
  --sequential \
  --stop-on-failure
```

**Pre-configured Workflows**:
- `pre-commit` - Syntax check, lint, git status
- `ci-pipeline` - Full build and test suite
- `full-build` - Multi-platform builds in parallel

---

## 🎨 UI/UX Improvements

### Toast Notification System
- New `ToastNotification` component for user feedback
- Non-intrusive temporary messages
- Customizable appearance and duration
- Accessible and respects motion settings

### Accessibility Enhancements
- Enhanced accessibility settings integration
- Better font scaling management across app
- Improved VoiceOver support for new features
- Motion and transparency preferences respected

### Cross-Platform Consistency
- `CatalystButtonStyle` for optimized macOS buttons
- Consistent UI patterns across iOS and macOS
- Better handling of platform-specific interactions
- Improved typography scaling

---

## 📚 Documentation

### New Documentation Added
- **POST_COMPOSER_START_HERE.md** - Complete composer architecture guide
- **POST_COMPOSER_FIXES_APPLIED.md** - Detailed fix documentation  
- **POST_COMPOSER_URL_BEHAVIOR_ANALYSIS.md** - URL handling deep dive
- **GIF_PICKER_FIXES.md** - Collection view optimization guide
- **QUICK_FILTER_FIXES.md** - Feed filtering complete solution
- **TYPEAHEAD_FIX.md** - Mention suggestion fixes explained
- **COPILOT_RUNNER_README.md** - Automation tooling guide
- **COPILOT_RUNNER_QUICKREF.md** - Quick reference for runners

### Updated Documentation
- **CLAUDE.md** - Enhanced with iOS 26 Liquid Glass guidance
- **AGENTS.md** - Updated automation patterns

---

## 🔧 Technical Improvements

### Code Quality
- Enhanced error handling in `AuthManager`
- Improved state management patterns
- Better Swift 6 concurrency compliance
- Cleaned up deprecated code paths
- More robust async/await patterns

### Performance
- Optimized feed filtering algorithms
- Better memory management in GIF picker
- Reduced unnecessary view updates
- Improved batch update logic

### State Management
- More consistent @Observable patterns
- Better actor isolation for thread-safe operations
- Improved coordination between view models
- Cleaner state propagation

---

## 🐛 Bug Fixes

### Post Composer
- Fixed URL embed cards disappearing during text edits
- Fixed mention facets extending beyond handle boundaries
- Fixed link detection missing text-based URLs
- Fixed embed card lifecycle management issues

### Feed System
- Fixed filters not checking parent/root posts in threads
- Fixed "Hide Link Posts" missing facet-based links
- Fixed "Only Media Posts" incorrectly filtering quote posts
- Fixed thread slices showing unfiltered parent posts

### GIF Picker
- Fixed opacity/fade issues during scroll
- Fixed ambiguous load direction (top vs bottom)
- Fixed cell flicker on data reload
- Fixed performance degradation with many GIFs

### Typeahead
- Fixed @mentions not appearing in reply mode
- Fixed cursor position not being tracked
- Fixed z-index issues with typeahead positioning
- Fixed typeahead appearing behind other content

### UI/UX
- Fixed font scaling inconsistencies
- Fixed accessibility setting integration gaps
- Fixed cross-platform UI differences
- Fixed state restoration edge cases

---

## ⚙️ Breaking Changes

**None** - This release maintains full backward compatibility.

---

## 🔄 Backward Compatibility

### Fully Compatible With
- ✅ Existing drafts (all formats)
- ✅ Posted content structure
- ✅ User preferences and settings
- ✅ AT Protocol specifications
- ✅ iOS 18+ and macOS 13+ (minimum versions)
- ✅ All existing features and workflows

### Migration Notes
No migration required - all changes are backward compatible.

---

## 📦 What's Included

### Files Changed
- **69 files modified**
- **8,851 lines added** (features, fixes, documentation)
- **545 lines removed** (cleanup, optimization)

### Key Components Updated
- Post Composer system (8 files)
- Feed filtering (4 files)
- GIF picker (2 files)
- State management (5 files)
- UI components (12 files)
- Developer tooling (3 new files)
- Documentation (15 new files)

---

## 🚀 Getting Started

### For Users
1. Update to the latest version
2. All fixes are automatically active
3. No configuration needed - everything works out of the box
4. Enjoy improved post composer and feed filtering!

### For Developers
1. Review the new documentation in `/docs`
2. Check out the Copilot Runner tools for automation
3. See `POST_COMPOSER_START_HERE.md` for composer architecture
4. Use `COPILOT_RUNNER_README.md` for task automation

---

## 🔮 Future Enhancements

### Post Composer (Planned)
- Multiple embed cards (select which URL to embed)
- Card preview editing (custom titles/thumbnails)
- Link shortening support
- Rich text formatting toolbar

### Feed System (Planned)
- Custom filter rules builder
- Saved filter presets
- Advanced content filtering
- Per-feed filter settings

### Performance (Planned)
- UICollectionViewDiffableDataSource migration
- Enhanced prefetching
- Cell pre-warming for video
- Instrumentation and metrics

---

## 🙏 Acknowledgments

Thanks to all users who reported issues and provided feedback on:
- URL embed card behavior
- Mention facet parsing
- Feed filtering accuracy
- GIF picker performance
- Typeahead functionality

Your feedback drives continuous improvement!

---

## 📞 Support

For issues or questions:
- GitHub Issues: [Report a bug](https://github.com/joshlacal/Catbird/issues)
- Bluesky: [@catbird.app](https://bsky.app/profile/catbird.app)

---

**Version**: December 2024 Release  
**Commit**: 1a68afa  
**Previous Version**: October 4, 2024 (6cb6f8e)
