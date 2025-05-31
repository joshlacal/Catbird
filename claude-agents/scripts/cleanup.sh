#!/bin/bash
echo "🧹 Cleaning up worktrees and temporary files..."

# Clean up old worktrees
find worktrees -maxdepth 1 -type d -name "workflow-*" -mtime +1 -exec rm -rf {} \; 2>/dev/null

# Clean up old results
find shared/results -name "*.json" -mtime +7 -delete 2>/dev/null

# Clean up old logs
find logs -name "*.log" -mtime +3 -delete 2>/dev/null

echo "✅ Cleanup completed"
