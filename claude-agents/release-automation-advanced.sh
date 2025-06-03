#!/bin/bash

# Advanced Release Automation with Parallel Execution
# Uses GNU Parallel for maximum concurrency

# Check if GNU parallel is installed
if ! command -v parallel &> /dev/null; then
    echo "Installing GNU Parallel..."
    brew install parallel
fi

# Base directory
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="$BASE_DIR/claude-agents/logs/release_$TIMESTAMP"
mkdir -p "$LOG_DIR"

# Define all tasks as a function
run_claude_task() {
    local task_id=$1
    local model=$2
    local prompt=$3
    local log_file="$LOG_DIR/${task_id}.log"
    
    echo "[$(date)] Starting $task_id with $model" | tee -a "$log_file"
    
    cd "$BASE_DIR"
    claude -p "$prompt" --model "$model" --max-turns 10 2>&1 | tee -a "$log_file"
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        echo "[$(date)] ✅ $task_id completed successfully" | tee -a "$log_file"
        return 0
    else
        echo "[$(date)] ❌ $task_id failed" | tee -a "$log_file"
        return 1
    fi
}

# Export function for parallel
export -f run_claude_task
export BASE_DIR LOG_DIR

# Task definitions
cat << 'EOF' > "$LOG_DIR/tasks.txt"
feed-filtering-fix|opus|Fix the feed filtering in Catbird: 1. Implement hideRepliesByUnfollowed in FeedTuner.swift line 473-476 2. Ensure all content filtering settings in ContentMediaSettingsView actually affect feed display 3. Test that all filter combinations work correctly
language-filtering|opus|Implement language filtering in Catbird: 1. Uncomment and implement language filtering in ContentMediaSettingsView.swift lines 82-95 2. Add language detection to PostParser 3. Filter posts based on user language preferences
font-accessibility|sonnet|Verify font accessibility settings: 1. Check that line spacing, display scale, increased contrast, and bold text in AccessibilitySettingsView actually affect text rendering 2. Connect all settings to the rendering system 3. Test with Dynamic Type
app-passwords|sonnet|Replace App Passwords functionality coming soon placeholder in PrivacySecuritySettingsView.swift line 94 with actual implementation
moderation-lists|sonnet|Replace Moderation Lists feature coming soon in ModerationSettingsView.swift with actual list management UI
typing-indicators|sonnet|Fix typing indicators in ChatManager.swift lines 1668-1672 to use real AT Protocol events instead of simulation
feed-discovery|sonnet|Replace hardcoded discovery data in FeedDiscoveryCardsView.swift with real API calls for trending topics
quote-posts|sonnet|Complete quote post TODOs in PostManager.swift with proper creation and rendering
video-upload|sonnet|Add video upload progress indicators and compression options to MediaUploadManager.swift
EOF

# Run tasks in parallel with controlled concurrency
echo "🚀 Starting Catbird Release Automation"
echo "📁 Logs will be saved to: $LOG_DIR"
echo ""

# Silence GNU Parallel citation notice
parallel --citation 2>/dev/null || true

# Critical tasks first (Opus - limit to 2 parallel)
echo "🔴 Phase 1: Critical Tasks (Opus)"
grep "|opus|" "$LOG_DIR/tasks.txt" | while IFS='|' read -r task_id model prompt; do
    echo "$task_id" "$model" "$prompt"
done | parallel -j 2 --colsep ' ' run_claude_task {1} {2} {3..}

# High priority tasks (Sonnet - up to 4 parallel)
echo ""
echo "🟡 Phase 2: High Priority Tasks (Sonnet)"
grep "|sonnet|" "$LOG_DIR/tasks.txt" | while IFS='|' read -r task_id model prompt; do
    echo "$task_id" "$model" "$prompt"
done | parallel -j 4 --colsep ' ' run_claude_task {1} {2} {3..}

# Generate summary
echo ""
echo "📊 Execution Summary"
echo "==================="
successful=$(grep -l "completed successfully" "$LOG_DIR"/*.log 2>/dev/null | wc -l)
failed=$(grep -l "failed" "$LOG_DIR"/*.log 2>/dev/null | grep -v "completed successfully" | wc -l)

echo "✅ Successful: $successful"
echo "❌ Failed: $failed"
echo ""
echo "📁 Full logs available at: $LOG_DIR"

# Optional: Open logs in VS Code
if command -v code &> /dev/null; then
    read -p "Open logs in VS Code? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        code "$LOG_DIR"
    fi
fi