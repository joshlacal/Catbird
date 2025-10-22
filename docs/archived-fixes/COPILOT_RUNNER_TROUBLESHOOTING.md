# Copilot Runner Troubleshooting Guide

## Issue: Copilot Runner Not Working

### Two Different Copilot CLIs

There are **TWO** different GitHub Copilot command-line tools:

1. **Standalone GitHub Copilot CLI** (Node.js package)
   - Command: `copilot`
   - Install: `npm install -g @githubnext/copilot-cli` (or similar)
   - Supports: `copilot -p "prompt" --allow-all-tools`
   - **This is what the runner uses**

2. **GitHub CLI Extension** (`gh` extension)
   - Command: `gh copilot suggest` or `gh copilot explain`
   - Install: `gh extension install github/gh-copilot`
   - Supports: Interactive suggestions and explanations
   - **This is NOT what the runner uses**

### Quick Check

```bash
# Check which copilot you have
which copilot
# Should show: /usr/local/Cellar/node/24.8.0/bin/copilot (or similar)

# Test if it supports programmatic mode
copilot --help | grep -E "(prompt|-p)"
# Should show: -p, --prompt <text>

# Test a simple command
copilot -p "echo hello world" --allow-tool 'shell(echo)'
```

### Common Issues

#### 1. Wrong Copilot CLI Installed

**Problem**: You have `gh copilot` but not the standalone `copilot` command.

**Solution**: Install the standalone GitHub Copilot CLI:
```bash
# Check if you have the right one
copilot --version

# If missing or wrong version, install standalone CLI
npm install -g @githubnext/copilot-cli
```

#### 2. Permissions/Authentication

**Problem**: Copilot runs but can't authenticate.

**Solution**: Ensure you're logged in:
```bash
# The standalone copilot might need GitHub authentication
# Check authentication status
gh auth status

# Login if needed
gh auth login
```

#### 3. Tool Approval Flags

**Problem**: Tasks hang or require manual approval.

**Solution**: Use proper approval flags:
```bash
# Allow all tools (non-interactive)
--allow-all-tools

# Allow specific tools
--allow-tool 'shell(swift)' --allow-tool 'shell(git)'

# Deny specific dangerous tools
--allow-all-tools --deny-tool 'shell(rm)' --deny-tool 'write'
```

### Testing the Runner

#### Test 1: Simple Echo Task
```bash
./copilot-runner.py single "test-echo" \
  "Echo the text 'Hello from Copilot'" \
  --approval "--allow-tool 'shell(echo)'"
```

#### Test 2: Safe Git Status
```bash
./copilot-runner.py single "test-git" \
  "Show git status" \
  --approval "--allow-tool 'shell(git status)'"
```

#### Test 3: Swift Syntax Check (Safe)
```bash
./copilot-runner.py single "test-swift" \
  "Check syntax of Catbird/App/CatbirdApp.swift using swift -frontend -parse" \
  --approval "--allow-tool 'shell(swift)'"
```

#### Test 4: From Task File
```bash
# List available workflows
cat catbird-tasks.json | jq '.workflows | keys'

# Run a simple task
./copilot-runner.py from-file catbird-tasks.json \
  --tasks ui-001-muted-toast \
  --verbose
```

### Debug Mode

Enable verbose logging to see what's happening:

```bash
# Python runner with verbose mode
./copilot-runner.py -v from-file catbird-tasks.json --tasks ui-001-muted-toast

# Check the logs
ls -lt copilot-results/
cat copilot-results/task_*_latest.log
```

### Manual Testing

If the runner still doesn't work, test the underlying command manually:

```bash
# What the runner executes
copilot -p "Fix the muted-words toast to wrap content" --allow-all-tools

# With specific tool allowance
copilot -p "Check Swift syntax" --allow-tool 'shell(swift)' --allow-tool 'read'

# With working directory context
cd /Users/joshlacalamito/Developer/Catbird+Petrel/Catbird
copilot -p "List all Swift files in Catbird/" --allow-tool 'shell(fd)'
```

### Known Limitations

1. **Non-Interactive Only**: The runner requires `--allow-all-tools` or specific `--allow-tool` flags
2. **No Streaming**: Output is captured after completion, not streamed
3. **Timeout Required**: Long-running tasks need appropriate timeout values
4. **Context Limitations**: Copilot CLI doesn't have full repo context like GitHub Copilot in VS Code

### Alternative: Manual Parallel Execution

If the runner is problematic, you can manually run tasks in parallel:

```bash
# Using GNU parallel (if installed)
parallel -j 4 'copilot -p {} --allow-all-tools' ::: \
  "Fix muted-words toast" \
  "Hide OAuth buttons" \
  "Fix reply flood"

# Using shell background jobs
copilot -p "Fix muted-words toast" --allow-all-tools &
copilot -p "Hide OAuth buttons" --allow-all-tools &
copilot -p "Fix reply flood" --allow-all-tools &
wait
```

### Getting Help

1. **Check Copilot CLI version and help**:
   ```bash
   copilot --version
   copilot --help
   ```

2. **Check GitHub CLI status**:
   ```bash
   gh --version
   gh auth status
   ```

3. **Check runner logs**:
   ```bash
   ls -ltr copilot-results/
   tail -50 copilot-results/run_*.log
   ```

4. **Run with debug**:
   ```bash
   python3 -u copilot-runner.py -v from-file catbird-tasks.json --tasks test-task
   ```

### Contact/Report Issues

If you've verified:
- ✅ Standalone `copilot` command is installed
- ✅ `copilot -p "test" --allow-all-tools` works manually
- ✅ GitHub authentication is working
- ✅ Task definitions are valid JSON

But the runner still fails, check:
1. Python version: `python3 --version` (needs 3.7+)
2. File permissions: `ls -l copilot-runner.py`
3. JSON validation: `cat catbird-tasks.json | jq '.'`
