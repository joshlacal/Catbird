#!/bin/bash

# Launch multiple interactive Claude agents in separate terminals
# Each agent gets its own terminal window for full interaction

echo "🚀 Launching Interactive Claude Agents"
echo "====================================="
echo ""

# Define all release tasks
declare -A TASKS=(
    ["feed-filtering"]="Fix the feed filtering in Catbird: 1. Implement hideRepliesByUnfollowed in FeedTuner.swift line 473-476 2. Ensure all content filtering settings in ContentMediaSettingsView actually affect feed display 3. Test that all filter combinations work correctly"
    ["language-filtering"]="Implement language filtering in Catbird: 1. Uncomment and implement language filtering in ContentMediaSettingsView.swift lines 82-95 2. Add language detection to PostParser using LanguageDetector utility 3. Filter posts based on user's language preferences in FeedTuner"
    ["font-accessibility"]="Verify font accessibility settings: 1. Check that line spacing, display scale, increased contrast, and bold text in AccessibilitySettingsView actually affect text rendering 2. Connect all settings to the rendering system 3. Test with Dynamic Type"
    ["app-passwords"]="Replace App Passwords functionality coming soon placeholder in PrivacySecuritySettingsView.swift line 94 with actual implementation"
    ["moderation-lists"]="Replace Moderation Lists feature coming soon in ModerationSettingsView.swift with actual list management UI"
)

declare -A MODELS=(
    ["feed-filtering"]="opus"
    ["language-filtering"]="opus"
    ["font-accessibility"]="sonnet"
    ["app-passwords"]="sonnet"
    ["moderation-lists"]="sonnet"
)

# Function to launch agent in new terminal
launch_agent() {
    local task_name=$1
    local prompt="${TASKS[$task_name]}"
    local model="${MODELS[$task_name]}"
    local window_title="Claude Agent: $task_name ($model)"
    
    # Create a temporary script for this agent
    local script_file="/tmp/claude_agent_${task_name}.sh"
    cat > "$script_file" << EOF
#!/bin/bash
cd "$PWD"
echo "🤖 Claude Agent: $task_name"
echo "📋 Model: $model"
echo "=" 
echo ""
echo "📝 Task:"
echo "$prompt"
echo ""
echo "=========================================="
echo "Starting interactive Claude session..."
echo "=========================================="
echo ""

# Start Claude with initial prompt
claude --model "$model" "$prompt"

# Keep terminal open
echo ""
echo "Press any key to close this window..."
read -n 1
EOF
    
    chmod +x "$script_file"
    
    # Detect terminal and launch
    if [[ "$TERM_PROGRAM" == "iTerm.app" ]]; then
        # iTerm2
        osascript <<EOF
tell application "iTerm"
    create window with default profile
    tell current session of current window
        set name to "$window_title"
        write text "bash $script_file"
    end tell
end tell
EOF
    elif [[ "$TERM_PROGRAM" == "Apple_Terminal" ]]; then
        # Terminal.app
        osascript <<EOF
tell application "Terminal"
    do script "bash $script_file"
    set custom title of window 1 to "$window_title"
end tell
EOF
    else
        # Generic terminal (tries to use system default)
        open -a Terminal "$script_file"
    fi
}

# Function to launch in tmux (alternative)
launch_tmux_session() {
    echo "🖥️  Launching agents in tmux session..."
    
    # Create new tmux session
    tmux new-session -d -s catbird-agents
    
    # Create panes for each agent
    local first=true
    for task in "${!TASKS[@]}"; do
        if [ "$first" = true ]; then
            first=false
            tmux send-keys -t catbird-agents "claude --model ${MODELS[$task]} \"${TASKS[$task]}\"" C-m
        else
            tmux split-window -t catbird-agents
            tmux send-keys -t catbird-agents "claude --model ${MODELS[$task]} \"${TASKS[$task]}\"" C-m
        fi
    done
    
    # Balance panes
    tmux select-layout -t catbird-agents tiled
    
    # Attach to session
    tmux attach-session -t catbird-agents
}

# Function to launch with GNU Screen
launch_screen_session() {
    echo "🖥️  Launching agents in GNU Screen..."
    
    # Start screen session
    screen -dmS catbird-agents
    
    # Create windows for each agent
    for task in "${!TASKS[@]}"; do
        screen -S catbird-agents -X screen -t "$task" bash -c "claude --model ${MODELS[$task]} \"${TASKS[$task]}\"; read -p 'Press enter to close...'"
    done
    
    # Attach to session
    screen -r catbird-agents
}

# Menu for user choice
echo "How would you like to launch the agents?"
echo ""
echo "1) Separate terminal windows (macOS)"
echo "2) tmux session (all in one window with panes)"
echo "3) GNU Screen session (all in one window with tabs)"
echo "4) Sequential in current terminal"
echo ""
read -p "Choose option (1-4): " choice

case $choice in
    1)
        echo ""
        echo "🚀 Launching agents in separate terminals..."
        echo ""
        
        # Launch critical agents first
        echo "🔴 Launching Critical Agents (Opus):"
        launch_agent "feed-filtering"
        sleep 1
        launch_agent "language-filtering"
        
        echo ""
        read -p "Press enter to launch high-priority agents..."
        
        echo "🟡 Launching High Priority Agents (Sonnet):"
        launch_agent "font-accessibility"
        sleep 1
        launch_agent "app-passwords"
        sleep 1
        launch_agent "moderation-lists"
        
        echo ""
        echo "✅ All agents launched!"
        echo "Check your terminal windows to interact with each agent."
        ;;
        
    2)
        if command -v tmux &> /dev/null; then
            launch_tmux_session
        else
            echo "❌ tmux not installed. Install with: brew install tmux"
            exit 1
        fi
        ;;
        
    3)
        if command -v screen &> /dev/null; then
            launch_screen_session
        else
            echo "❌ GNU Screen not installed. Install with: brew install screen"
            exit 1
        fi
        ;;
        
    4)
        echo ""
        echo "🚀 Running agents sequentially..."
        for task in "feed-filtering" "language-filtering" "font-accessibility"; do
            echo ""
            echo "=========================================="
            echo "🤖 Starting: $task (${MODELS[$task]})"
            echo "=========================================="
            claude --model "${MODELS[$task]}" "${TASKS[$task]}"
            echo ""
            read -p "Press enter to continue to next agent..."
        done
        ;;
        
    *)
        echo "Invalid choice"
        exit 1
        ;;
esac