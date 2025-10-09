# Repository Guidelines

This guide gives prescriptive, production-focused instructions for agents working in this repo.

## Overview & Structure
- Purpose: Production iOS client for Bluesky built with Swift 6 + SwiftUI, using Petrel for AT Protocol.
- App modules: `Catbird/` (App, Core, Features, Resources). Widgets: `CatbirdNotificationWidget/`, `CatbirdFeedWidget/`.
- Tests: `CatbirdTests/` (unit), `CatbirdUITests/` (UI). Tooling: `.swiftlint.yml`, `.sourcekit-lsp/`, helper scripts in repo root.

## Build, Run, Test
- Open: `open Catbird.xcodeproj` (run with ⌘R).
- Build (CLI): `xcodebuild -project Catbird.xcodeproj -scheme Catbird -configuration Debug build`.
- Test (CLI): `xcodebuild -project Catbird.xcodeproj -scheme Catbird -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' test`.
- Fast diagnostics: `./quick-error-check.sh` (analyze), `./swift-check.sh all` (parse + dry-run + lint), `swiftlint`.

## Headless Task Automation (Copilot CLI)
Run multiple tasks in parallel or sequence without manual interaction using GitHub Copilot CLI:

### Quick Start
```bash
# Single task
./copilot-runner.sh single "syntax" "Check Swift files" "--allow-tool 'shell(swift)'"

# Parallel tasks (runs simultaneously)
./copilot-runner.sh parallel \
  "build-ios|Build iOS|--allow-all-tools" \
  "build-macos|Build macOS|--allow-all-tools"

# Sequential tasks (runs in order)
./copilot-runner.py from-file copilot-tasks.example.json --workflow ci-pipeline
```

### Features
- **Parallel execution**: Run independent tasks simultaneously
- **Sequential execution**: Chain dependent operations
- **Headless operation**: Auto-approval with security controls
- **Task definitions**: Reusable JSON/YAML configurations
- **Result logging**: All outputs saved to `copilot-results/`

### Available Tools
- `copilot-runner.sh` - Bash version (simple, portable)
- `copilot-runner.py` - Python version (advanced, JSON/YAML support)
- `copilot-tasks.example.json` - Example task definitions

See `COPILOT_RUNNER_README.md` for full documentation.

## Code Style & Architecture
- Swift API Design Guidelines; 2-space indent; `// MARK:` sectioning.
- Concurrency first: async/await throughout; use Actors for shared mutable state.
- State: prefer `@Observable` models; avoid `ObservableObject` unless required by APIs.
- Navigation: use the central navigation types in `Core/Navigation` rather than ad-hoc routing.
- Conditional compilation: keep `#if os(...)` inside helpers/modifiers, not inline in view modifier chains.

## Testing
- Framework: XCTest. Place unit tests in `CatbirdTests/`, UI tests in `CatbirdUITests/`.
- Naming: files end with `Tests.swift`; methods start with `test` and assert behavior (not implementation).
- Run: Xcode (⌘U) or CLI command above. Add/adjust tests when touching Core/Features.

## Commits & PRs
- Commit style: Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`). Keep changes atomic and descriptive.
- PRs: include summary, linked issues, test plan/outputs, and screenshots for UI. Require green build and lint.

## Security & Configuration
- No secrets in repo. Use Keychain/secure storage; validate entitlements (`*.entitlements`) and `PrivacyInfo.xcprivacy`.
- Prefer `xcodebuild` and helper scripts over the generated `Makefile`.

## Non‑Negotiables
- Production quality only: no placeholders, no TODOs left behind, no temporary code. Maintain strict compiler warnings-free builds.
