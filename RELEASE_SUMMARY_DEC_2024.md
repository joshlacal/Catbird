# Release Summary - December 2024

**Released**: December 2024  
**Previous Release**: October 4, 2024  
**Changes**: 69 files, 8,851 additions, 545 deletions

## Key Highlights

### 🎯 Post Composer
- **Sticky URL Cards**: Embed cards now stay visible when editing text (no more disappearing!)
- **Fixed Mention Parsing**: @handles no longer extend into following text
- **Better Link Detection**: Detects links in both embeds and text facets

### 📊 Feed Filtering  
- **Thread-Aware Filters**: Now checks parent/root posts in threads, not just the main post
- **Improved Detection**: "Hide Link Posts" catches facet-based links, "Only Media Posts" handles quote posts correctly
- **Complete Thread Filtering**: Entire threads are filtered if ANY post matches criteria

### 🎬 GIF Picker
- **Smooth Loading**: No more flicker or opacity issues during scroll
- **Clear Append**: New GIFs clearly load from bottom (not top)
- **50% Faster**: Only new cells configure, not all visible cells

### 💬 Typeahead
- **Reply Mode Fixed**: @mention suggestions now work in replies
- **Cursor-Aware**: Detects mentions where you're actually typing
- **Better Positioning**: Appears on top, not behind content

### 🛠️ Developer Tools
- **Copilot Runner**: New headless task automation (parallel/sequential execution)
- **Pre-configured Workflows**: pre-commit, ci-pipeline, full-build
- **Task Definitions**: JSON/YAML based, reusable automation

## Bug Fixes

✅ URL embed cards disappearing during text edits  
✅ Mention facets extending beyond handle boundaries  
✅ Filters missing parent/root posts in threads  
✅ GIF picker opacity/fade issues  
✅ Typeahead not appearing in reply mode  
✅ Link detection missing facet-based URLs  
✅ Media filter incorrectly handling quote posts

## Documentation

📚 15 new documentation files covering:
- Complete post composer architecture
- Feed filtering implementation details
- GIF picker optimizations
- Copilot runner automation guide
- Comprehensive fix documentation

## Technical

- Enhanced error handling and state management
- Better Swift 6 concurrency compliance
- Improved performance across board
- Full backward compatibility (no breaking changes)

## Getting the Update

```bash
git pull origin main
```

All features are automatically active - no configuration needed!

---

**Full Release Notes**: See `RELEASE_NOTES_DEC_2024.md`  
**Commit**: 1a68afa → main  
**Status**: ✅ Live on GitHub
