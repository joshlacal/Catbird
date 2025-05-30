# Catbird Git Worktree Development Plan

## Overview
Using git worktrees to enable parallel development across multiple simulators and devices.

## Worktree Structure

### 1. fix/thread-refresh (High Priority)
**Purpose**: Fix thread replies not showing immediately
**Tasks**:
- Implement proper thread update notifications
- Fix ThreadView refresh on new replies
- Ensure optimistic UI updates
**Testing**: iPhone 16 Pro simulator

### 2. fix/account-switching (High Priority)
**Purpose**: Fix account switching state management
**Tasks**:
- Fix feeds not refreshing on account switch
- Fix chat not refreshing after switch
- Implement per-account search history
- Clear and reload all state properly
**Testing**: iPhone 16 simulator + physical device

### 3. feature/error-states (Medium Priority)
**Purpose**: Implement proper error handling and UI states
**Tasks**:
- Create standardized ErrorStateView
- Implement ContentUnavailableView usage
- Add network status indicators
- Show proper error messages instead of blank content
**Testing**: iPhone 16 Plus simulator

### 4. feature/feed-improvements (Medium Priority)
**Purpose**: Fix feed behavior and add headers
**Tasks**:
- Fix over-eager refresh and scroll position
- Add feed headers for unsubscribed feeds
- Implement feed persistence in AppStorage
- Maintain scroll position on background/resume
**Testing**: Physical device

### 5. feature/chat-enhancements (Low Priority)
**Purpose**: Improve chat functionality
**Tasks**:
- Add notification badges to messages tab
- Implement local polling for messages
- Improve message request handling
**Testing**: iPhone SE simulator

## Setup Commands

```bash
# From main repository
cd /Users/joshlacalamito/Developer/Catbird:Petrel/Catbird

# Create worktrees
git worktree add ~/Developer/Catbird-Worktrees/fix-thread-refresh -b fix/thread-refresh
git worktree add ~/Developer/Catbird-Worktrees/fix-account-switching -b fix/account-switching
git worktree add ~/Developer/Catbird-Worktrees/feature-error-states -b feature/error-states
git worktree add ~/Developer/Catbird-Worktrees/feature-feed-improvements -b feature/feed-improvements
git worktree add ~/Developer/Catbird-Worktrees/feature-chat-enhancements -b feature/chat-enhancements
```

## Development Workflow

1. **Main Repository**: Continue dim theme fixes and overall coordination
2. **Worktree 1**: Thread refresh fixes (simulator 1)
3. **Worktree 2**: Account switching fixes (simulator 2)
4. **Worktree 3**: Error states (physical device)
5. **Worktree 4**: Feed improvements (as needed)
6. **Worktree 5**: Chat enhancements (as needed)

## Xcode Configuration

### To avoid build deadlocks:
1. Use different derived data paths for each worktree
2. Close Xcode projects not actively being worked on
3. Use command line builds when possible
4. Set up build scripts with specific derived data paths:

```bash
# Example build script for worktree
xcodebuild -project Catbird.xcodeproj \
  -scheme Catbird \
  -configuration Debug \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/Catbird-thread-refresh \
  -destination "platform=iOS Simulator,name=iPhone 16 Pro"
```

## Simulator Allocation

- **iPhone 16 Pro** (DEEB371A-6A16-4922-8831-BCABBCEB4E41): Thread refresh testing
- **iPhone 16** (9DEB446A-BB21-4E3A-BD6A-D51FBC28617C): Account switching testing
- **iPhone 16 Plus** (C4F81FC1-3AC8-40F1-AA1C-EBC3FFE81B6F): Error states testing
- **iPhone SE** (E0741BE7-0ED6-4376-A550-7BB93C258317): Chat testing
- **Physical Device**: Feed improvements and final testing

## Merge Strategy

1. Each worktree develops independently
2. Create PRs from feature branches to main
3. Test integration on main branch
4. Deploy fixes incrementally

## Current State

- Dim theme navigation bar fix is complete in main
- Ready to create worktrees and begin parallel development
