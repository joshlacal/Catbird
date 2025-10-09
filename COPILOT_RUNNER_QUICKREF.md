# Copilot Task Runner - Quick Reference

## Installation

```bash
# Prerequisites
gh extension install github/gh-copilot

# Make scripts executable
chmod +x copilot-runner.sh copilot-runner.py
```

## Common Commands

### Single Task
```bash
./copilot-runner.sh single "TASK_NAME" "PROMPT" "APPROVAL_FLAGS"
```

### Parallel Tasks (Bash)
```bash
./copilot-runner.sh parallel \
  "name1|prompt1|flags1" \
  "name2|prompt2|flags2"
```

### Sequential Tasks (Bash)
```bash
./copilot-runner.sh sequential \
  "name1|prompt1|flags1" \
  "name2|prompt2|flags2"
```

### From Config File (Python)
```bash
# Run workflow
./copilot-runner.py from-file copilot-tasks.json --workflow WORKFLOW_NAME

# Run specific tasks in parallel
./copilot-runner.py from-file copilot-tasks.json --tasks task1 task2

# Run specific tasks sequentially
./copilot-runner.py from-file copilot-tasks.json --tasks task1 task2 --sequential
```

## Approval Flags (Security)

| Flag | Description | Use Case |
|------|-------------|----------|
| `--allow-all-tools` | Allow any tool | ⚠️ Containers/VMs only |
| `--allow-tool 'shell(CMD)'` | Allow specific command | Safe automation |
| `--allow-tool 'write'` | Allow file modifications | Code generation |
| `--deny-tool 'shell(CMD)'` | Block specific command | Safety first |
| No flags | Manual approval | Maximum safety |

## Common Catbird Workflows

### Pre-commit Check
```bash
./copilot-runner.py from-file copilot-tasks.example.json \
  --workflow pre-commit
```

### Multi-platform Build
```bash
./copilot-runner.py from-file copilot-tasks.example.json \
  --workflow full-build
```

### CI Pipeline
```bash
./copilot-runner.py from-file copilot-tasks.example.json \
  --workflow ci-pipeline \
  --stop-on-failure
```

### Syntax + Lint (Quick)
```bash
./copilot-runner.sh parallel \
  "syntax|Check Swift syntax|--allow-tool 'shell(swift)'" \
  "lint|Run SwiftLint|--allow-tool 'shell(swiftlint)'"
```

## Python Options

```bash
# Custom results directory
--results-dir ./my-results

# Verbose output
--verbose

# Custom AI model
--model gpt-5
# or
export COPILOT_MODEL=claude-sonnet-4.5

# Max parallel workers
--max-workers 4

# Stop on first failure (sequential only)
--stop-on-failure
```

## Results & Logs

All outputs saved to `copilot-results/`:
- `run_TIMESTAMP.log` - Main log
- `task_NAME_TIMESTAMP.log` - Per-task logs

Exit codes:
- `0` = Success
- `1` = Failure

## Task Definition Format (JSON)

```json
{
  "tasks": {
    "task-id": {
      "name": "Display Name",
      "prompt": "What to do",
      "approval": "--allow-tool 'shell(cmd)'",
      "timeout": 120
    }
  },
  "workflows": {
    "workflow-name": {
      "description": "Description",
      "mode": "parallel",
      "tasks": ["task-id-1", "task-id-2"]
    }
  }
}
```

## Safe Approval Patterns

### Read-only Git
```bash
--allow-tool 'shell(git status)' \
--allow-tool 'shell(git diff)' \
--deny-tool 'shell(git push)'
```

### Build Only
```bash
--allow-tool 'shell(xcodebuild)' \
--deny-tool 'shell(rm)' \
--deny-tool 'write'
```

### Syntax Check Only
```bash
--allow-tool 'shell(swift)' \
--deny-tool 'shell'
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `copilot: command not found` | `gh extension install github/gh-copilot` |
| Permission denied | `chmod +x copilot-runner.sh copilot-runner.py` |
| Task hangs | Add approval flags or increase timeout |
| Task timeout | Increase `timeout` in task definition |

## Resources

- Full docs: `COPILOT_RUNNER_README.md`
- Example tasks: `copilot-tasks.example.json`
- GitHub Copilot CLI: https://docs.github.com/en/copilot/using-github-copilot/using-github-copilot-in-the-command-line
