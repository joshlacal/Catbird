# Development Workflow Quick Reference

## Agent Behavior Expectations

### What Agents Should Do
- ✅ Work continuously without artificial limits
- ✅ Use parallel tool calls for independent operations
- ✅ Validate code with syntax checks (`swift -frontend -parse`)
- ✅ Trust your Xcode error reports
- ✅ Verify implementations against Apple docs via MCP
- ✅ Complete tasks thoroughly before stopping
- ✅ Execute directly without excessive explanations
- ✅ Place temporary docs in `docs/session-notes/`

### What Agents Should NOT Do
- ❌ Make timeline estimates
- ❌ Include dates in documentation
- ❌ Build unless explicitly requested
- ❌ Stop prematurely due to context anxiety
- ❌ Over-explain simple operations
- ❌ Ask for repeated confirmations
- ❌ Clutter root directory with fix documentation
- ❌ Underutilize MCP servers

## Common Commands

### Syntax Validation (Fast)
```bash
# Single file
swift -frontend -parse Catbird/Core/State/AppState.swift

# Quick check script
./swift-check.sh

# Batch check
fd -e swift . Catbird/Core | xargs -I {} swift -frontend -parse {}
```

### Parallel Agents (Independent Tasks)
```bash
# Quick spawn
./parallel-agents.py quick \
  "Task 1" "Task 2" "Task 3" \
  --approval='--allow-all-tools'

# From config
./parallel-agents.py from-config build-tasks.json

# Interactive
./parallel-agents.py interactive
```

### MCP Server Usage
```bash
# Always verify with Apple docs
apple-doc-mcp:search_symbols(query="SwiftUI performance")
apple-doc-mcp:get_documentation(path="documentation/SwiftUI/View")

# Use xcodebuild-mcp instead of manual xcodebuild
xcodebuild-mcp:build_sim(...)
xcodebuild-mcp:test_sim(...)
```

## Directory Structure

```
/Catbird/
├── docs/
│   └── session-notes/       # Temporary docs (gitignored)
├── parallel-agents-results/ # Agent execution logs (gitignored)
├── AGENTS.md               # Comprehensive agent guide
├── CLAUDE.md               # Claude-specific guide
├── PARALLEL_AGENTS_README.md
└── WORKFLOW_QUICKREF.md    # This file
```

## Parallel Agents Use Cases

### Multi-Platform Builds
```bash
./parallel-agents.py quick \
  "Build iOS Debug target" \
  "Build macOS Debug target" \
  "Run unit tests" \
  --approval='--allow-all-tools'
```

### Code Quality Sweep
```bash
./parallel-agents.py quick \
  "Check Swift syntax in Catbird/Core/" \
  "Check Swift syntax in Catbird/Features/" \
  "Run SwiftLint on all files" \
  "Find print() statements" \
  --approval='--allow-tool shell(swift) --allow-tool shell(swiftlint) --allow-tool shell(rg)'
```

### Documentation Generation
```bash
./parallel-agents.py quick \
  "Document Auth module" \
  "Document Feed module" \
  "Document Profile module" \
  --approval='--allow-tool write'
```

## Key Principles

1. **Efficiency**: Syntax checks over builds, parallel over sequential
2. **Autonomy**: Work continuously, don't self-limit
3. **Clarity**: Direct action, minimal explanation
4. **Organization**: Temp docs in session-notes, permanent docs in root
5. **Verification**: Always check Apple docs via MCP
6. **Pragmatism**: No timelines, no dates, no safety theater

## When to Use What

| Task Type | Tool | Reasoning |
|-----------|------|-----------|
| Code validation | `swift -frontend -parse` | Fast, no dependencies |
| Independent tasks | `parallel-agents.py` | 3-4x speedup |
| Sequential tasks | Direct execution | Context preservation |
| API research | `apple-doc-mcp` | Always verify latest |
| Building | Only when requested | Syntax checks usually sufficient |
| Testing | MCP when available | Consistent automation |

## Documentation Lifecycle

1. **During work**: Create in `docs/session-notes/`
2. **After completion**: Review session notes
3. **Decision**: Promote to permanent docs OR delete
4. **Result**: Clean repository with only valuable docs committed
