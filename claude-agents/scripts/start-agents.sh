#!/bin/bash

SESSION="claude-agents"
BASE_DIR="$(pwd)"

# Kill existing session
tmux kill-session -t $SESSION 2>/dev/null || true

# Create new session
tmux new-session -d -s $SESSION -n "orchestrator"

# Start orchestrator in first window
tmux send-keys -t $SESSION:orchestrator "cd $BASE_DIR && node orchestrator.js" C-m

# Create monitoring window
tmux new-window -t $SESSION -n "monitor"
tmux split-window -h -t $SESSION:monitor
tmux split-window -v -t $SESSION:monitor.1

# Monitor logs
tmux send-keys -t $SESSION:monitor.0 "cd $BASE_DIR && tail -f logs/*.log 2>/dev/null || echo 'No logs yet'" C-m

# Monitor shared directory
tmux send-keys -t $SESSION:monitor.1 "cd $BASE_DIR && watch -n 2 'find shared -name \"*.json\" | head -10'" C-m

# Monitor git worktrees
tmux send-keys -t $SESSION:monitor.2 "cd $BASE_DIR && watch -n 5 'find worktrees -maxdepth 2 -name .git 2>/dev/null | wc -l | xargs echo \"Active worktrees:\"'" C-m

echo "✅ Claude agents started in tmux session: $SESSION"
echo "📺 Attach with: tmux attach -t $SESSION"
echo "🔧 Control: tmux list-sessions"
