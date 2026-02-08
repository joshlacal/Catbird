# Parallel Agents System

Run multiple independent GitHub Copilot CLI agents simultaneously for massive productivity gains.

## Quick Start

```bash
# Run 3 agents in parallel
./parallel-agents.py quick \
  "Check Swift syntax in Core/" \
  "Build iOS target" \
  "Run tests" \
  --approval='--allow-all-tools'

# Load from config file
./parallel-agents.py from-config parallel-agents-config.example.json

# Interactive mode
./parallel-agents.py interactive
```

## What This Enables

Instead of sequentially running tasks that take 2-5 minutes each, spawn multiple Copilot agents that work **concurrently**. This is perfect for:

- **Multi-platform builds**: iOS + macOS + tests simultaneously
- **Code quality checks**: Syntax + lint + tests + security scans in parallel
- **Research tasks**: API docs + codebase search + examples at once
- **Refactoring**: Multiple file edits across different features concurrently

## Real Example

```bash
# Traditional sequential approach (15+ minutes)
copilot -p "Check all Swift syntax"        # 5 min
copilot -p "Build iOS"                     # 5 min  
copilot -p "Build macOS"                   # 5 min
copilot -p "Run tests"                     # 3 min

# Parallel agents (5-6 minutes total)
./parallel-agents.py quick \
  "Check all Swift syntax" \
  "Build iOS target" \
  "Build macOS target" \
  "Run all tests" \
  --approval='--allow-all-tools'
```

## Configuration File Format

Create JSON configs for reusable agent swarms:

```json
{
  "agents": [
    {
      "name": "syntax-checker",
      "task": "Check all Swift files for syntax errors",
      "approval": "--allow-all-tools"
    },
    {
      "name": "ios-builder",
      "task": "Build iOS target for iPhone 16 Pro simulator",
      "approval": "--allow-all-tools"
    },
    {
      "name": "test-runner",
      "task": "Run Swift tests",
      "approval": "--allow-all-tools"
    }
  ]
}
```

## Command Reference

### Quick Mode
Spawn agents from command line arguments:
```bash
./parallel-agents.py quick TASK1 TASK2 TASK3 [options]
```

### Config File Mode
Load agent definitions from JSON:
```bash
./parallel-agents.py from-config CONFIG_FILE [options]
```

### Interactive Mode
Spawn agents one by one interactively:
```bash
./parallel-agents.py interactive
```

## Options

- `--max-agents N`: Maximum concurrent agents (default: 4)
- `--workspace PATH`: Working directory (default: current)
- `--approval FLAGS`: Approval flags for all agents (quick mode)

## Approval Flags

Control what agents can do:

```bash
# Full automation (use with caution)
--approval='--allow-all-tools'

# Specific tool allowance
--approval='--allow-tool shell(swift)'

# Multiple tools
--approval='--allow-tool shell(swift) --allow-tool shell(xcodebuild)'

# Deny dangerous operations
--approval='--deny-tool shell(rm) --allow-all-tools'
```

## Output Structure

Results are saved to `parallel-agents-results/TIMESTAMP/`:

```
parallel-agents-results/20251013_104908/
├── summary.json          # Execution summary
├── agent_0_name.log      # Agent 0 output
├── agent_1_name.log      # Agent 1 output
└── agent_2_name.log      # Agent 2 output
```

## Use Cases

### CI/CD Pipeline Acceleration
```bash
./parallel-agents.py quick \
  "Build iOS Debug" \
  "Build macOS Debug" \
  "Run unit tests" \
  "Run SwiftLint" \
  "Check for TODOs" \
  --approval='--allow-all-tools'
```

### Cross-Platform Feature Development
```bash
./parallel-agents.py quick \
  "Implement UserProfile view for iOS" \
  "Implement UserProfile view for macOS" \
  "Add UserProfile unit tests" \
  "Update UserProfile documentation" \
  --approval='--allow-all-tools'
```

### Code Quality Audit
```bash
./parallel-agents.py quick \
  "Check Swift syntax in Catbird/Core/" \
  "Check Swift syntax in Catbird/Features/" \
  "Run SwiftLint on entire codebase" \
  "Find print() statements" \
  "Check for TODO/FIXME comments" \
  --approval='--allow-tool shell(swift) --allow-tool shell(swiftlint) --allow-tool shell(rg)'
```

### Documentation Generation
```bash
./parallel-agents.py quick \
  "Generate README for Auth module" \
  "Generate README for Feed module" \
  "Generate README for Profile module" \
  "Update main project README" \
  --approval='--allow-tool write'
```

## Performance Tips

1. **Optimal agent count**: Use 2-4x CPU core count for I/O-bound tasks
2. **Task independence**: Agents work best on independent tasks (no shared state)
3. **Approval flags**: Use minimal permissions for safety and speed
4. **Timeout management**: Set appropriate timeouts in config files
5. **Resource monitoring**: Watch CPU/memory when running many agents

## Safety Considerations

- **File conflicts**: Agents can't coordinate - avoid editing same files
- **Build artifacts**: Parallel builds may conflict - use separate schemes/configs
- **Git operations**: One agent per git operation to avoid race conditions
- **Resource limits**: Don't spawn more agents than your system can handle

## Integration Examples

### Makefile
```makefile
.PHONY: parallel-check
parallel-check:
	./parallel-agents.py from-config qa-agents.json

.PHONY: parallel-build
parallel-build:
	./parallel-agents.py quick \
		"Build iOS" "Build macOS" "Run tests" \
		--approval='--allow-all-tools'
```

### GitHub Actions
```yaml
- name: Parallel Agent QA
  run: |
    ./parallel-agents.py from-config .github/qa-agents.json
```

### Pre-commit Hook
```bash
#!/bin/bash
./parallel-agents.py quick \
  "Check Swift syntax" \
  "Run SwiftLint" \
  --approval='--allow-tool shell(swift) --allow-tool shell(swiftlint)' \
  || exit 1
```

## Troubleshooting

### Agents all fail immediately
- Check approval flags format (use quotes: `--approval='--allow-all-tools'`)
- Verify Copilot CLI is installed: `which copilot`

### Out of memory
- Reduce `--max-agents` count
- Run fewer agents or use sequential tasks

### Conflicting file edits
- Design tasks to work on different files/features
- Use sequential execution for dependent tasks

### Slow performance
- Check if agents are CPU or I/O bound
- Adjust `--max-agents` accordingly
- Monitor system resources during execution

## Advanced: Agent Coordination Patterns

While agents can't directly communicate, you can coordinate through file system:

```json
{
  "agents": [
    {
      "name": "setup",
      "task": "Create temp directory and prepare environment"
    },
    {
      "name": "worker1", 
      "task": "Process files from temp directory batch 1"
    },
    {
      "name": "worker2",
      "task": "Process files from temp directory batch 2"
    }
  ]
}
```

Run setup first, then spawn workers that read from shared location.

## Comparison to copilot-cli MCP

| Feature | parallel-agents.py | copilot-cli MCP |
|---------|-------------------|-----------------|
| Concurrent execution | ✅ Yes (truly parallel) | ✅ Yes |
| Agent isolation | ✅ Full isolation | ✅ Full isolation |
| Task independence | ✅ Required | ⚠️ Can depend |
| Configuration | JSON | MCP calls |
| Workflow support | ❌ No | ✅ Via agent orchestration |
| Best for | Independent tasks | Managed agent spawning |

Use **parallel-agents.py** for batch execution of many independent tasks.  
Use **copilot-cli MCP** for programmatic agent spawning with lifecycle management.

## Future Enhancements

Potential improvements:
- [ ] Agent communication via message passing
- [ ] Distributed execution across machines
- [ ] Result aggregation and analysis
- [ ] Automatic task splitting
- [ ] Dynamic agent spawning based on load
- [ ] Web dashboard for monitoring
- [ ] Agent pooling and reuse

## Examples

See `parallel-agents-config.example.json` for ready-to-use configurations.
