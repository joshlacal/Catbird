# Catbird Current Todo List

## Status: Active Development Tasks
*Last Updated: January 29, 2025*

## 🔴 HIGH PRIORITY (State Management Foundation)

### Phase 1: Foundation Work
1. **State Architecture Foundation** - Audit AppState, FeedModel, PostShadowManager usage
2. **Implement StateInvalidationBus** for centralized event coordination  
3. **Set up comprehensive logging infrastructure** with OSLog categories

### Critical Bug Fixes
4. **Fix post creation → timeline refresh issue**
5. **Fix thread replies not showing immediately**
6. **Fix account switching** - feeds/chat don't refresh properly

## 🟡 MEDIUM PRIORITY (UX Improvements)

### Debug & Monitoring
7. **Create DebugStateView** for runtime state inspection
8. **Resolve over-eager feed refresh** and scroll position loss
9. **Implement proper error states** instead of blank content

### Feature Improvements  
10. **Add feed headers** for unsubscribed feeds (icon, name, description, subscribe button)
11. **Make search history per-account** instead of global
12. **Add notification badges** to messages tab
13. **Implement local polling** for chat messages

## 🟢 LOW PRIORITY (Polish & Features)

### Design & Features
14. **Standardize spacing** throughout the app for design consistency
15. **Implement post embeddings** support
16. **Clean up and expand Settings** with more comprehensive options

---

## Implementation Notes

This list follows the 4-phase bug fix plan documented in `BUG_FIX_PLAN.md`:

- **Phase 1 (Week 1-2)**: Foundation - Tasks 1-3
- **Phase 2 (Week 2-3)**: Core Refresh Fixes - Tasks 4-6  
- **Phase 3 (Week 3-4)**: Error Handling & UX - Tasks 7-13
- **Phase 4 (Week 4-5)**: UI Polish & Features - Tasks 14-16

## Next Actions
Start with Phase 1 foundation work to establish proper state management infrastructure before tackling the specific refresh bugs.