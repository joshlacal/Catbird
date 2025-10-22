# Catbird Documentation Index

**Last Updated**: October 20, 2025  
**Status**: Repository cleaned and organized

## 🚀 Start Here

### Essential Reading

1. **[README.md](README.md)** - Project overview and getting started
2. **[AGENTS.md](AGENTS.md)** - AI agent development guidelines (MCP servers, workflows)
3. **[TODO.md](TODO.md)** - Active task list
4. **[CONTRIBUTING.md](CONTRIBUTING.md)** - Contribution guidelines

### For AI Assistants

- **[AGENTS.md](AGENTS.md)** - Comprehensive agent guidelines with MCP integration
- **[CLAUDE.md](CLAUDE.md)** - Claude Code-specific instructions
- **[gemini.md](gemini.md)** - Gemini-specific configuration

## 📋 Task Management

### Active Tasks

- **[TODO.md](TODO.md)** - Master task list
- **[agentic-tasks.json](agentic-tasks.json)** - Task definitions for remaining P2 work
- **[catbird-tasks.json](catbird-tasks.json)** - Comprehensive structured task definitions
- **[README_NEXT_STEPS.md](README_NEXT_STEPS.md)** - Development roadmap

## 🔧 Tooling & Automation

### Copilot CLI Runner

- **[COPILOT_RUNNER_README.md](COPILOT_RUNNER_README.md)** - Complete documentation
- **[COPILOT_RUNNER_QUICKREF.md](COPILOT_RUNNER_QUICKREF.md)** - Quick reference
- **[copilot-runner.py](copilot-runner.py)** - Python implementation
- **[copilot-runner.sh](copilot-runner.sh)** - Bash implementation
- **[copilot-tasks.example.json](copilot-tasks.example.json)** - Example task definitions

### Parallel Agents

- **[PARALLEL_AGENTS_README.md](PARALLEL_AGENTS_README.md)** - Multi-agent orchestration
- **[parallel-agents.py](parallel-agents.py)** - Implementation script

### Workflows

- **[WORKFLOW_QUICKREF.md](WORKFLOW_QUICKREF.md)** - Development workflow reference

### Diagnostic Tools

- **[tools/diagnostics/](tools/diagnostics/)** - Python diagnostic scripts
  - `analyze_order_variance.py` - Build order analysis
  - `swift-check.py` - Swift syntax checking
  - `swift-diagnostics.py` - Detailed diagnostics

## 📚 Reference Documentation

### Guides

- **[docs/guides/PERF_001_INSTRUMENTS_PROFILING_GUIDE.md](docs/guides/PERF_001_INSTRUMENTS_PROFILING_GUIDE.md)** - Profiling with Instruments
- **[docs/guides/PETREL_FEED_TYPES_REFERENCE.md](docs/guides/PETREL_FEED_TYPES_REFERENCE.md)** - Petrel feed types
- **[docs/guides/PUSH_NOTIFIER_MODERATION_QUICKREF.md](docs/guides/PUSH_NOTIFIER_MODERATION_QUICKREF.md)** - Push notification moderation

### Monitoring

- **[README-Sentry.md](README-Sentry.md)** - Sentry error tracking setup

## 📦 Archived Documentation

Historical documentation has been organized into archives to maintain a clean root directory:

### Archived Planning Documents

**Location**: `docs/archived-planning/`

Includes completed feature planning, design docs, and milestone summaries:

- Feed system implementations (FEED_002, FEED_003, FEED_004, FEEDS_UI_001)
- Moderation features (MOD_001, MOD_002, MOD_003)
- Composer features (COMP_002)
- Navigation fixes (NAV_001)
- Messages polish (MSG_002)
- Milestone summaries (P0_QUICK_WINS, P1_MILESTONE_73%, P1_MILESTONE_82%)
- Search overhaul design and implementation
- Push notifier moderation design
- Streaming summaries
- Release notes (December 2024)
- Action plans and execution plans

### Archived Implementation/Fix Documents

**Location**: `docs/archived-fixes/`

Includes completed implementation summaries and fix documentation:

- Feed interactions (complete implementation, changelog, index, quickref, research)
- Feed feedback implementation and summaries
- Label system (complete, fixes summary, labeler support)
- App Attest (debug analysis, quick ref, README, summary, testing guide)
- AppView configuration implementation
- Account switch shadow state fix
- Implementation summaries
- Cleanup summaries
- Session summaries and task completions
- Server-side issue analysis
- Typeahead reply mode issues
- App Attest failure analysis
- Copilot runner status and troubleshooting
- Height validation examples

## 🗂️ Directory Structure

```
/Catbird/
├── docs/
│   ├── archived-planning/       # Completed feature planning and design docs
│   ├── archived-fixes/          # Historical fix and implementation documentation
│   ├── guides/                  # Reference guides and how-tos
│   └── session-notes/           # Temporary session notes (gitignored)
├── tools/
│   └── diagnostics/             # Python diagnostic scripts
├── Catbird/                     # Main app source code
├── Petrel/                      # AT Protocol library
├── CatbirdNotificationWidget/   # iOS notification widget
├── CatbirdFeedWidget/          # iOS feed widget
└── [Root Documentation]         # Essential docs (README, AGENTS, CONTRIBUTING, etc.)
```

## 📝 Documentation Conventions

### File Naming

- `README*.md` - Project and component documentation
- `*_QUICKREF.md` - Quick reference guides
- `*_README.md` - Comprehensive documentation
- `TODO.md` - Active task tracking

### Active Root Documentation

Keep in root only:

- Essential project docs (README, LICENSE, CONTRIBUTING)
- Active AI agent instructions (AGENTS, CLAUDE, gemini)
- Current task tracking (TODO, README_NEXT_STEPS)
- Active tool documentation (COPILOT*RUNNER*_, PARALLEL*AGENTS*_, WORKFLOW_QUICKREF)
- Configuration files (_.json, _.sh, \*.py)

### Archive Criteria

Move to `docs/archived-planning/`:

- Completed feature planning documents
- Obsolete design documents
- Old milestone summaries
- Historical action plans

Move to `docs/archived-fixes/`:

- Completed implementation summaries
- Historical fix documentation
- Session completion summaries
- Resolved issue analysis

## 🔄 Keeping This Index Updated

This index should be updated when:

- New reference documentation is added
- Documentation is archived
- Directory structure changes
- Tool documentation is updated

Last major update: October 20, 2025 (Repository cleanup and reorganization)
