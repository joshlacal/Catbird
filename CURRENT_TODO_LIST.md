# Catbird Current Todo List

## Status: PRE-RELEASE BUG FIXES
*Last Updated: January 30, 2025*

## 🔴 CRITICAL RELEASE BLOCKERS (Must Fix Immediately)

### Week 1: Critical Functionality
1. **Fix emoji picker functionality** - Currently broken in chat interface
2. **Fix recurring 'Chat Error cancelled' alert** - Blocking user interaction  
3. **Fix inconsistent tab bar translucency** - Visual inconsistency across screens

### Week 2: Core UX Issues  
4. **Implement notifications header compacting** when scrolling
5. **Implement missing font settings** - style, size, line spacing, accessibility, display scale, contrast, bold text

## 🟡 HIGH PRIORITY (Feature Completion)

### Week 3: Functional Settings
6. **Fix non-functional Content & Media settings** - toggles don't affect behavior
7. **Implement server-provided video thumbnails** for non-auto played videos
8. **Allow external media embeds** for approved services (YouTube, Vimeo, etc.)

### Week 4: Polish & Testing
9. **Fix Account settings screen layout** and functionality issues
10. **Comprehensive integration testing** and release preparation

## 🟢 DEFERRED (Post-Release)

### Future Improvements
11. **Add feed headers** for unsubscribed feeds (icon, name, description, subscribe button)
12. **Make search history per-account** instead of global  
13. **Add notification badges** to messages tab
14. **Implement local polling** for chat messages
15. **Standardize spacing** throughout the app for design consistency

---

## Implementation Strategy

**RELEASE-FOCUSED APPROACH**: All development now prioritized around getting a stable, polished release ready.

### Phase 1 Foundation ✅ COMPLETED
- StateInvalidationBus integration complete
- Theme system optimizations complete  
- Authentication improvements complete

### Phase 2: Release Blockers (Current Focus)
See detailed implementation in `RELEASE_IMPLEMENTATION_GUIDE.md`

### Success Criteria for Release
✅ Zero critical bugs in user testing
✅ All core features working as expected
✅ Consistent visual design across app
✅ Font accessibility properly implemented  
✅ Chat functionality stable and reliable

## Next Actions
Follow the detailed implementation plan in `RELEASE_IMPLEMENTATION_GUIDE.md` to address all release-blocking issues in priority order.