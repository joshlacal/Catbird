# Baseline Performance Findings

**Date**: 2026-01-27
**Device**: iPhone 17 Pro Simulator (iOS 26.2)
**Build**: Debug

## Trace Files Captured

| Trace | Template | Duration | Location |
|-------|----------|----------|----------|
| app-launch-baseline.trace | App Launch | 15s | `build/traces/` |
| feed-scroll-baseline.trace | Time Profiler | 60s | `build/traces/` |
| allocations-baseline.trace | Allocations | 60s | `build/traces/` |
| swift-concurrency-baseline.trace | Swift Concurrency | 45s | `build/traces/` |
| leaks-baseline.trace | Leaks | 120s | `build/traces/` |

> **Note**: SwiftUI template not supported on Simulator (requires physical device)

---

## Key Findings

### 1. No Hangs Detected ✅
The Time Profiler (with Hangs detection enabled at 250ms threshold) found **no micro-hangs or hangs** during the 60s feed scroll session. Main thread responsiveness is good.

### 2. No Memory Leaks Detected ✅
The 2-minute Leaks trace with navigation found **no memory leaks**. Retain cycle hygiene appears solid.

### 3. Memory Allocation Patterns

| Metric | Value |
|--------|-------|
| Total heap allocations | ~329 MB |
| Persistent memory | ~12 MB (86K objects) |
| Transient allocations | ~315 MB (373K objects) |
| Allocation events | 833K |

**Observations**:
- High transient churn (373K objects created and destroyed in 60s)
- Most allocations are small (16-64 bytes) — likely value types, closures, strings
- Persistent footprint is reasonable at 12MB

**Top allocation buckets**:
- 64 bytes: 88K allocations (5.6 MB total)
- 16 bytes: 73K allocations (1.1 MB total)  
- 32 bytes: 55K allocations (1.7 MB total)
- 48 bytes: 38K allocations (1.8 MB total)

### 4. Areas for Deeper Investigation

1. **Object Churn**: 373K transient allocations in 60s is notable. Could optimize hot paths that create/destroy many small objects.

2. **Feed Cell Configuration**: Need signposts to identify time spent in cell configuration vs. network/image loading.

3. **Swift Concurrency**: Trace captured but needs Instruments UI analysis for Task/Actor overhead.

4. **App Launch**: 15s trace captured; need to analyze time-to-first-content.

---

## Next Steps

1. **Add Performance Signposts** — Instrument feed loads, image loading, MLS operations, navigation
2. **Capture with Signposts** — Re-run traces to correlate signposts with time profiler data
3. **Profile Specific Journeys** — Thread view, MLS chat, profile loading
4. **Reduce Object Churn** — Identify hot paths creating transient allocations

---

## How to Open Traces

```bash
open build/traces/feed-scroll-baseline.trace
open build/traces/allocations-baseline.trace
open build/traces/app-launch-baseline.trace
```
