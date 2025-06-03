#!/bin/bash

# Real-time monitoring for Claude agents
# Shows what files are being edited and progress

echo "🔍 Claude Agent Monitor"
echo "======================="
echo ""
echo "Press Ctrl+C to exit"
echo ""

# Monitor git changes in real-time
watch_changes() {
    echo "📊 Monitoring file changes..."
    echo ""
    
    # Store initial state
    git status --porcelain > /tmp/initial_state.txt
    
    while true; do
        # Clear screen for clean output
        clear
        echo "🔍 Claude Agent Monitor - $(date)"
        echo "======================="
        echo ""
        
        # Show current git status
        echo "📝 Files being modified:"
        git status --porcelain | grep "^ M" | awk '{print "  ✏️  " $2}'
        echo ""
        
        echo "🆕 New files created:"
        git status --porcelain | grep "^??" | awk '{print "  📄 " $2}'
        echo ""
        
        # Show recent changes
        echo "🕐 Recent changes (last 5 minutes):"
        find . -name "*.swift" -mmin -5 -type f 2>/dev/null | grep -v ".git" | head -10 | awk '{print "  🔄 " $0}'
        echo ""
        
        # Show process activity
        echo "🤖 Active Claude processes:"
        ps aux | grep "[c]laude" | grep -v "monitor" | awk '{print "  PID: " $2 " - Started: " $9}'
        echo ""
        
        # Show last few lines of changes
        echo "📋 Latest modifications (git diff summary):"
        git diff --stat | tail -5
        echo ""
        
        sleep 2
    done
}

# Alternative: tail multiple log files if using the automation script
watch_logs() {
    LOG_DIR="$1"
    if [ -d "$LOG_DIR" ]; then
        echo "📁 Watching logs in: $LOG_DIR"
        echo ""
        
        # Use multitail if available, otherwise fall back to tail
        if command -v multitail &> /dev/null; then
            multitail "$LOG_DIR"/*.log
        else
            # Simple tail follow on all logs
            tail -f "$LOG_DIR"/*.log
        fi
    else
        echo "❌ Log directory not found: $LOG_DIR"
        echo "Running file change monitor instead..."
        watch_changes
    fi
}

# Check if log directory was provided
if [ $# -eq 1 ]; then
    watch_logs "$1"
else
    watch_changes
fi