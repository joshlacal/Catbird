#!/bin/bash

# Catbird Project - Untrack Development Files
# This script removes development files from git tracking while keeping them locally

echo "🔓 Untracking development files from git..."
echo ""

# Untrack development markdown files
echo "📄 Untracking development documentation..."
git rm --cached CLAUDE.md 2>/dev/null || echo "  - CLAUDE.md not tracked"
git rm --cached BUGS_AND_ISSUES.md 2>/dev/null || echo "  - BUGS_AND_ISSUES.md not tracked"
git rm --cached BUG_FIX_PLAN.md 2>/dev/null || echo "  - BUG_FIX_PLAN.md not tracked"
git rm --cached CURRENT_TODO_LIST.md 2>/dev/null || echo "  - CURRENT_TODO_LIST.md not tracked"
git rm --cached BACKUP_INFRASTRUCTURE_IMPLEMENTATION.md 2>/dev/null || echo "  - BACKUP_INFRASTRUCTURE_IMPLEMENTATION.md not tracked"
git rm --cached DOCUMENTATION_CLEANUP_SUMMARY.md 2>/dev/null || echo "  - Not tracked"
git rm --cached EXPERIMENTAL_CAR_PARSER_IMPLEMENTATION.md 2>/dev/null || echo "  - Not tracked"
git rm --cached EXPERIMENTAL_MIGRATION_SYSTEM.md 2>/dev/null || echo "  - Not tracked"
git rm --cached FEED_DISCOVERY_IMPROVEMENTS.md 2>/dev/null || echo "  - Not tracked"
git rm --cached FEED_HEADERS_PLAN.md 2>/dev/null || echo "  - Not tracked"
git rm --cached FEED_PREVIEW_IMPLEMENTATION.md 2>/dev/null || echo "  - Not tracked"
git rm --cached FEED_WIDGET_IMPLEMENTATION.md 2>/dev/null || echo "  - Not tracked"
git rm --cached MCP_SIMULATOR_SETUP.md 2>/dev/null || echo "  - Not tracked"
git rm --cached RELEASE_IMPLEMENTATION_GUIDE.md 2>/dev/null || echo "  - Not tracked"
git rm --cached REPOSITORY_BROWSER_IMPLEMENTATION.md 2>/dev/null || echo "  - Not tracked"
git rm --cached SETTINGS_IMPLEMENTATION_PLAN.md 2>/dev/null || echo "  - Not tracked"
git rm --cached SETTINGS_IMPROVEMENTS_SUMMARY.md 2>/dev/null || echo "  - Not tracked"
git rm --cached SIMULATOR_AUTOMATION_GUIDE.md 2>/dev/null || echo "  - Not tracked"
git rm --cached TESTING_COOKBOOK.md 2>/dev/null || echo "  - Not tracked"
git rm --cached WORKTREE_PLAN.md 2>/dev/null || echo "  - Not tracked"

# Untrack scripts
echo "🔧 Untracking helper scripts..."
git rm --cached TEST_SETTINGS_BOUNDARY.swift 2>/dev/null || echo "  - Not tracked"
git rm --cached catbird_sim_helper.sh 2>/dev/null || echo "  - Not tracked"
git rm --cached setup-local-claude-system.sh 2>/dev/null || echo "  - Not tracked"

# Untrack screenshots and test images (but NOT app icons)
echo "🖼️  Untracking test screenshots..."
git rm --cached current_app_screenshot.png 2>/dev/null || echo "  - Not tracked"
git rm --cached current_genmoji_test.png 2>/dev/null || echo "  - Not tracked"
git rm --cached current_screen.png 2>/dev/null || echo "  - Not tracked"
git rm --cached debug_paste_test.png 2>/dev/null || echo "  - Not tracked"
git rm --cached screenshot.png 2>/dev/null || echo "  - Not tracked"
git rm --cached screenshot_check.png 2>/dev/null || echo "  - Not tracked"
git rm --cached test_screenshot.png 2>/dev/null || echo "  - Not tracked"

# Untrack log files
echo "📋 Untracking log files..."
git rm --cached "logs jun 4 1323.txt" 2>/dev/null || echo "  - Not tracked"
git rm --cached "logs jun 5 505.txt" 2>/dev/null || echo "  - Not tracked"

# Keep the scripts we just created from being tracked
git rm --cached update-gitignore-for-public.sh 2>/dev/null || echo "  - Not tracked"
git rm --cached backup-dev-files.sh 2>/dev/null || echo "  - Not tracked"
git rm --cached untrack-dev-files.sh 2>/dev/null || echo "  - Not tracked"

echo ""
echo "✅ Untracking complete!"
echo ""
echo "📝 These files are now untracked but remain on your local filesystem."
echo "   They will be ignored in future commits due to .gitignore rules."
echo ""
echo "Next steps:"
echo "1. Review changes: git status"
echo "2. Commit the removal of tracked dev files: git commit -m 'Remove development files from tracking'"
echo "3. Continue with public release preparation"
