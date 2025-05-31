#!/bin/bash
echo "🛑 Stopping Claude agents..."
tmux kill-session -t claude-agents 2>/dev/null || true
echo "✅ Agents stopped"
