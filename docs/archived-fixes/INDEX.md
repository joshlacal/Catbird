# Archived Fix Documentation Index

This directory contains historical fix documentation that has been resolved and archived for reference. These documents capture point-in-time fixes and debugging sessions that are no longer active issues.

## Organization

Files are organized by feature area and chronologically archived as issues are resolved.

## Categories

### Account Management
- `ACCOUNT_SWITCH_FEED_STALE_FIX.md` - Fixed stale feed data after account switching
- `FEED_STATE_ACCOUNT_SWITCH_FIX.md` - Feed state management during account switches

### Feed System
- `FEED_FEEDBACK_HEADER_REMOVAL_FIX.md` - Removed problematic feed feedback headers
- `FEED_FEEDBACK_PROXY_HEADER_FIX.md` - Fixed proxy header issues in feed feedback
- `FEED_INTERACTIONS_DID_FIX.md` - DID resolution in feed interactions
- `FEED_INTERACTIONS_PROXY_HEADER_FIX.md` - Proxy header handling for feed interactions

### Post Composer
- `POST_COMPOSER_BLUE_TEXT_FIX.md` - Fixed blue text rendering in composer
- `POST_COMPOSER_FIXES_APPLIED.md` - General composer fixes
- `POST_COMPOSER_LINK_FIXES_BUG_AND_FIX.md` - Link handling bug fixes
- `POST_COMPOSER_LINK_FIXES.md` - Link detection and formatting fixes
- `POST_COMPOSER_PHASE1_FIXES.md` - Phase 1 composer improvements
- `TYPEAHEAD_FIX.md` - Typeahead/mention suggestion fixes

### Moderation & Labels
- `LABEL_VISIBILITY_FIX.md` - Content label visibility corrections
- `LABELER_DISPLAY_FIXES.md` - Labeler UI display fixes

### UI Components
- `GIF_PICKER_FIXES.md` - GIF picker stability and UX fixes
- `QUICK_FILTER_FIXES.md` - Quick filter UI corrections
- `DRAG_DROP_CRASH_FIX.md` - Drag-and-drop crash prevention

### Platform-Specific
- `CATALYST_SANDBOX_FIX.md` - Mac Catalyst sandbox permissions

### Authentication
- `OAUTH_CALLBACK_DEBUGGING.md` - OAuth callback flow debugging

### System-Level
- `COMPILATION_FIXES.md` - Build and compilation error resolutions
- `CLIENT_SIDE_FIX_APPLIED.md` - Client-side bug fixes
- `NESTED_EMBED_DECODING_FIX.md` - Nested embed JSON decoding
- `NOTIFICATIONS_CRASH_FIX.md` - Push notification crash prevention

## Current Active Documentation

For current features and tasks, see:
- `TODO.md` - Active task list with priorities
- `AGENTS.md` - AI agent development guidelines
- Feature-specific docs in `/Features` directory
- Implementation summaries (e.g., `COMP_002_DRAFTS_UI_COMPLETION.md`)

## Usage

These archived documents are useful for:
- Understanding historical context of fixes
- Reference when similar issues arise
- Code archaeology and debugging
- Learning from past implementation approaches

## Maintenance

- Documents are moved here when the issue is fully resolved
- Files retain their original names for git history tracking
- Index is updated as new files are archived
- Consider periodic review (annually) to remove truly obsolete content
