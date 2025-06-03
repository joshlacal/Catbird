#!/bin/bash

# Quick parallel agent launcher using Terminal tabs
# Opens each agent in a new tab for easy monitoring

echo "🚀 Quick Parallel Agent Launcher"
echo "================================"
echo ""

# Base directory
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BASE_DIR"

# Critical tasks
declare -a CRITICAL_TASKS=(
    "opus|Fix the feed filtering in Catbird: 1. Implement hideRepliesByUnfollowed in FeedTuner.swift line 473-476 2. Ensure all content filtering settings in ContentMediaSettingsView actually affect feed display 3. Test that all filter combinations work correctly 4. The filtering logic is partially there but needs completion"
    "opus|Implement language filtering in Catbird: 1. Uncomment and implement language filtering in ContentMediaSettingsView.swift lines 82-95 2. Add language detection to PostParser using LanguageDetector utility 3. Filter posts based on user language preferences in FeedTuner 4. Test with multiple languages"
)

# High priority tasks  
declare -a HIGH_TASKS=(
    "sonnet|Verify and complete font accessibility settings: 1. Check that line spacing, display scale, increased contrast, and bold text in AccessibilitySettingsView actually affect text rendering 2. These settings exist in the UI but may not be connected to the rendering system 3. Look at Typography.swift and ensure all settings are applied 4. Test with Dynamic Type at all sizes"
    "sonnet|Replace App Passwords functionality coming soon placeholder: 1. In PrivacySecuritySettingsView.swift line 94, implement actual app passwords 2. Add UI for creating/revoking app-specific passwords 3. Store securely in Keychain 4. Use ATProtoClient for API calls" 
    "sonnet|Fix typing indicators in ChatManager.swift: 1. Replace simulated typing (lines 1668-1672) with real AT Protocol events 2. Implement sendTypingIndicator and receiveTypingIndicator 3. Use WebSocket or polling for real-time updates 4. Test across multiple devices"
)

# Function to open in new Terminal tab
open_in_tab() {
    local model=$1
    local prompt=$2
    local title=$3
    
    osascript <<EOF
tell application "Terminal"
    activate
    tell application "System Events" to keystroke "t" using {command down}
    delay 0.5
    do script "cd '$BASE_DIR' && echo '🤖 $title' && echo '📋 Model: $model' && echo '' && claude --model '$model' '$prompt'" in front window
end tell
EOF
}

# Alternative: Use iTerm2 if available
open_in_iterm_tab() {
    local model=$1
    local prompt=$2
    local title=$3
    
    osascript <<EOF
tell application "iTerm"
    tell current window
        create tab with default profile
        tell current session
            write text "cd '$BASE_DIR'"
            write text "echo '🤖 $title'"
            write text "echo '📋 Model: $model'"
            write text "echo ''"
            write text "claude --model '$model' '$prompt'"
        end tell
    end tell
end tell
EOF
}

# Check which terminal to use
if [[ -d "/Applications/iTerm.app" ]]; then
    echo "Using iTerm2..."
    OPEN_FUNC="open_in_iterm_tab"
else
    echo "Using Terminal.app..."
    OPEN_FUNC="open_in_tab"
fi

echo ""
echo "🔴 Launching Critical Tasks (Opus)..."

# Launch critical tasks
counter=1
for task in "${CRITICAL_TASKS[@]}"; do
    IFS='|' read -r model prompt <<< "$task"
    $OPEN_FUNC "$model" "$prompt" "Critical Task $counter"
    ((counter++))
    sleep 1
done

echo ""
read -p "Press enter to launch high-priority tasks..."

echo "🟡 Launching High Priority Tasks (Sonnet)..."

# Launch high priority tasks
counter=1
for task in "${HIGH_TASKS[@]}"; do
    IFS='|' read -r model prompt <<< "$task"
    $OPEN_FUNC "$model" "$prompt" "High Priority $counter"
    ((counter++))
    sleep 1
done

echo ""
echo "✅ All agents launched in separate tabs!"
echo ""
echo "Tips:"
echo "- Each tab is running an interactive Claude session"
echo "- You can ask follow-up questions in each tab"
echo "- Use Cmd+Shift+[ or ] to switch between tabs"
echo "- Monitor all agents simultaneously"
echo ""

# Optional: Show status monitoring
read -p "Launch monitoring window? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    $OPEN_FUNC "bash" "./claude-agents/monitor-agents.sh" "Monitor"
fi