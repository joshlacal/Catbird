#!/bin/bash
# Headless task runner for GitHub Copilot CLI
# Runs multiple tasks in parallel or sequence and returns results

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
RESULTS_DIR="${COPILOT_RESULTS_DIR:-./copilot-results}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${RESULTS_DIR}/run_${TIMESTAMP}.log"

# Ensure results directory exists
mkdir -p "$RESULTS_DIR"

# Log function
log() {
    echo -e "${2:-$NC}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}" | tee -a "$LOG_FILE"
}

# Task execution function
run_task() {
    local task_name="$1"
    local prompt="$2"
    local approval_flags="${3:---allow-all-tools}"
    local task_log="${RESULTS_DIR}/task_${task_name}_${TIMESTAMP}.log"
    
    log "Starting task: $task_name" "$BLUE"
    log "Prompt: $prompt" "$YELLOW"
    
    # Run copilot with programmatic mode
    if copilot -p "$prompt" $approval_flags > "$task_log" 2>&1; then
        log "✓ Task '$task_name' completed successfully" "$GREEN"
        echo "Results saved to: $task_log"
        return 0
    else
        log "✗ Task '$task_name' failed" "$RED"
        echo "Error log: $task_log"
        return 1
    fi
}

# Parallel task execution
run_parallel() {
    local -a pids=()
    local -a tasks=()
    
    log "Running ${#@} tasks in parallel..." "$BLUE"
    
    # Start all tasks
    for task_spec in "$@"; do
        IFS='|' read -r name prompt flags <<< "$task_spec"
        tasks+=("$name")
        run_task "$name" "$prompt" "$flags" &
        pids+=($!)
    done
    
    # Wait for all tasks
    local failed=0
    for i in "${!pids[@]}"; do
        if ! wait "${pids[$i]}"; then
            failed=$((failed + 1))
            log "Task '${tasks[$i]}' failed" "$RED"
        fi
    done
    
    if [ $failed -eq 0 ]; then
        log "All parallel tasks completed successfully" "$GREEN"
        return 0
    else
        log "$failed tasks failed" "$RED"
        return 1
    fi
}

# Sequential task execution
run_sequential() {
    log "Running ${#@} tasks sequentially..." "$BLUE"
    
    local failed=0
    for task_spec in "$@"; do
        IFS='|' read -r name prompt flags <<< "$task_spec"
        if ! run_task "$name" "$prompt" "$flags"; then
            failed=$((failed + 1))
        fi
    done
    
    if [ $failed -eq 0 ]; then
        log "All sequential tasks completed successfully" "$GREEN"
        return 0
    else
        log "$failed tasks failed" "$RED"
        return 1
    fi
}

# Display help
show_help() {
    cat << EOF
Headless Task Runner for GitHub Copilot CLI

Usage: $0 [OPTIONS] COMMAND

Commands:
  single TASK_NAME PROMPT [FLAGS]
      Run a single task
      
  parallel TASK_SPEC [TASK_SPEC ...]
      Run multiple tasks in parallel
      Task spec format: "name|prompt|flags"
      
  sequential TASK_SPEC [TASK_SPEC ...]
      Run multiple tasks in sequence
      
  from-file FILE
      Run tasks from a JSON/YAML file

Options:
  -h, --help              Show this help
  -d, --results-dir DIR   Set results directory (default: ./copilot-results)
  -s, --safe              Use safe mode (no auto-approval)

Approval Flags (default: --allow-all-tools):
  --allow-all-tools       Allow all tools without approval
  --allow-tool TOOL       Allow specific tool
  --deny-tool TOOL        Deny specific tool
  --safe                  Require manual approval for all tools

Examples:
  # Single task with auto-approval
  $0 single "syntax-check" "Check all Swift files for syntax errors" "--allow-tool 'shell(swift)'"
  
  # Parallel tasks
  $0 parallel \\
    "build-ios|Build for iOS simulator|--allow-all-tools" \\
    "build-macos|Build for macOS|--allow-all-tools" \\
    "lint|Run SwiftLint|--allow-tool 'shell(swiftlint)'"
  
  # Sequential tasks (each depends on previous)
  $0 sequential \\
    "syntax|Check Swift syntax|--allow-tool 'shell'" \\
    "build|Build the project|--allow-all-tools" \\
    "test|Run tests|--allow-all-tools"

Environment Variables:
  COPILOT_RESULTS_DIR    Directory for task results (default: ./copilot-results)
  COPILOT_MODEL          AI model to use (claude-sonnet-4, gpt-5, etc.)

EOF
}

# Main execution
main() {
    if [ $# -eq 0 ]; then
        show_help
        exit 1
    fi
    
    # Parse global options
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -d|--results-dir)
                RESULTS_DIR="$2"
                mkdir -p "$RESULTS_DIR"
                shift 2
                ;;
            single)
                shift
                if [ $# -lt 2 ]; then
                    echo "Error: single requires TASK_NAME and PROMPT"
                    exit 1
                fi
                run_task "$1" "$2" "${3:---allow-all-tools}"
                exit $?
                ;;
            parallel)
                shift
                run_parallel "$@"
                exit $?
                ;;
            sequential)
                shift
                run_sequential "$@"
                exit $?
                ;;
            from-file)
                shift
                log "Task file execution not yet implemented" "$YELLOW"
                exit 1
                ;;
            *)
                echo "Unknown command: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Check if copilot is installed
if ! command -v copilot &> /dev/null; then
    log "Error: GitHub Copilot CLI is not installed" "$RED"
    log "Install it with: gh extension install github/gh-copilot" "$YELLOW"
    exit 1
fi

log "=== Copilot Task Runner Started ===" "$GREEN"
main "$@"
log "=== Task Runner Finished ===" "$GREEN"
log "Results directory: $RESULTS_DIR" "$BLUE"
