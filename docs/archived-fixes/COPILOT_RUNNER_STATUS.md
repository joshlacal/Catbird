# Copilot Runner Issue & Solutions

## Summary

I've created a comprehensive TODO list and investigated the copilot runner issue. Here's what I found:

## ✅ What's Working

1. **GitHub Copilot CLI is installed**: Version 0.0.339 at `/usr/local/Cellar/node/24.8.0/bin/copilot`
2. **Authentication is configured**: User `joshlacal` is logged in
3. **Programmatic mode is supported**: The `-p` flag exists
4. **Python runner script is functional**: No syntax errors

## ❌ The Issue

The `copilot` command **hangs when run programmatically** with the `-p` flag, even with `--allow-all-tools`. This appears to be because:

1. The copilot CLI may still be trying to start some interactive components
2. It might be waiting for MCP servers or other background services
3. Session state management could be interfering

## 🔧 Solutions

### Option 1: Use Alternative Approach (Recommended for Now)

Instead of using the automated runner, manually run tasks one at a time:

```bash
# Method 1: Use gh copilot (interactive but reliable)
gh copilot suggest "Fix the muted-words toast to wrap content"

# Method 2: Use copilot interactively
copilot  # Then type your prompt
```

### Option 2: Fix the Runner (Advanced)

The runner needs modification to handle the CLI's behavior. Potential fixes:

**A. Add stdin handling:**
```python
# In copilot-runner.py, modify subprocess.run:
result = subprocess.run(
    cmd,
    capture_output=True,
    text=True,
    timeout=task.timeout,
    stdin=subprocess.DEVNULL  # ← Add this
)
```

**B. Use environment variables:**
```python
# Set environment before running
env = os.environ.copy()
env['COPILOT_ALLOW_ALL'] = '1'
env['COPILOT_NO_INTERACTIVE'] = '1'  # If available

result = subprocess.run(
    cmd,
    capture_output=True,
    text=True,
    timeout=task.timeout,
    stdin=subprocess.DEVNULL,
    env=env  # ← Add this
)
```

**C. Alternative: Use expect/pexpect:**
```python
import pexpect

child = pexpect.spawn(f'copilot -p "{prompt}" --allow-all-tools')
child.expect(pexpect.EOF, timeout=timeout)
output = child.before.decode()
```

### Option 3: Build Your Own Simple Runner

Create a simpler runner that uses GitHub Copilot in VS Code or directly interfaces with the API:

```bash
#!/bin/bash
# simple-task-runner.sh

TASKS=(
  "Fix muted-words toast"
  "Hide OAuth buttons"
  "Fix reply flood"
)

for task in "${TASKS[@]}"; do
  echo "=== $task ==="
  echo "Opening in GitHub Copilot..."
  # Open VS Code with Copilot
  code --wait --new-window .
  echo "Complete this task: $task"
  read -p "Press enter when done..."
done
```

## 📋 Created Files

I've created the following files to help you:

### 1. `TODO.md` - Organized Task List
- 25 tasks organized by priority (P0/P1/P2)
- Grouped by area (Feeds, UI, Accounts, etc.)
- Clear acceptance criteria
- Suggested order for manual work

### 2. `catbird-tasks.json` - Machine-Readable Tasks
- Complete task definitions with metadata
- Pre-defined workflows (p0-quick-wins, feeds-complete, etc.)
- Structured for the copilot runner
- Includes code paths and dependencies

### 3. `COPILOT_RUNNER_TROUBLESHOOTING.md` - Debug Guide
- Step-by-step troubleshooting
- Common issues and solutions
- Testing procedures
- Alternative approaches

### 4. `test-copilot-setup.sh` - Diagnostic Script
- Tests copilot installation
- Validates JSON task file
- Checks authentication
- Verifies all dependencies

## 🎯 Recommended Workflow (Without Runner)

Since the runner is having issues, here's the best manual approach:

### Phase 1: P0 Quick Wins (Do Today)
```bash
# Task 1: Muted-words toast
cd Catbird/Components/Toasts/
# Fix MutedWordsToast to use .frame(maxHeight: UIScreen.main.bounds.height * 0.4)

# Task 2: OAuth buttons
cd Catbird/Features/Settings/
# Hide unsupported OAuth actions

# Task 3: Reply flood
cd Catbird/Features/Feed/
# Filter replies in FollowingFeed

# ... continue with TODO.md order
```

### Phase 2: Track Progress
Use the checkboxes in `TODO.md`:
```bash
# Mark task complete
sed -i '' 's/- \[ \] \*\*UI-001\*\*/- [x] **UI-001**/' TODO.md
```

### Phase 3: Run Automated Checks
```bash
# Before each commit
./swift-check.sh
./quick-error-check.sh

# Build and test
xcodebuild -project Catbird.xcodeproj -scheme Catbird build
```

## 🔄 Next Steps

1. **Use TODO.md for manual task tracking**
2. **Pick tasks from the suggested order** (UI-001, SET-001, FEED-001, etc.)
3. **If you want to fix the runner**, try the stdin/env modifications above
4. **Alternative**: Use GitHub Copilot in VS Code with the task descriptions

## 📊 Task Breakdown

### P0 (Critical) - 8 tasks
- UI-001: Muted toast (fast)
- SET-001: OAuth buttons (fast)
- FEED-001: Reply flood (medium)
- COMP-001: Share crash (medium)
- UI-004: Sort options (fast)
- NAV-001: Messages nav (medium)
- SRCH-001: Search plan (planning)
- NOTIF-001: Push notifier (server)

### P1 (Important) - 11 tasks
- Feed system (3 tasks)
- UI polish (2 tasks)
- Composer/Accounts (4 tasks)
- Moderation/Performance (2 tasks)

### P2 (Nice to have) - 6 tasks
- Messages/Feed UX (2 tasks)
- UI enhancements (1 task)
- Moderation/Tooling/Cleanup (3 tasks)

## 🛠️ Quick Runner Fix to Try

If you want to quickly test a fix, edit `copilot-runner.py` line 95-100:

```python
# Change from:
result = subprocess.run(
    cmd,
    capture_output=True,
    text=True,
    timeout=task.timeout
)

# To:
result = subprocess.run(
    cmd,
    capture_output=True,
    text=True,
    timeout=task.timeout,
    stdin=subprocess.DEVNULL,  # Don't wait for input
    env={**os.environ, 'COPILOT_ALLOW_ALL': '1'}  # Force non-interactive
)
```

Then test:
```bash
./copilot-runner.py single "test" "echo hello" --approval "--allow-all-tools"
```

---

**Bottom line**: The TODO list is ready to use manually. The runner has an issue with the copilot CLI hanging. You can either fix the runner with the suggested changes or work through the tasks manually using TODO.md as your guide.
