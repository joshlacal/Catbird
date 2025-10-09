# Copilot CLI Headless Task Runner

Automated task execution system for GitHub Copilot CLI that can run tasks in parallel or sequence without manual interaction.

## Overview

This toolset allows you to:
- **Run multiple Copilot CLI tasks in parallel** - execute independent tasks simultaneously
- **Run tasks sequentially** - chain dependent operations
- **Headless operation** - no manual approval needed with configurable safety options
- **Task definitions in JSON/YAML** - reusable task configurations
- **Result aggregation** - collect and analyze task outputs

## Files

- `copilot-runner.sh` - Bash version (simple, portable)
- `copilot-runner.py` - Python version (advanced features, JSON/YAML support)
- `copilot-tasks.example.json` - Example task definitions

## Installation

### Prerequisites

1. Install GitHub Copilot CLI:
```bash
gh extension install github/gh-copilot
```

2. For Python version (optional YAML support):
```bash
pip install pyyaml  # Optional, for YAML task files
```

### Make Scripts Executable

```bash
chmod +x copilot-runner.sh copilot-runner.py
```

## Quick Start

### Single Task (Bash)

```bash
./copilot-runner.sh single "syntax-check" \
  "Check all Swift files for syntax errors" \
  "--allow-tool 'shell(swift)'"
```

### Parallel Tasks (Bash)

```bash
./copilot-runner.sh parallel \
  "build-ios|Build for iOS simulator|--allow-all-tools" \
  "build-macos|Build for macOS|--allow-all-tools" \
  "lint|Run SwiftLint|--allow-tool 'shell(swiftlint)'"
```

### Sequential Tasks (Python)

```bash
./copilot-runner.py from-file copilot-tasks.example.json \
  --workflow ci-pipeline \
  --sequential
```

## Task Definition Format

### JSON Format

```json
{
  "version": "1.0",
  "tasks": {
    "task-id": {
      "name": "Task Display Name",
      "prompt": "What you want Copilot to do",
      "approval": "--allow-tool 'shell(command)'",
      "timeout": 120,
      "description": "Optional description"
    }
  },
  "workflows": {
    "workflow-name": {
      "description": "Workflow description",
      "mode": "parallel",
      "tasks": ["task-id-1", "task-id-2"]
    }
  }
}
```

### YAML Format (Python only)

```yaml
version: "1.0"
tasks:
  syntax-check:
    name: Swift Syntax Check
    prompt: Check all Swift files for syntax errors
    approval: --allow-tool 'shell(swift)'
    timeout: 60

workflows:
  pre-commit:
    description: Pre-commit validation
    mode: sequential
    tasks:
      - syntax-check
      - lint
```

## Usage Examples

### Development Workflow

```bash
# Pre-commit checks (sequential)
./copilot-runner.py from-file copilot-tasks.json \
  --tasks syntax-check lint git-status \
  --sequential

# Multi-platform build (parallel)
./copilot-runner.py from-file copilot-tasks.json \
  --workflow full-build

# CI/CD pipeline (sequential with stop-on-failure)
./copilot-runner.py from-file copilot-tasks.json \
  --workflow ci-pipeline \
  --sequential \
  --stop-on-failure
```

### iOS Development Tasks

```bash
# Syntax check before build
./copilot-runner.sh single "pre-build" \
  "Run swift -frontend -parse on all Swift files in Catbird/" \
  "--allow-tool 'shell(swift)'"

# Build and test
./copilot-runner.sh sequential \
  "build|Build Catbird for iPhone 16 Pro simulator|--allow-all-tools" \
  "test|Run all Catbird tests on simulator|--allow-all-tools"

# Parallel quality checks
./copilot-runner.sh parallel \
  "swiftlint|Run SwiftLint|--allow-tool 'shell(swiftlint)'" \
  "warnings|Check for TODO and FIXME comments|--allow-tool 'shell(rg)'" \
  "prints|Find print statements|--allow-tool 'shell(rg)'"
```

## Security & Approval Options

### Approval Flags

- `--allow-all-tools` - Allow any tool (⚠️ USE WITH CAUTION)
- `--allow-tool 'shell(command)'` - Allow specific shell command
- `--allow-tool 'write'` - Allow file modifications
- `--deny-tool 'shell(rm)'` - Deny specific dangerous commands
- No flags - Manual approval required (safest)

### Security Best Practices

1. **Start restrictive**: Use specific `--allow-tool` flags
2. **Deny dangerous commands**: Always deny `rm`, `chmod`, etc.
3. **Run in containers**: Use Docker/VM for `--allow-all-tools`
4. **Review task definitions**: Audit JSON/YAML before running
5. **Check logs**: Review results in `copilot-results/` directory

### Safe Combinations

```bash
# Safe: Only allow Swift syntax checking
--allow-tool 'shell(swift)' --deny-tool 'shell'

# Safe: Allow read-only git commands
--allow-tool 'shell(git status)' --allow-tool 'shell(git diff)' --deny-tool 'shell(git push)'

# Safe: Allow builds but deny destructive operations
--allow-tool 'shell(xcodebuild)' --deny-tool 'shell(rm)' --deny-tool 'write'
```

## Advanced Features (Python Version)

### Custom Model Selection

```bash
# Use GPT-5
./copilot-runner.py from-file tasks.json \
  --workflow ci-pipeline \
  --model gpt-5

# Or set environment variable
export COPILOT_MODEL=claude-sonnet-4.5
./copilot-runner.py from-file tasks.json --workflow build
```

### Parallel Execution Control

```bash
# Limit to 2 concurrent tasks
./copilot-runner.py from-file tasks.json \
  --tasks task1 task2 task3 task4 \
  --max-workers 2
```

### Verbose Logging

```bash
# Detailed output with prompts and approvals
./copilot-runner.py from-file tasks.json \
  --workflow full-build \
  --verbose
```

### Custom Results Directory

```bash
# Save results to custom location
./copilot-runner.py from-file tasks.json \
  --workflow ci-pipeline \
  --results-dir ./ci-results
```

## Integration with CI/CD

### GitHub Actions

```yaml
- name: Run Copilot Tasks
  run: |
    ./copilot-runner.py from-file .github/copilot-tasks.json \
      --workflow ci-pipeline \
      --sequential \
      --stop-on-failure \
      --results-dir ${{ github.workspace }}/copilot-results

- name: Upload Results
  uses: actions/upload-artifact@v3
  with:
    name: copilot-task-results
    path: copilot-results/
```

### Makefile Integration

```makefile
.PHONY: copilot-check
copilot-check:
	./copilot-runner.py from-file copilot-tasks.json \
		--tasks syntax-check lint \
		--sequential

.PHONY: copilot-build-all
copilot-build-all:
	./copilot-runner.py from-file copilot-tasks.json \
		--workflow full-build \
		--max-workers 2
```

### Pre-commit Hook

```bash
#!/bin/bash
# .git/hooks/pre-commit

./copilot-runner.sh sequential \
  "syntax|Check Swift syntax|--allow-tool 'shell(swift)'" \
  "lint|Run SwiftLint|--allow-tool 'shell(swiftlint)'" \
  || exit 1
```

## Output & Results

### Log Files

All task execution generates log files in the results directory:

- `run_TIMESTAMP.log` - Main execution log
- `task_TASKNAME_TIMESTAMP.log` - Individual task logs

### Example Log Structure

```
copilot-results/
├── run_20250108_143022.log          # Main run log
├── task_syntax-check_20250108_143022.log
├── task_build-ios_20250108_143022.log
└── task_build-macos_20250108_143022.log
```

### Exit Codes

- `0` - All tasks succeeded
- `1` - One or more tasks failed

## Troubleshooting

### Copilot CLI Not Found

```bash
# Install Copilot CLI
gh extension install github/gh-copilot

# Verify installation
which copilot
copilot --version
```

### Permission Denied

```bash
chmod +x copilot-runner.sh copilot-runner.py
```

### Task Timeout

Increase timeout in task definition:
```json
{
  "timeout": 300  // 5 minutes
}
```

### Approval Issues

If tasks hang waiting for approval, ensure approval flags are set:
```bash
--allow-all-tools  # or specific --allow-tool flags
```

## Examples for Catbird Project

### Pre-commit Validation

```bash
./copilot-runner.py from-file copilot-tasks.example.json \
  --workflow pre-commit
```

### Full Platform Builds

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

## Future Enhancements

Potential additions:
- [ ] Result aggregation and reporting
- [ ] Slack/Discord notifications
- [ ] Task dependency graphs
- [ ] Conditional task execution
- [ ] Result caching
- [ ] Performance metrics
- [ ] Interactive task selection (fzf integration)

## Contributing

To add new task definitions:

1. Edit `copilot-tasks.example.json`
2. Add task to `tasks` section
3. Optionally add to `workflows`
4. Test with `--verbose` flag

## Resources

- [GitHub Copilot CLI Documentation](https://docs.github.com/en/copilot/concepts/agents/about-copilot-cli)
- [Copilot CLI Security Considerations](https://docs.github.com/en/copilot/concepts/agents/about-copilot-cli#security-considerations)
- [Installing Copilot CLI](https://docs.github.com/en/copilot/using-github-copilot/using-github-copilot-in-the-command-line)

## License

Same as Catbird project.
