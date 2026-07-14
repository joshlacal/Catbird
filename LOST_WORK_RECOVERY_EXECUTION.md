# Lost Work Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore every still-valid behavior from the preserved Catbird feature history onto current `main` without regressing newer authentication, security, replies, repost-menu, or App Intents work.

**Architecture:** Reconstruct behavior in an isolated `jj` workspace rooted at `bfa93955`, one independently verified commit per recovery slice. Treat clean historical commits as evidence and source material, current `main` as the infrastructure authority, and canonical schemas/manifests as the authority for generated output.

**Tech Stack:** Swift 6, SwiftUI, UIKit, SwiftData, App Intents, XCTest, Swift Testing, Xcode, `jj` colocated with Git.

## Global Constraints

- Baseline is `bfa9395512daedb6255f97390df47a9333d11bee`; do not move `main` during reconstruction.
- Never merge or transplant `1b01b528`; it contains committed conflict markers and is inspection-only evidence.
- Preserve newer OAuth, security, reply-thread, repost-menu, and selective App Intents behavior from `main`.
- Never hand-edit generated API or App Intents output; change canonical definitions and regenerate from a clean checkpoint.
- One behavioral slice per commit; never absorb unrelated working-copy changes.
- Build, run, navigate, screenshot, and test UI changes before calling them recovered.
- Physical-device results are required for photo/video capture, Siri, App Intents, and entity lookup.
- All Swift uses two-space indentation and Swift 6 concurrency rules.

---

## File and Responsibility Map

| Area | Primary files | Responsibility |
|---|---|---|
| Recovery control | `LOST_WORK_RECOVERY_DESIGN.md`, `LOST_WORK_RECOVERY_EXECUTION.md` | Invariants, source commits, disposition ledger, verification evidence |
| Feed/profile geometry | `Catbird/Core/UI/FlexibleHeaderGeometry.swift`, `Catbird/Features/Feed/Views/FeedsStartPage.swift`, `Catbird/Features/Profile/Views/Unified/*` | Feed icon sizing and unified banner clipping/layout |
| Draft sync | `Catbird/Core/Models/DraftPost.swift`, `Catbird/Features/Feed/Services/{ComposerDraftManager,DraftPersistence,DraftSyncService}.swift`, `DraftsListView.swift` | Local/remote draft translation, persistence, sync, and selection |
| Composer | `Catbird/Features/Feed/Views/Components/PostComposer/*` | Chips, accessory controls, counter, thread metadata, and sheets |
| Capture/FAB | `Catbird/Core/UI/{FAB,CameraCaptureView,CapturedMedia}.swift`, `Catbird/App/ContentView.swift`, `PostComposerCapturedMediaIngest.swift` | Morphing quick-action UI and captured-media handoff |
| Search | `Catbird/Features/Search/Models/SearchFilterState.swift`, `RefinedSearchViewModel.swift`, `RefinedSearchView.swift`, filter views | Supported sort/date/language parameters and saved-state restoration |
| Feed correctness | `CachedFeedViewPost.swift`, `BackgroundCacheRefreshManager.swift`, `EnhancedFeedPost.swift`, `CatbirdApp.swift` | Per-feed/repost cache identity and header containment |
| Chat/MLS | `UnifiedChatMessage.swift`, `MLSMessageAdapter.swift`, `MLSConversationDataSource.swift`, chat collection views | Edit/unsend capabilities and deterministic display ordering |
| Settings | `AppSettingsModel.swift`, settings views, explicit runtime consumers | Persisted settings and observable product behavior |
| Replies | `PostView.swift`, `UIKitThreadView.swift`, `ThreadReplyLayoutTests.swift` | Sibling connector/layout semantics |
| App Intents | `Catbird/AppIntents/**`, generator manifest/schema inputs, `AppIntentsSiriPathTests.swift` | Shortcut surface, entities, handoffs, donations, and out-of-process lookup |

## Recovery Ledger

Update the disposition column in the same commit that closes each slice. Valid dispositions are `recovered`, `already present`, `superseded`, and `excluded with evidence`.

| Candidate commits | Behavior | Initial disposition |
|---|---|---|
| `d062c2a`, `8e2b09d`, `650f738`, `2f3f4cc` | Feed icons and banner geometry | recovered in `53084284` |
| `412bb74` | Draft translation, account scoping, and drafts-sheet presentation | recovered |
| `412bb74` | Default-on AppView draft sync; current-main requires explicit opt-in as a safety gate | superseded |
| `4e833ba` | Composer chips/accessory redesign | recovered in `44b7e366` and hardened in `b62b5b5c`; unrelated auth/chat content excluded with evidence |
| `17a4479` through `f7322e3`, plus `08e7368`, `dd7fde8` | FAB and capture actions | recovered; the unrelated `dd7fde8` App Intents/UIKit cell annotations are excluded with evidence |
| `fea6386`, `dfb0b1e`, `19ae89a`, `29ab384`, `8881885` | Honest search filters | recovered |
| `68043cb` | Repost/per-feed cache identity | recovered in `d7c098b1`, with store and scope hardening through `cc668b1b` |
| `d5eefcd`, `d06e076` | Own-message actions and sequence-zero ordering | recovered in `6cfc47c9`, with lifecycle hardening through `39ad6e77` |
| `10f1c17` | Settings runtime wiring | recovered in `7932735a`, with runtime and lifecycle hardening through `7f569427` |
| `b86c5ca` | Threaded replies and account cleanup | recovered selectively in the final audit: 48/32/24-point avatar depth cues, 0/12/24-point indentation, and the deeper cap restored while current URI-based connector rules remain authoritative; unrelated account cleanup excluded |
| `67d8872` through `641531a` | App Intents expansion and runtime hardening | recovered from canonical inputs and regenerated in `116cdf7e` |

### Task 1: Isolate and Baseline the Recovery

**Files:**
- Modify: `LOST_WORK_RECOVERY_EXECUTION.md`
- Evidence: `/tmp/catbird-recovery-baseline/`

**Interfaces:**
- Consumes: `main`, `search-filtering-merged`, `feature/compose-fab-quick-actions`
- Produces: isolated workspace `Catbird-recovery`, rescue bookmarks, baseline build/test evidence

- [x] **Step 1: Verify source identities and preserve them**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel/Catbird
jj status
git cat-file -e bfa9395512daedb6255f97390df47a9333d11bee^{commit}
git cat-file -e 88818854beac35b0b5733bf94b76cee940a641fb^{commit}
git cat-file -e f7322e39b7ba880c853875c70f4b450f33668045^{commit}
jj bookmark create rescue/lost-work-broad -r 88818854beac35b0b5733bf94b76cee940a641fb
jj bookmark create rescue/compose-fab -r f7322e39b7ba880c853875c70f4b450f33668045
```

Expected: the source commits resolve and both rescue bookmarks point at the clean preserved heads. If either bookmark already exists, verify its target instead of recreating it.

- [x] **Step 2: Prevent the sibling workspace from entering the dirty umbrella repository**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel
grep -qxF '/Catbird-recovery/' .git/info/exclude || printf '%s\n' '/Catbird-recovery/' >> .git/info/exclude
```

Expected: this changes only the local Git exclude file, not a tracked file.

- [x] **Step 3: Create the isolated workspace from the approved design commit**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel/Catbird
jj workspace add /Users/joshlacalamito/Developer/Catbird+Petrel/Catbird-recovery \
  --revision codex/recover-lost-catbird-work
cd /Users/joshlacalamito/Developer/Catbird+Petrel/Catbird-recovery
jj new codex/recover-lost-catbird-work
jj status
```

Expected: clean empty working-copy commit whose parent contains only the approved design documentation plus baseline `main`.

- [x] **Step 4: Record baseline health**

```bash
mkdir -p /tmp/catbird-recovery-baseline
xcodebuild -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,id=40111BBE-8709-40D0-9016-A27448486A80' build \
  | tee /tmp/catbird-recovery-baseline/ios-build.log
xcodebuild test -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,id=40111BBE-8709-40D0-9016-A27448486A80' \
  | tee /tmp/catbird-recovery-baseline/ios-tests.log
xcodebuild -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=macOS' build \
  | tee /tmp/catbird-recovery-baseline/macos-build.log
```

Expected: `** BUILD SUCCEEDED **` for both builds and `** TEST SUCCEEDED **`, or exact pre-existing failures recorded in the ledger before feature edits.

- [x] **Step 5: Seal the baseline evidence note**

Add the baseline revision, command results, and any pre-existing failures beneath Task 1. Then:

```bash
jj describe -m 'Catbird: record recovery baseline'
jj new
```

#### Task 1 baseline evidence (2026-07-13)

- Approved recovery parent: `ecda750f824803d17352c65db92845e3582fd2af` (`Catbird: add lost-work recovery implementation plan`), based on `main` at `bfa9395512daedb6255f97390df47a9333d11bee`.
- Preserved sources: `rescue/lost-work-broad` points to `88818854beac35b0b5733bf94b76cee940a641fb`; `rescue/compose-fab` points to `f7322e39b7ba880c853875c70f4b450f33668045`.
- Isolation: sibling `jj` workspace `Catbird-recovery` was created from the approved recovery parent. The dirty umbrella repository excludes `/Catbird-recovery/` through its local `.git/info/exclude`; no tracked umbrella file was changed.
- iOS simulator build: PASS. The prior name-only iPhone simulator build command exited 0 with `** BUILD SUCCEEDED **`. Full output: `/tmp/catbird-recovery-baseline/ios-build.log`.
- iOS simulator tests: PRE-EXISTING INFRASTRUCTURE FAILURE. The prior name-only iPhone full-scheme test command built the app and test bundles, then spent more than five consecutive minutes in a simulator-launch loop without starting any test case. Xcode repeatedly emitted `IDELaunchParametersSnapshot: debugger version lookup failed for path '<nil>': noURL` followed by `IDELaunchParametersSnapshot: no debugger version`, interleaved with repeated package resolution. The command was terminated cleanly with Ctrl-C after approximately eleven minutes total and exited 130. Captured standard output: `/tmp/catbird-recovery-baseline/ios-tests.log`.
- macOS build: PRE-EXISTING COMPILE FAILURE. The required `xcodebuild ... -destination 'platform=macOS' build` command exited 65 with `** BUILD FAILED **`. `Catbird/Features/Feed/Views/FeedsStartPage.swift:1426:15` reports `'GlassEffectContainer' is only available in macOS 26.0 or newer`; its enclosing branch checks only `if #available(iOS 26.0, *)`, so the macOS compiler requires an additional availability check. Captured standard output, including the compiler diagnostic: `/tmp/catbird-recovery-baseline/macos-build.log`.
- Recovery gate: no feature code was edited. Task 2 must treat the simulator launch loop and macOS availability error as baseline failures rather than regressions introduced by recovered behavior.

#### Task 1A baseline gate repair evidence

- Root causes: three installed runtimes expose an iPhone 17 Pro, making the name-only destination ambiguous; the shared feeds title-row branch also omitted the `macOS 26.0` availability requirement for `GlassEffectContainer`.
- Pinned focused tests: PASS. XcodeBuildMCP launched `FeedsLaunchpadLayoutTests` on iOS 26.2 simulator `40111BBE-8709-40D0-9016-A27448486A80`; all seven tests passed. The post-fix full suite also ran and passed those same seven tests.
- Post-fix full iOS suite: FAIL after launching normally, exiting 65 with `** TEST FAILED **`. `ConcentricLiquidGlassDrawerTests.backdropTuningScrubsBackdropBlurWithLightScrim()` expected scrim opacity `0.1` but received `0.18`; separately, `CatbirdUITests-Runner` could not load because Xcode beta's `AppIntentsTesting.framework` was built for iOS simulator 26.4 and requires an unavailable `AppIntentsTypeSupport.framework` on iOS 26.2. Full output: `/tmp/catbird-recovery-baseline-repair/ios-tests.log`; result bundle: `/Users/joshlacalamito/Library/Developer/Xcode/DerivedData/Catbird-gryvknwoutnhbsfxyasxwrraencn/Logs/Test/Test-Catbird-2026.07.13_16-55-20--0400.xcresult`.
- Post-fix macOS build: PASS. Adding the shared macOS availability clause cleared the compiler error; the exact build exited 0 with `** BUILD SUCCEEDED **`. Full output: `/tmp/catbird-recovery-baseline-repair/macos-build.log`.

#### Task 1B baseline test gate repair evidence

- Historical production tuning: commit `29013f363fa7` intentionally raised `ConcentricDrawerBackdropMetrics.maximumScrimOpacity` from `0.1` to `0.18` for legibility, while `ConcentricLiquidGlassDrawerTests` retained the obsolete `0.1` assertion. The regression test now matches the shipped `0.18` full-progress scrim.
- Pre-fix simulator loader failure: `AppIntentsSiriPathTests.swift` unconditionally imported `AppIntentsTesting`, forcing every simulator `CatbirdUITests` bundle to link its device-oriented support chain. On the pinned iOS 26.2 runtime, the runner failed before test discovery because `AppIntentsTypeSupport.framework` was unavailable. The import and physical iOS 27 test class are now excluded from simulator compilation while remaining intact for physical devices.
- Xcode 27 beta launcher fallback: direct focused `xcodebuild test` and `test-without-building` commands repeated the known debugger-launch loop. The required `build-for-testing` fallback completed with `** TEST BUILD SUCCEEDED **` in `/tmp/catbird-task1b-build-for-testing.log`; focused execution then used XcodeBuildMCP with the same pinned simulator.
- Post-fix drawer suite: PASS on iOS 26.2 simulator `40111BBE-8709-40D0-9016-A27448486A80`; all 6 discovered tests passed. Build log: `/Users/joshlacalamito/Library/Developer/XcodeBuildMCP/workspaces/Catbird-Petrel-abf01301fe68/logs/test_sim_2026-07-13T21-20-44-906Z_pid79600_c85c6898.log`.
- Post-fix UI loader: PASS on the same simulator; `CatbirdUITestsLaunchTests/testLaunch` was discovered and passed, proving the test runner loads without the missing App Intents support framework. Build log: `/Users/joshlacalamito/Library/Developer/XcodeBuildMCP/workspaces/Catbird-Petrel-abf01301fe68/logs/test_sim_2026-07-13T21-23-01-128Z_pid79600_7a50d278.log`.
- Post-fix unit target: PASS on the same simulator; XcodeBuildMCP reported 174 logical tests passed with 0 failures and 0 skips. Build log: `/Users/joshlacalamito/Library/Developer/XcodeBuildMCP/workspaces/Catbird-Petrel-abf01301fe68/logs/test_sim_2026-07-13T21-25-31-803Z_pid79600_4826619d.log`.

### Task 2: Recover Feed Icons and Unified Banner Geometry

**Files:**
- Modify: `Catbird/Core/UI/FlexibleHeaderGeometry.swift`
- Modify: `Catbird/Features/Feed/Views/FeedsStartPage.swift`
- Modify: `Catbird/Features/Profile/Views/Unified/UnifiedProfileView.swift`
- Create or reconcile: `Catbird/Features/Profile/Views/Unified/ProfileBannerHeader.swift`
- Test: `CatbirdTests/FeedsLaunchpadLayoutTests.swift`

**Interfaces:**
- Produces: `ConcentricBannerClip(horizontalInset:minimumCornerRadius:)`, final `ProfileBannerHeader`, feed icon sizing clamped around `itemWidth * 0.8`

- [x] **Step 1: Add a failing icon-metric regression test**

Expose an internal pure metric and test it:

```swift
@Test("Feed start icons use eighty percent of available card width")
func feedStartIconScale() {
  #expect(FeedsStartPageLayoutMetrics.iconSize(itemWidth: 50) == 64)
  #expect(FeedsStartPageLayoutMetrics.iconSize(itemWidth: 100) == 80)
  #expect(FeedsStartPageLayoutMetrics.iconSize(itemWidth: 200) == 110)
}
```

Run:

```bash
xcodebuild test -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,id=40111BBE-8709-40D0-9016-A27448486A80' \
  -only-testing:CatbirdTests/FeedsLaunchpadLayoutTests
```

Expected: FAIL because `FeedsStartPageLayoutMetrics.iconSize` does not yet exist.

Evidence: the pinned shell run exited 65 with three expected `Cannot find
'FeedsStartPageLayoutMetrics' in scope` diagnostics before production edits.

- [x] **Step 2: Restore the final geometry, not an intermediate diff**

Use `git show d062c2a:...`, `git show 650f738:...`, and `git show 2f3f4cc:...` side-by-side with current files. Implement this stable interface:

```swift
enum FeedsStartPageLayoutMetrics {
  static func iconSize(itemWidth: CGFloat) -> CGFloat {
    max(64, min(itemWidth * 0.8, 110))
  }
}

struct ConcentricBannerClip: ViewModifier {
  var horizontalInset: CGFloat = 0
  var minimumCornerRadius: CGFloat = 16

  @State private var resolvedTopRadius: CGFloat?

  private var cornerRadius: CGFloat {
    max(resolvedTopRadius ?? 0, minimumCornerRadius)
  }

  func body(content: Content) -> some View {
    content
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .onGeometryChange(for: CGFloat.self) { proxy in
        if #available(iOS 27.0, macOS 27.0, *),
          let radii = proxy.concentricCornerRadii
        {
          return max(radii.topLeading, radii.topTrailing)
        }
        return 0
      } action: { topRadius in
        if topRadius > 0 {
          resolvedTopRadius = topRadius
        }
      }
      .padding(.horizontal, horizontalInset)
  }
}
```

Extract `ProfileBannerHeader` as in `8e2b09d`, retain `Color.clear.overlay` containment from `650f738`, and retain the zero horizontal inset from `2f3f4cc`. Do not restore deleted UIKit profile controllers or `_trash` files.

- [x] **Step 3: Run focused tests and build**

Run the Task 2 test command, then the iOS build command from Task 1. Expected: PASS and `** BUILD SUCCEEDED **`.

Evidence: XcodeBuildMCP on the pinned iOS 26.2 simulator passed all 8
`FeedsLaunchpadLayoutTests` and the subsequent iOS simulator build succeeded.

- [ ] **Step 4: Verify visually**

Launch the app, use UI hierarchy inspection to open Feed Start and a unified profile, and capture compact-width and regular-width screenshots. Confirm larger icons, centered content, a continuous concentric curve, full-bleed banner edges, and no image overflow.

Blocked boundary: the app launched on the compact simulator, but its retained
state is the sign-in screen with `GatewayOAuthExchangeError error 2`, so the
two authenticated screens could not be reached without mutating account state.
Xcode-beta UI hierarchy capture also failed because its private
`SimulatorKit.framework` is absent. Exact launch-state screenshot:
`/tmp/catbird-task2-iphone.png`.

- [x] **Step 5: Update ledger and commit**

```bash
jj describe -m 'Catbird: recover feed icons and profile banner geometry'
jj new
```

### Task 3: Reconcile Draft Sync and Drafts UI

**Files:**
- Modify: `Catbird/Core/Models/DraftPost.swift`
- Modify: `Catbird/Core/Settings/ExperimentalSettings.swift`
- Modify: `Catbird/Features/Feed/Services/ComposerDraftManager.swift`
- Modify: `Catbird/Features/Feed/Services/DraftPersistence.swift`
- Modify: `Catbird/Features/Feed/Services/DraftSyncService.swift`
- Modify: `Catbird/Features/Feed/Views/Components/PostComposer/DraftsListView.swift`
- Modify: `Catbird/Features/Feed/Views/Components/PostComposer/PostComposerViewUIKit/PostComposerViewUIKit+Sheets.swift`
- Test: `CatbirdTests/DraftSyncTranslationTests.swift`
- Test: `CatbirdTests/PostComposerFixesTests.swift`

**Interfaces:**
- Produces: `DraftSyncTranslator.isSyncable(_:)`, `remoteDraft(...)`, `localDraft(from:includeLocalMedia:)`, account-scoped draft selection and working-draft preservation

- [x] **Step 1: Run current draft tests before editing**

```bash
xcodebuild test -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,id=40111BBE-8709-40D0-9016-A27448486A80' \
  -only-testing:CatbirdTests/DraftSyncTranslationTests \
  -only-testing:CatbirdTests/PostComposerFixesTests
```

Expected: establishes whether `412bb74` is already present. A passing test is evidence, not automatic proof that the UI behavior is present.

Evidence: the pre-edit command passed all 12 enumerated
`DraftSyncTranslationTests`. `PostComposerFixesTests.swift` is excluded from the
current `CatbirdTests` target by the Xcode project and therefore did not
enumerate; the recovered account-selection regressions were added to the
targeted translation suite instead.

- [x] **Step 2: Reconcile `412bb74` symbol by symbol**

Retain or restore these exact semantics:

```swift
enum DraftSyncTranslator {
  static let maxPosts = 100
  static let maxLangs = 3
  static let maxTextLength = 10_000
  static let maxDeviceNameLength = 100
  static func isSyncable(_ draft: PostComposerDraft) -> Bool
  static func remoteDraft(from draft: PostComposerDraft, deviceId: String?, deviceName: String?) -> AppBskyDraftDefs.Draft
  static func localDraft(from remote: AppBskyDraftDefs.Draft, includeLocalMedia: Bool) -> PostComposerDraft
}
```

Keep remote media as device-local references, exclude reply/quote drafts from sync, preserve account scoping, and keep current Petrel-generated signatures when they differ from history.

Evidence: reconciled the historical behavior against current generated Petrel
types, including schema clamping, current gallery writes plus legacy image
reads, non-advancing pagination termination, device-local media metadata,
account-scoped selection, and immediate working-draft preservation. The
historical default-on sync flag was not restored; current main's explicit
opt-in default remains the safety gate.

- [ ] **Step 3: Verify selection and sync UI**

Run the tests again, build, launch Drafts, select a local draft, return to the composer, and confirm its text/thread metadata restore. If a test account supports AppView drafts, pull then push a text-only draft and confirm round-trip behavior.

Automated evidence: all 17 enumerated `DraftSyncTranslationTests` passed on simulator
`40111BBE-8709-40D0-9016-A27448486A80`; the fresh `Catbird` simulator build
exited 0; and the built app installed, launched, and rendered its authenticated
timeline (`/tmp/catbird-task3-launch.png`). The focused suite covers local
selection, thread restoration, schema/media translation, and drafts-row media
metadata.

Outstanding runtime QA gates:

- [ ] Launch Drafts, inspect grouped rows/thumbnails/sync disclosure, select a
  local draft, and confirm text/thread metadata in the composer.
- [ ] With explicit authorization to mutate test-account data, pull then push a
  text-only AppView draft and confirm the round trip.

These remain open because scripted simulator tooling could not reliably navigate
into the Drafts sheet and a live AppView round trip would mutate the signed-in
account's remote drafts. App launch alone does not close either gate.

- [x] **Step 4: Update ledger and commit**

```bash
jj describe -m 'Catbird: reconcile draft sync and drafts presentation'
jj new
```

### Task 4: Recover Composer Chips and Accessory Presentation

**Files:**
- Create or reconcile: `Catbird/Features/Feed/Views/Components/PostComposer/Components/ComposerAccessoryBar.swift`
- Create or reconcile: `Catbird/Features/Feed/Views/Components/PostComposer/Components/ComposerChipsStrip.swift`
- Modify: composer component and `PostComposerViewUIKit` files listed by `git diff-tree -r 4e833ba`
- Test: `CatbirdTests/ComposerChipsStripTests.swift`
- Test: `CatbirdTests/ComposerCounterDisplayTests.swift`

**Interfaces:**
- Produces: pure chip visibility/summary state, character-counter display threshold, reusable accessory bar consumed by the UIKit composer

- [x] **Step 1: Restore the two focused test files from `4e833ba` and run them**

Tests must cover hidden/visible chip state, threadgate summary text, counter hidden far from the limit, visible at fifty remaining, and custom maximum count.

```bash
xcodebuild test -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,id=40111BBE-8709-40D0-9016-A27448486A80' \
  -only-testing:CatbirdTests/ComposerChipsStripTests \
  -only-testing:CatbirdTests/ComposerCounterDisplayTests
```

Expected: FAIL for every absent historical interface; already-passing cases receive `already present` ledger evidence.

Evidence: both restored suites were included by the synchronized test target. The
pre-production run failed at compile time only because `ComposerChipsStrip` and
`ComposerCounterDisplay` were absent, covering every required historical
interface. After the composer-owned implementation, all 6 focused tests passed
on simulator `40111BBE-8709-40D0-9016-A27448486A80`.

- [x] **Step 2: Port only the composer-owned portion of `4e833ba`**

Implement `ComposerChipsStrip` and `ComposerAccessoryBar`, then wire them through `PostComposerViewUIKit.swift`, `+Actions`, `+Metadata`, `+Sheets`, and `+Thread`. Exclude `AuthManager`, profile, and chat files from this commit. Preserve current submit validation and media-state synchronization.

Evidence: restored the pure chip/counter policies, reusable safe-area accessory
bar, Liquid Glass plus menu with legacy fallback, and the current UIKit
composer bindings. The old editor-owned keyboard toolbar was disabled to avoid
duplicate controls. Existing sheet bindings supply the accessory actions; no
historical auth, profile, chat, generated Petrel, submit, media, or draft code
was imported.

- [ ] **Step 3: Test and visually verify**

Run the focused tests plus `PostComposerFixesTests`, build, and capture composer screenshots for empty, language-selected, labels-selected, threadgate-selected, and near-character-limit states.

Automated evidence: all 6 focused tests passed, then a fresh XcodeBuildMCP
simulator build succeeded, installed, and launched the authenticated app as
process 23149; the authenticated timeline is captured at
`/tmp/catbird-task4-launch.png`. `PostComposerFixesTests.swift` and the other historical composer
suites remain excluded from the current `CatbirdTests` target; the two restored
suites are the only composer suites that enumerate.

Outstanding visual QA gate: the empty, language, labels, threadgate, and
near-limit states remain unobserved. Xcode-beta hierarchy capture failed because
`SimulatorKit.framework` is absent, so the running app could not be navigated
reliably into each composer state. Build and launch evidence do not close these
visual checks.

- [x] **Step 4: Update ledger and commit**

```bash
jj describe -m 'Catbird: recover composer chips and accessory controls'
jj new
```

- [x] **Independent review follow-up: make link creation selection-safe**

All UIKit composer link entry points now use one presentation method that reads
the active `UITextView.selectedRange`, validates it against the current
attributed text, derives the selected text, and falls back to an end-of-text
caret if the range is unavailable or invalid. Completion refuses a changed
source string or an invalid/changed selected range. Valid completion uses
`RichTextFacetUtils.addOrInsertLinkFacet`, including zero-length caret insertion;
the old direct unchecked `NSMutableAttributedString.addAttribute` path was
removed.

Strict TDD evidence: `ComposerLinkEditTests` first failed to compile because the
wished-for `ComposerLinkEdit` interface was absent. After implementation, the
focused `build-for-testing` completed with `** TEST BUILD SUCCEEDED **`, and
`test-without-building` completed with `** TEST EXECUTE SUCCEEDED **`: all 10
tests across `ComposerLinkEditTests`, `ComposerChipsStripTests`, and
`ComposerCounterDisplayTests` passed on simulator
`40111BBE-8709-40D0-9016-A27448486A80`. Logs:
`/tmp/catbird-task4-link-red.log`, `/tmp/catbird-task4-link-build.log`, and
`/tmp/catbird-task4-link-focused.log`.

### Task 5: Recover the Morphing FAB and Capture Handoff

**Files:**
- Modify: `Catbird/App/ContentView.swift`
- Modify: `Catbird/Core/UI/FAB.swift`
- Create: `Catbird/Core/UI/CapturedMedia.swift`
- Create: `Catbird/Core/UI/CameraCaptureView.swift`
- Create: `Catbird/Features/Feed/Views/Components/PostComposer/PostComposerCapturedMediaIngest.swift`
- Modify: `PostComposerViewUIKit.swift`, `PostComposerMediaManagement.swift`
- Test: `CatbirdTests/CapturedMediaIngestTests.swift`

**Interfaces:**
- Produces: `CapturedMedia.photo(Data)`, `CapturedMedia.video(URL)`, `CameraCaptureMode`, a single-orb FAB exposing New Post/Browse Drafts/Take Photo/Record Video, and captured-media ingestion into the current composer thread entry

- [x] **Step 1: Restore capture ingestion tests and verify failure**

Restore the photo-add and image-limit tests from `51036b1`, then run:

```bash
xcodebuild test -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,id=40111BBE-8709-40D0-9016-A27448486A80' \
  -only-testing:CatbirdTests/CapturedMediaIngestTests
```

Expected: FAIL until captured-media interfaces exist.

- [x] **Step 2: Add the capture boundary**

```swift
enum CapturedMedia {
  case photo(Data)
  case video(URL)
}

enum CameraCaptureMode: Identifiable {
  case photo
  case video
  var id: Int {
    switch self {
    case .photo: return 0
    case .video: return 1
    }
  }
}
```

Wrap the supported UIKit capture controller in `CameraCaptureView` and return one `CapturedMedia` result or cancellation. Do not place composer state inside the camera wrapper.

- [x] **Step 3: Restore ingestion and the single-orb menu**

Port the ingestion boundary from `51036b1` plus the shared `syncMediaStateToCurrentThread()` call from `670c265`. Reconstruct the FAB chain through `f7322e3`, then apply the single-orb correction from `08e7368`. New Post opens a clean composer; Browse Drafts robustly opens the draft destination; capture actions first stash the current working draft.

- [ ] **Step 4: Verify automated and runtime behavior**

Run capture and composer tests, build, then verify the morph under Reduce Motion on/off and Reduce Transparency on/off. On a physical iPhone, capture one photo and one video, cancel each flow once, and confirm an existing text draft survives all four paths.

- [x] **Step 5: Update ledger and commit**

```bash
jj describe -m 'Catbird: recover compose FAB quick actions and media capture'
jj new
```

#### Task 5 recovery evidence (2026-07-13)

- Archaeology: `51036b1` supplied the captured-photo/video ingestion boundary and its two focused regressions; `670c265` supplied the shared `syncMediaStateToCurrentThread()` call. `cc1952b`/`4b5a04c` supplied the supported `UIImagePickerController` wrapper and identifiable capture modes. The quick-action chain from `17a4479` through `f7322e3` supplied New Post, Browse Drafts, Take Photo, Record Video, draft stashing, and robust drafts-sheet selection. `08e7368` superseded the redundant second glass layer so the recovered control remains one orb. `dd7fde8` changed only an App Intents annotation on the FAB plus unrelated UIKit feed/thread annotations; those changes are excluded from this slice.
- TDD RED: the restored `CapturedMediaIngestTests` failed at compile time because `PostComposerViewModel` had no `ingestCapturedPhoto`. After the minimal ingestion boundary was added, the pure FAB/capture boundary tests failed because `FABQuickAction` and `CameraCaptureMode` did not exist. Logs: `/tmp/catbird-task5-capture-red.log` and the first run recorded in `/tmp/catbird-task5-capture-green.log`.
- TDD GREEN: the dedicated focused run passed all 4 tests across `CapturedMediaIngestTests` and `FABQuickActionTests`, covering photo ingestion, image-limit refusal, the exact four recovered action titles/order, and stable photo/video identities. Log: `/tmp/catbird-task5-focused-green.log`.
- Preservation regression: the initial 43-test slice passed, then the post-review preservation slice passed 49/49 with zero failures across captured media, managed capture storage, transactional draft stashing, FAB actions, composer chips/counter/link editing, draft translation/account scoping, and the legacy OAuth compatibility hotfix. Logs: `/tmp/catbird-task5-regression.log` and `/tmp/catbird-task5-review-regression.log`.
- Review hardening TDD: `/tmp/catbird-task5-review-red.log` failed on missing `WorkingDraftStashPolicy`, `CapturedVideoStore`, and the production-menu action model. `/tmp/catbird-task5-review-green.log` then passed 9/9. A separate URL-backed video test failed on the missing captured-video factory (`/tmp/catbird-task5-video-url-red.log`) and passed 3/3 after the minimal implementation (`/tmp/catbird-task5-video-url-green.log`).
- Lifecycle hardening: New Post and camera routes now await a durable draft save and refuse transition on failure; camera availability is checked before any draft mutation. Captured videos are copied off the main actor into app-group `SharedDrafts/CapturedMedia` and remain URL-backed rather than eagerly loading the movie into `Data`. The first review pass supplied and unit-tested the `CapturedVideoStore` ownership/removal helper; it did not yet connect that helper to saved-draft deletion. Successful stashing detaches the working copy without deleting media now owned by the saved record. The production FAB menu is generated from exactly four actions; Clear Draft is no longer a fifth menu item.
- Saved-draft cleanup integration: `DatabaseModelActor` now decodes persisted video references before deleting the row and returns them only after the deletion save succeeds. `DraftPersistence` then removes only URLs owned by `SharedDrafts/CapturedMedia`; missing-row failure and unowned URLs preserve their files. `ComposerDraftManager.clearDraft()` no longer performs eager file cleanup for a restored persisted row, and remote-propagated local deletion uses the same post-commit lifecycle. RED: `/tmp/catbird-task5-delete-lifecycle-red.log` (owned file remained) and `/tmp/catbird-task5-predelete-policy-red.log` (missing ordering policy). GREEN: `/tmp/catbird-task5-delete-lifecycle-final-green.log` (4/4).
- Post-integration preservation: the combined 10-suite run completed 51 tests; all four lifecycle tests plus the OAuth, FAB, draft-sync, composer, stash-policy, and capture-store coverage passed. `CapturedMediaIngestTests.ingestCapturedPhotoRespectsLimit` did not complete because the test host terminated immediately after the pre-existing `FeedFeedbackManager` runtime fatal (`deallocated with non-zero retain count 2`). An isolated rerun reproduced the same fatal at the same second test. This is recorded as an unresolved harness/runtime failure, not a passing preservation run. Logs: `/tmp/catbird-task5-delete-lifecycle-preservation.log` and `/tmp/catbird-task5-captured-media-isolation.log`.
- Final cleanup-integration build/runtime: XcodeBuildMCP built, installed, and launched `blue.catbird` (process 57625) on simulator `0F51B352-E2B1-4647-9958-0F0E2594F05F`. Build log: `~/Library/Developer/XcodeBuildMCP/workspaces/Catbird-Petrel-abf01301fe68/logs/build_run_sim_2026-07-14T04-00-53-024Z_pid95698_6a29f517.log`.
- Build/runtime: XcodeBuildMCP built, installed, and launched `blue.catbird` on authenticated simulator `40111BBE-8709-40D0-9016-A27448486A80`. The running Timeline visibly contains one compose orb; screenshot: `/tmp/catbird-task5-launched.png`. Build log: `~/Library/Developer/XcodeBuildMCP/workspaces/Catbird-Petrel-abf01301fe68/logs/build_run_sim_2026-07-14T03-00-07-612Z_pid95668_da2bdbe1.log`. This closes build, launch, authenticated-state, and closed-orb presence only.
- Post-review build/runtime: the final hardened tree built, installed, and launched successfully as `blue.catbird` (process 62417) on the same simulator. Build log: `~/Library/Developer/XcodeBuildMCP/workspaces/Catbird-Petrel-abf01301fe68/logs/build_run_sim_2026-07-14T03-26-45-871Z_pid95698_8ff33221.log`.
- Open runtime gates: Xcode beta's missing `SimulatorKit.framework` prevents semantic UI inspection/tapping, and the simulator has no supported camera source. Menu expansion/action routing, photo capture, video capture, each cancellation path, captured-video eligibility, and Reduce Motion/Reduce Transparency variants therefore remain physical-device checks; they are not inferred from build success. An unavailable camera is refused before draft mutation or `UIImagePickerController` presentation; an available-camera route awaits the durable stash before presenting.

### Task 6: Recover Honest Search Filters

**Files:**
- Create or reconcile: `Catbird/Features/Search/Models/SearchFilterState.swift`
- Modify: `SearchModels.swift`, `RefinedSearchViewModel.swift`, `RefinedSearchView.swift`, `SaveSearchSheet.swift`, `SavedSearchesSection.swift`, `BasicFilterView.swift`
- Create or reconcile: `SearchFilterBar.swift`, `SearchFiltersSheet.swift`
- Remove only if still present: `AdvancedSearchParams.swift`, `AdvancedFilterView.swift`, `SearchSortSelector.swift`
- Test: `CatbirdTests/SearchFilterStateTests.swift`

**Interfaces:**
- Produces: `SearchFilterState` with `.sort`, `.dateRange`, custom bounds, optional language, `activeFilterCount`, `sortValue`, `languageContainer`, and `dateBounds(now:)`

- [x] **Step 1: Restore the complete focused test suite and run it**

The suite from `8881885` must cover defaults, counts, API sort mapping, fixed/custom bounds, language conversion, Codable round-trip, and legacy saved-search reset.

- [x] **Step 2: Implement supported parameters only**

```swift
struct SearchFilterState: Codable, Equatable {
  var sort: SearchSort = .top
  var dateRange: SearchDateRange = .anytime
  var customStartDate: Date?
  var customEndDate: Date?
  var language: String?
}
```

Wire only real `searchPosts` sort/date/language parameters. Apply filters before the request, reset the cursor when query/filter state changes, and load all saved state before searching. Do not restore fictional media/verification/follower filters.

- [ ] **Step 3: Test and verify UI**

Run `SearchFilterStateTests`, build, then verify Top/Latest pills, filter count, date/language selection, saved-search reload, and pagination after a filter change.

- [x] **Step 4: Update ledger and commit**

```bash
jj describe -m 'Catbird: recover supported search filters'
jj new
```

#### Task 6 recovery evidence (2026-07-14)

- Archaeology: `fea6386`/`dfb0b1e` supplied the pure supported filter model and
  focused tests; `19ae89a` replaced the unused fictional query dictionary with
  real Petrel `sort`/`since`/`until`/`lang` arguments; `29ab384` supplied the
  inline Top/Latest bar and compact filter sheet; `8881885` closed cursor reset,
  saved-state ordering, and explicit-language precedence. The current Petrel
  generated signature was inspected directly and supports those parameters.
- Root cause: current code computed `queryParams` from date and
  `AdvancedSearchParams` but never passed that dictionary to `searchPosts`.
  Initial search, refresh, and pagination also constructed different requests,
  allowing pagination to drop filters, while saved-search reload called a bare
  post search after loading only the obsolete schema.
- TDD RED: the restored 10-test `SearchFilterStateTests` suite failed to compile
  because `SearchFilterState` was absent (`/tmp/recovery-task6-red.log`). Four
  additional wiring regressions then failed for the missing supported parameter
  builder, pre-search cursor reset, saved-state ordering, and honest filter UI
  (`/tmp/recovery-task6-wiring-red.log`).
- TDD GREEN: the final focused run passed 14/14 tests across
  `SearchFilterStateTests` and `SearchFilterWiringTests`; log:
  `/tmp/recovery-task6-focused-green.log`.
- Preservation: 34/34 tests passed across `GatewayOAuthExchangeTests`,
  `DraftSyncTranslationTests`, `ComposerChipsStripTests`, and
  `FABQuickActionTests`; log: `/tmp/recovery-task6-preservation.log`.
- Build/runtime: the iOS simulator build exited 0 with `** BUILD SUCCEEDED **`
  (`/tmp/recovery-task6-build.log`). The resulting app installed and launched on
  authenticated simulator `40111BBE-8709-40D0-9016-A27448486A80` as process
  21490; launch screenshot: `/tmp/recovery-task6-auth-launch.png`.
- Disposition: only API-supported sort, date bounds, and one optional language
  were recovered. `AdvancedSearchParams`, `AdvancedFilterView`, and
  `SearchSortSelector` were moved to repository `_trash` per file-safety rules;
  fictional media, verification, follower, engagement, and local re-ranking
  filters are excluded with evidence.
- Open runtime gates: Top/Latest interaction, active filter count, custom
  date/language selection, saved-search reload, and pagination after a filter
  change remain unobserved. Xcode beta cannot load its private
  `SimulatorKit.framework`, so semantic UI inspection/tapping is unavailable.
  Build, source-contract tests, and authenticated launch do not close these
  interactive checks.

#### Task 6 review hardening evidence (2026-07-14)

- Request correctness: every committed query/filter change now creates an
  immutable `SearchRequestSnapshot` with a monotonic generation. The preceding
  execution task is cancelled, and initial, refresh, and pagination responses
  are generation-gated before they can mutate results or cursors. Pagination
  also refuses snapshots that no longer match the visible query/filter state.
- Custom dates: selecting Custom initializes concrete editable dates. Request
  bounds normalize reversed dates and translate the UI's inclusive end date to
  the API's next-day exclusive `until` bound.
- Refresh and saved searches: refresh installs response cursors rather than
  resetting successful pagination to `nil`; both saved-search entry points now
  update `RefinedSearchView.searchText` before committing the restored search.
- Review RED: `/tmp/recovery-task6-review-red.log` failed at compile time on the
  absent generation helper, date normalization API, and custom-date selection
  API. The first integrated attempt then exposed a missing preview callback and
  two stale source-contract assertions; these were corrected before final
  verification.
- Review GREEN: `/tmp/recovery-task6-review-green.log` passed 20/20 across
  `SearchFilterStateTests` and `SearchFilterWiringTests`, including stale
  generation rejection, custom-date inclusion/normalization, response cursor
  retention, and both saved-search visible-query routes.
- Review preservation: `/tmp/recovery-task6-review-preservation.log` passed
  34/34 across `GatewayOAuthExchangeTests`, `DraftSyncTranslationTests`,
  `ComposerChipsStripTests`, and `FABQuickActionTests`.
- Review build: `/tmp/recovery-task6-review-build.log` completed with
  `** BUILD SUCCEEDED **` for the iOS simulator.
- Final review feedback-loop RED: `/tmp/recovery-task6-final-review-red.log`
  failed on the missing query-update gate. The follow-up gate ignores only an
  identical query echo while the model search is already committed; a distinct
  user edit and all uncommitted typing still flow through normal typeahead and
  reset behavior. Both saved-search routes retain their committed state, so
  subsequent sort/filter changes continue to schedule full searches.
- Final review focused GREEN: `/tmp/recovery-task6-final-review-green.log`
  passed 21/21 search model and wiring tests.
- Final review preservation: `/tmp/recovery-task6-final-review-preservation.log`
  passed 34/34 OAuth, draft-sync, composer-chip, and FAB regressions.
- Final review build: `/tmp/recovery-task6-final-review-build.log` completed
  with `** BUILD SUCCEEDED **` for the iOS simulator.

### Task 7: Recover Repost and Per-Feed Cache Correctness

**Files:**
- Modify: `Catbird/App/CatbirdApp.swift`
- Modify: `Catbird/Core/Services/BackgroundCacheRefreshManager.swift`
- Modify: `Catbird/Features/Feed/Models/CachedFeedViewPost.swift`
- Modify: `Catbird/Features/Feed/Views/Post/EnhancedFeedPost.swift`
- Test: `CatbirdTests/CachedFeedViewPostIdentityTests.swift`

**Interfaces:**
- Produces: stable cache identity that distinguishes organic/repost variants and feed membership without changing current repost-menu behavior

- [x] **Step 1: Restore and run the four identity regressions**

Tests must prove repost differs from organic, repost identity is stable, a profile repost cannot clobber the timeline organic row, and the same organic post can coexist in two feeds.

- [x] **Step 2: Reconcile `68043cb` narrowly**

Implement the identity/key behavior and header containment only. Before committing, verify `jj diff` contains no repost-menu action or menu-layout change.

- [ ] **Step 3: Test, build, and visually verify**

Run `CachedFeedViewPostIdentityTests`, build, browse two feeds containing the same post/repost, refresh, relaunch, and confirm headers never bleed between rows or feeds.

- [x] **Step 4: Update ledger and commit**

```bash
jj describe -m 'Catbird: recover repost-aware feed cache identity'
jj new
```

#### Task 7 recovery evidence (2026-07-14)

- Archaeology: `68043cb` was read from the original Catbird repository without
  importing the commit. Only repost-aware entry identity, composite
  `(feedType, id)` uniqueness, feed-scoped upserts, direct cached identity use,
  and the cache schema reset were reconciled. Historical formatting and menu UI
  changes were excluded.
- TDD RED: the four restored behavioral tests initially failed for organic vs.
  repost identity, cross-feed repost clobbering, and same-post coexistence; the
  stable repost case already passed. After current-state audit found later
  thread and notification upserts still matching global id only, their two new
  source contracts were added while the fixes were absent; direct contract
  evaluation returned exit 1. The corresponding Xcode RED build was bounded
  during an unexpected full dependency rebuild before test execution.
- TDD GREEN: the final focused run printed 6/6 passing tests and the suite
  result `CachedFeedViewPost identity passed after 0.091 seconds`. This includes
  the four SwiftData identity/containment cases plus source contracts for both
  current-state upsert sites. Xcode was bounded after the results printed during
  its known post-result hang, so the process exit was 143 rather than a normal
  test-run exit.
- Preservation: `ActionButtonsRepostPresentationTests` and
  `NotificationsRepostIconPresentationTests` passed 2/2 via
  `test-without-building`; result bundle:
  `Test-Catbird-2026.07.14_03-57-50--0400.xcresult`. The repost action remains a
  `Menu`, and no action or menu-layout file appears in `jj diff`.
- Build/runtime: the focused test run completed compilation and linking before
  executing all six tests. The resulting app installed and launched on
  simulator `40111BBE-8709-40D0-9016-A27448486A80` as process 6074; startup
  initialized the version-5 ModelContainer successfully. The version bump
  resets only regenerable feed cache rows whose old uniqueness contract is
  incompatible.
- Justified scope expansion: `ThreadManager.swift` and
  `NotificationManager.swift` are included because they were added or changed
  after `68043cb` and still performed global-id upserts. Leaving either site
  unchanged would reintroduce cross-feed row mutation despite the recovered
  composite uniqueness contract. Both are covered by explicit regressions.
- Open runtime gate: manually browsing two feeds containing the same organic
  post/repost, refreshing, relaunching, and visually checking header isolation
  remains unobserved. Build, real SwiftData persistence tests, authenticated
  launch, and menu/icon preservation are green, but they do not close this
  interactive visual check; Step 3 therefore remains unchecked.

#### Task 7 critical/important review follow-up (2026-07-14)

- Critical store-safety correction: the version-5 composite uniqueness change
  and schema-reset path were removed. `CachedFeedViewPost` retains the deployed
  v4 global unique `id` attribute, while newly generated IDs encode feed scope.
  This avoids quarantining the shared SwiftData store that also owns drafts,
  settings, backups, and repository data.
- Targeted cache transition: old global-ID cache rows remain readable. On the
  next primary save for a feed, `PersistentFeedStateManager` removes only that
  feed's stale rows and inserts feed-encoded rows; non-cache entities are never
  copied, deleted, or recreated.
- Real on-disk preservation GREEN: a full production-v4 schema store containing
  one legacy cache row plus representative `DraftPost`, `AppSettingsModel`,
  `BackupRecord`, and `RepositoryRecord` data reopened through the production
  store factory. After the real primary feed save replaced only the legacy
  timeline row, fresh fetches preserved the exact non-cache IDs and values.
  `CachedFeedStoreMigrationTests` passed 2/2, exit 0; result bundle
  `Test-Catbird-2026.07.14_04-24-12--0400.xcresult`.
- Important upsert correction: the primary save path fetches by
  `(feedType, id)`, and `CachedFeedViewPost.update(from:)` refuses cross-feed
  sources. Behavioral coverage proves the same post coexists in timeline and
  profile feeds through this primary path. Background, thread, and notification
  live upserts were re-audited and remain feed-scoped.
- Final focused GREEN: identity, containment, primary-path, upsert contracts,
  and migration passed 12/12, exit 0; result bundle
  `Test-Catbird-2026.07.14_04-25-40--0400.xcresult`.
- Preservation GREEN: repost menu/icon and draft-sync suites passed 19/19,
  exit 0; result bundle `Test-Catbird-2026.07.14_04-26-10--0400.xcresult`.
- Final thread-cache lookup correction: scoped cache IDs begin with the encoded
  feed scope, so `ThreadManager.hasCachedThread` now builds the same
  `entryIdPrefix(for:feedType:)` used by cache insertion instead of searching
  for the URI at byte zero. The focused suite includes both collision behavior
  and source contracts for the lookup and upsert paths. A fresh verification
  attempt was infrastructure-blocked by a concurrent DerivedData lock, then a
  separate warmed cache was interrupted during dependency compilation; the
  existing 12/12 focused, 19/19 preservation, and build evidence remains valid
  for the preceding commit, while this final lookup delta is source-contract
  covered and pending the final cross-platform Task 12 rerun.
- Final iOS simulator build exited 0 with `** BUILD SUCCEEDED **`. The manual
  two-feed browse/refresh/relaunch header check is still open; Step 3 remains
  unchecked.

### Task 8: Reconcile Chat Actions and MLS Display Ordering

**Files:**
- Modify: files listed by `git diff-tree -r d5eefcd` and `git diff-tree -r d06e076`
- Test: `CatbirdTests/MLSPendingSendTests.swift`
- Test: `CatbirdTests/MLSMessageDisplayOrderTests.swift`
- Test: `CatbirdTests/UnifiedChatRenderSignatureTests.swift`

**Interfaces:**
- Produces: own-message capability metadata, edit/unsend actions routed through `MLSConversationDataSource`, and `MLSMessageAdapter.sortedForDisplay(_:)` with timestamp anchoring for delivered sequence-zero rows

- [x] **Step 1: Run current ordering and pending-send tests**

Determine whether newer `main` already supersedes `d06e076`. Keep current ordering if it passes the six historical display-order cases, including all input permutations.

- [x] **Step 2: Add failing edit/unsend capability tests before UI wiring**

Use a test adapter whose current-user message reports editable/unsendable and whose remote message reports neither. Assert action dispatch targets the exact message ID and that a successful unsend removes or tombstones the row according to the current data-source contract.

- [x] **Step 3: Reconcile UI and data source**

Port `d5eefcd` through the protocol, adapter, data source, bubble, bridge, controller, and UIKit MLS composer. Never expose edit/unsend for another sender. Preserve current read cursors, epochs, and sequence persistence.

- [ ] **Step 4: Test and verify**

Run all three focused suites, build, then use two accounts to edit and unsend an own message while confirming the peer observes the update and neither account shows ordering jumps.

- [x] **Step 5: Update ledger and commit**

```bash
jj describe -m 'Catbird: reconcile own-message actions and MLS ordering'
jj new
```

#### Task 8 recovery evidence (2026-07-14)

- Archaeology: `d5eefcd` and `d06e076` were read from the original Catbird
  repository without importing either commit. Current pending-send identity,
  read-cutoff, recovery-state, epoch, and globally monotonic sequence behavior
  were retained. The historical edit/unsend UI and delivered-sequence-zero
  timeline anchoring were reconciled onto those newer contracts.
- Baseline: the active `MLSPendingSendTests` and
  `UnifiedChatRenderSignatureTests` passed 14/14. The dedicated six-case
  `MLSMessageDisplayOrderTests` file was absent from the recovery tree and was
  not enumerated, proving that current coverage did not supersede `d06e076`.
- TDD RED: after restoring the six ordering cases and adding action tests, the
  focused build failed only for the missing `canEdit`, `canUnsend`,
  `sortedForDisplay`, `MLSMessageActionPerformer`, and action-performer init
  seam. A separate render-signature cycle passed the six existing cases and
  failed the new edit-metadata signature assertion before its minimal fix.
- TDD GREEN: all three live focused suites passed 25/25, exit 0, with
  `** TEST SUCCEEDED **`: 12 pending/action cases, six display-order cases
  (including every five-message input permutation), and seven render-signature
  cases. Exact resolved server message IDs dispatch for edit and unsend; remote
  rows dispatch neither; successful unsend immediately removes the row, matching
  the current tombstone-filtered observation contract.
- Preservation: `MLSSendBlockingTests` passed 6/6 and
  `MLSBlockCoordinatorTests` passed 4/4 via `test-without-building`, exit 0.
  Three older requested preservation files are explicitly excluded from the
  active CatbirdTests target, so their zero-test run is not claimed as evidence.
- Review follow-up: acknowledged pending rows temporarily use `.sent` before
  their confirmed GRDB twin arrives. The regression and production guard deny
  server actions to every `pending:` identity during that handoff, and the
  final focused run executed that case successfully.
- Review follow-up: live-message reads now share one
  `MLSDisplayableMessageQuery` for initial fetch, GRDB observation, and refresh.
  It filters `payloadExpired == false` and `isTombstone == 0`; pagination keeps
  using the storage helper with the same tombstone exclusion. Successful unsend
  still removes immediately. A real `DatabasePool` regression observed the
  initial ordered rows, the tombstone-driven removal, and a later mutation of
  the excluded row without reinsertion or an ordering jump.
- Review follow-up: `editMessage` reports success or failure, and the UIKit
  edit session clears only on success. The session owns the current draft,
  records the attempted text synchronously before dispatch, and supplies that
  draft back to the SwiftUI-to-UIKit bridge. A failed edit therefore preserves
  the attempted retry text even when the original message text differs; success
  and cancel clear both target and draft. Strict TDD first failed only for the
  missing draft-state API, then all 15 pending/action cases passed, exit 0, in
  `/tmp/recovery-task8-draft-green-2.log`.
- Final focused verification: four suites passed 29/29, exit 0, with
  `** TEST SUCCEEDED **`: 15 pending/action/edit-session cases, one live GRDB
  observation case, six display-order cases, and seven render-signature cases.
  The earlier package-graph/result-bundle hang was terminated and preserved at
  `/tmp/recovery-task8-review-green.log`; the conclusive run used the known-good
  isolated `/tmp/CatbirdThreadReplyDerivedData` cache.
- Build/runtime: the final focused run compiled and linked the complete app.
  That exact product installed on simulator
  `40111BBE-8709-40D0-9016-A27448486A80` and launched as PID 9911.
- Open runtime gate: real two-account edit, unsend, peer propagation, and
  no-ordering-jump verification was not observed. Step 4 remains unchecked;
  automated ownership, dispatch, removal, ordering, preservation, build, and
  authenticated-launch evidence does not substitute for that interaction.

### Task 9: Audit Settings for Runtime Effects

#### `10f1c17` control/storage/consumer audit

The historical commit touches 32 files. Current storage and controls already exist for all
11 persisted values; the table records every historical file/hunk and limits recovery to
missing runtime consumers. "Exclude" means the hunk is unrelated cosmetic, account/OAuth,
dead-property, or separately tracked secondary work rather than evidence that the control
is wired.

| Historical file | Control / storage | Current runtime consumer | Disposition |
| --- | --- | --- | --- |
| `Core/Extensions/AttributedString+AccentText.swift` | `highlightLinks`, `linkStyle` / `AppSettingsModel` | post facet link attributes | Recover with disabled/color/underline/both plus safe invalid fallback. |
| `Core/State/AppState.swift` | `mlsMessageRetentionDays` / `AppSettingsModel` | MLS policy initialization and startup cleanup | Recover onto current MLS initialization lifecycle. |
| `Core/UI/Drag/BigDefaultButtonDropDelegate.swift` | `disableHaptics` / `AppSettingsModel` | centralized drag feedback | Recover direct UIKit bypass through `PlatformHaptics`. |
| `Core/UI/Drag/DefaultFeedDropDelegate.swift` | `disableHaptics` / `AppSettingsModel` | centralized drag feedback | Recover direct UIKit bypass through `PlatformHaptics`. |
| `Core/UI/Drag/FeedDropDelegate.swift` | `disableHaptics` / `AppSettingsModel` | centralized drag feedback | Recover direct UIKit bypass through `PlatformHaptics`. |
| `Core/Utilities/PlatformHaptics.swift` | `disableHaptics` / `AppSettingsModel` | all emitting entry points | Recover one testable centralized enable policy. |
| `Features/Auth/Views/LoginView.swift` | `disableHaptics` / `AppSettingsModel` | centralized login feedback | Recover direct UIKit bypass through `PlatformHaptics`. |
| `Features/Chat/Views/ConversationView.swift` | `disableHaptics` / `AppSettingsModel` | centralized message feedback | Recover direct UIKit bypass through `PlatformHaptics`. |
| `Features/Feed/Services/ThreadManager.swift` | `threadSortOrder` / `AppSettingsModel` | both `getPostThreadV2.sort` calls | Recover via `ThreadSortAPIMapper`; invalid values safely use `oldest`. |
| `Features/Feed/Views/Components/ActionButtons/ActionButtonsView.swift` | `disableHaptics` / `AppSettingsModel` | centralized post-action feedback | Recover direct UIKit bypass through `PlatformHaptics`. |
| `Features/Feed/Views/Components/PostComposer/PostComposerCore.swift` | `requireAltText` / `AppSettingsModel` | composer submit validation | Recover missing-alt-text validation. |
| `Features/Feed/Views/Components/PostComposer/PostComposerModels.swift` | `requireAltText` / `AppSettingsModel` | `PostComposerSubmitValidationState.missingAltText` | Recover validation state without changing composer ownership. |
| `Features/Feed/Views/FeedDiscoveryHeaderView.swift` | `disableHaptics` / `AppSettingsModel` | centralized discovery feedback | Recover direct UIKit bypass through `PlatformHaptics`. |
| `Features/Feed/Views/FeedsLaunchpad/FeedsLaunchpadEdgeFlip.swift` | `disableHaptics` / `AppSettingsModel` | centralized edge-flip feedback | Recover direct UIKit bypass through `PlatformHaptics`. |
| `Features/Feed/Views/FeedsStartPage.swift` | `disableHaptics` / `AppSettingsModel` | centralized launchpad feedback | Recover direct UIKit bypasses; exclude icon/cosmetic hunks. |
| `Features/Feed/Views/Post.swift` | `showLanguageIndicators`, `highlightLinks`, `linkStyle`, `disableHaptics` / `AppSettingsModel` | declared-language chips, styled post text, centralized feedback | Recover only those consumers. |
| `Features/Feed/Views/PostView.swift` | `showReadingTimeEstimates`, `confirmBeforeActions` / `AppSettingsModel` | post metadata and mute user/thread confirmation | Recover using pure reading-time and confirmation predicates. |
| `Features/Feed/Views/ViewImageGridView.swift` | `largerAltTextBadges` / `AppSettingsModel` | feed-image ALT badges and preview badge | Recover badge presence and size on image grid/preview paths. |
| `Features/MLSChat/MLSConversationDetailView.swift` | `disableHaptics` / `AppSettingsModel` | centralized message-action feedback | Recover Task-8-current direct UIKit bypasses only. |
| `Features/Profile/Views/Unified/ProfileHeader.swift` | `loggedOutVisibility`, `confirmBeforeActions` / `AppSettingsModel` | self-label source-of-truth reconciliation and mute/unfollow confirmation | Recover while preserving profile fields and unrelated labels. |
| `Features/Settings/Models/AppSettingsModel.swift` | all 11 values | account-scoped persisted storage | Keep current storage; exclude historical dead-property cleanup. |
| `Features/Settings/Views/AccessibilitySettingsView.swift` | accessibility controls / `AppSettingsModel` | consumers listed above | Keep current controls; exclude cosmetic copy/layout churn. |
| `Features/Settings/Views/AccountSettingsHelpers.swift` | none of the 11 | none | Exclude OAuth/account-action deletion. |
| `Features/Settings/Views/AccountSettingsView.swift` | none of the 11 | none | Exclude OAuth/account-action deletion and broad cleanup. |
| `Features/Settings/Views/AppSettings.swift` | `disableHaptics` / `AppSettingsModel` | centralized `PlatformHaptics` policy | Recover startup, account-switch, and setter synchronization. |
| `Features/Settings/Views/ContentMediaSettingsView.swift` | `threadSortOrder`, `showLanguageIndicators` / `AppSettingsModel` | consumers listed above | Keep current controls; exclude picker/cosmetic churn. |
| `Features/Settings/Views/DataBackupSettingsView.swift` | none of the 11 | none | Exclude secondary backup-progress bug. |
| `Features/Settings/Views/MLSChatSettingsView.swift` | `mlsMessageRetentionDays` / `AppSettingsModel` | MLS initialization policy | Keep current control; exclude zero-day picker semantics. |
| `Features/Settings/Views/ModerationSettingsView.swift` | none of the 11 | none | Exclude moderation lookup/dead-code cleanup. |
| `Features/Settings/Views/PrivacySecuritySettingsView.swift` | `loggedOutVisibility`, `mlsMessageRetentionDays` / `AppSettingsModel` | self-label record write and MLS lifecycle | Recover logged-out visibility only here; exclude broad view rewrite. |
| `Features/Settings/Views/SettingsView.swift` | none of the 11 | none | Exclude credential/account cleanup and cosmetic rows. |
| `Features/Settings/Views/SideDrawer.swift` | `disableHaptics` / `AppSettingsModel` | centralized drawer feedback | Recover direct UIKit bypass through `PlatformHaptics`. |

**Files:**
- Audit: every file from `git diff-tree --no-commit-id --name-status -r 10f1c17`
- Modify: only settings views/models and current runtime consumers with absent behavior
- Test: create `CatbirdTests/SettingsRuntimeWiringTests.swift` if no existing focused test covers a recovered setting

**Interfaces:**
- Produces: a one-to-one mapping from each visible control to persisted state and an observable runtime consumer

- [x] **Step 1: Build a setting-to-consumer table in the ledger**

For each `10f1c17` hunk, record control label, storage property, runtime consumer, and disposition. Audit these concrete mappings: `requireAltText` to composer submit validation; `highlightLinks` and `linkStyle` to attributed post links; `confirmBeforeActions` to mute/unfollow confirmation; `showReadingTimeEstimates` to post metadata; `showLanguageIndicators` to declared-language chips; `disableHaptics` to every `PlatformHaptics` entry point; `loggedOutVisibility` to the self-label record write; `threadSortOrder` to `getPostThreadV2.sort`; `largerAltTextBadges` to image-grid ALT badges; and `mlsMessageRetentionDays` to retention-policy startup sync. Exclude cosmetic churn, broad `AppState` replacements, the OAuth-blocked account actions removed by the historical commit, and any setting already wired differently on current `main`.

- [x] **Step 2: Test the concrete pure mappings first**

Extract only pure calculations that need coverage and add these assertions:

```swift
@Test("Thread sort values map to supported API values")
func threadSortMapping() {
  #expect(ThreadSortAPIMapper.apiValue(for: "hot") == "top")
  #expect(ThreadSortAPIMapper.apiValue(for: "top") == "top")
  #expect(ThreadSortAPIMapper.apiValue(for: "newest") == "newest")
  #expect(ThreadSortAPIMapper.apiValue(for: "oldest") == "oldest")
  #expect(ThreadSortAPIMapper.apiValue(for: "invalid") == "oldest")
}

@Test("Reading-time estimates start at one hundred words")
func readingTimeThreshold() {
  #expect(PostReadingTime.minutes(forWordCount: 99) == nil)
  #expect(PostReadingTime.minutes(forWordCount: 100) == 1)
  #expect(PostReadingTime.minutes(forWordCount: 201) == 2)
}
```

Add `ThreadSortAPIMapper` beside `ThreadManager` and `PostReadingTime` beside `PostView` only if the corresponding current behavior is missing or untested. Extend the existing composer validation test with `.missingAltText` expectations if `requireAltText` needs recovery. Do not create abstractions for mappings already covered by current tests.

- [ ] **Step 3: Wire accepted settings and verify manually**

Implement only table rows with a proven missing consumer. Relaunch after toggling each recovered persistent setting and verify the affected feed, media, moderation, accessibility, privacy, or chat behavior changes.

- [x] **Step 4: Test, update ledger, and commit**

```bash
xcodebuild test -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,id=40111BBE-8709-40D0-9016-A27448486A80' \
  -only-testing:CatbirdTests/SettingsRuntimeWiringTests
jj describe -m 'Catbird: recover missing settings runtime wiring'
jj new
```

If every historical setting is already present or superseded, commit only the evidence-bearing ledger update with message `Catbird: audit recovered settings wiring`.

#### Task 9 recovery evidence (2026-07-14)

- Archaeology/control audit: all 32 files touched by historical `10f1c17` are
  represented in the table above. Current account-scoped storage and controls
  were retained; only the 11 accepted missing runtime mappings were recovered.
  Backup progress, zero-day MLS picker semantics, moderation lookup, OAuth and
  account cleanup, dead-property cleanup, cosmetic churn, and broad `AppState`
  replacement remain excluded.
- TDD RED: the initial focused suite failed on the absent thread-sort,
  reading-time, link-style, language-indicator, ALT-badge, confirmation,
  haptic, and self-label symbols. A second behavioral composer RED failed on
  the deliberately absent `PostComposerAltTextRequirement` at all three call
  sites in `SettingsRuntimeWiringTests`; that build was bounded after the exact
  compiler failures were captured.
- Focused GREEN: the final fresh run passed 8/8, exit 0, with
  `** TEST SUCCEEDED **`; result bundle
  `Test-Catbird-2026.07.14_06-46-04--0400.xcresult`. It covers the composer
  predicate against complete image/video alt text, blank image alt text, and
  blank video alt text.
- Preservation GREEN: settings plus the Task 8 MLS pending-send, observation,
  display-order, render-signature, send-blocking, and block-coordinator suites
  passed 47/47 via `test-without-building`, exit 0; result bundle
  `Test-Catbird-2026.07.14_06-43-51--0400.xcresult`.
- Consumer audit: composer validation, attributed link rendering, mute/unfollow
  confirmations, reading metadata, language chips, all `PlatformHaptics` entry
  points and every historical direct-generator bypass, profile self-label
  reconciliation, both thread API calls, image-grid ALT badges, and MLS startup
  policy/cleanup each read their persisted setting. Haptic state is synchronized
  by the setting setter and by account-scoped `AppSettings.initialize`, which is
  invoked on preferences initialization/account reload.
- Safety: logged-out visibility reads the live profile record, preserves every
  current profile field and unrelated self-label, uses `swapRecord`, rejects
  unknown label unions, and restores the local control on failed writes.
- Build/runtime: the final focused test performed a fresh product/test build and
  exited 0. That exact app installed and launched on simulator
  `40111BBE-8709-40D0-9016-A27448486A80` as process 40507.
- Open manual gate: toggling all 11 settings, relaunching, and observing each
  affected screen/action remains an interactive simulator/device check. The
  automated mapping tests and launch evidence do not close it, so Step 3 stays
  unchecked.

#### Task 9 review follow-up evidence (2026-07-14)

- Retention P1: the ineffective core-owned automatic-cleanup call was replaced
  at the app layer by an actor-isolated coordinator. It scans the active user's
  persisted MLS conversations immediately, invokes the existing effective
  `cleanupConversation` path for each current epoch, and then waits for the
  current policy interval. Settings changes update the policy and replace the
  worker; account switching explicitly stops it. Restart generations await all
  retiring workers, so concurrent restart/stop calls cannot leave overlapping
  or untracked cleanup loops.
- Privacy rollback: logged-out visibility now marks programmatic load/rollback
  targets and consumes that mark in `onChange`. A failed network write therefore
  produces one rollback and one alert without issuing the inverse write.
- Link attributes and composer copy: every linked run, including ordinary web,
  `mention://`, and `tag://` destinations, first clears Petrel's foreground and
  underline attributes before applying the selected style. Required-alt-text
  copy now refers neutrally to every media attachment rather than images only.
- TDD RED: `/tmp/recovery-task9-review-red.log` exited 65 with the expected
  missing `LoggedOutVisibilityChangeGate` and
  `MLSEpochRetentionCleanupCoordinator` production symbols. The async probe was
  then simplified to use cancellation of a long injected sleep, with no elapsed
  time dependency. A later first execution exposed only an invalid test URL
  fixture (`mention://did:plc:example` parsed `plc` as a port); the corrected
  valid `mention://did.example` fixture required no production change.
- Focused GREEN: the final `test-without-building` execution passed 11/11 in one
  suite and emitted `** TEST EXECUTE SUCCEEDED **`. Log:
  `/tmp/recovery-task9-review-focused-final.log`; result bundle:
  `/tmp/CatbirdTask9RedDerivedData/Logs/Test/Test-Catbird-2026.07.14_07-14-40--0400.xcresult`.
- Preservation GREEN: settings plus the six preserved Task 8 MLS/chat suites
  passed 51/51 in seven suites and emitted `** TEST EXECUTE SUCCEEDED **`. Log:
  `/tmp/recovery-task9-review-preservation-final.log`; result bundle:
  `/tmp/CatbirdTask9RedDerivedData/Logs/Test/Test-Catbird-2026.07.14_07-15-07--0400.xcresult`.
- Build/runtime: the final product/test bundle emitted
  `** TEST BUILD SUCCEEDED **` in
  `/tmp/recovery-task9-review-build-fixture.log`. That exact app installed and
  launched on clean iOS 26.2 simulator
  `CEC8381E-065C-468C-ACED-6A9DC716987B` as `blue.catbird` process 62845.
- Scope safety: no `CatbirdMLSCore` source was edited or committed by this
  follow-up. Its pre-existing concurrent change to
  `MLSConversationManager.swift` remains outside the recovery workspace change.
  The interactive toggle/relaunch gate above remains open.

#### Task 9 lifecycle-gap closure evidence (2026-07-14)

- Old-state shutdown: `AppState.prepareMLSStorageReset()` now awaits the
  app-layer retention coordinator's `stop()` immediately after cancelling MLS
  initialization. This is the shared old-state teardown already used by account
  switching, explicit account removal/storage reset, and now logout, so cleanup
  cannot continue scanning a closing old-account database.
- Logout ordering: `AppStateManager.logout` captures the current cached
  `AppState` and awaits `prepareMLSStorageReset()` before clearing the auth
  session or changing lifecycle state. The switch path continues to await that
  same shared teardown before database closure.
- Privacy initial seed: the cached `loggedOutVisibility` seed in the view task
  now uses `setLoggedOutVisibilityProgrammatically`, matching server load and
  failed-write rollback. The next `onChange` consumes the suppression target,
  while a subsequent user toggle still produces exactly one write.
- TDD RED: the source-backed focused run proved all three gaps before product
  edits: the cached seed directly assigned state, the shared storage reset did
  not contain the awaited coordinator stop, and logout did not await the current
  state's reset. Log: `/tmp/recovery-task9-lifecycle-red-test.log`.
- Focused GREEN: the final settings execution passed 12/12 in one suite and
  emitted `** TEST EXECUTE SUCCEEDED **`. Log:
  `/tmp/recovery-task9-lifecycle-green-focused.log`; result bundle:
  `/tmp/CatbirdTask9RedDerivedData/Logs/Test/Test-Catbird-2026.07.14_07-26-47--0400.xcresult`.
- Preservation GREEN: settings plus the six Task 8 MLS/chat suites passed 52/52
  in seven suites and emitted `** TEST EXECUTE SUCCEEDED **`. Log:
  `/tmp/recovery-task9-lifecycle-preservation.log`; result bundle:
  `/tmp/CatbirdTask9RedDerivedData/Logs/Test/Test-Catbird-2026.07.14_07-27-15--0400.xcresult`.
- Build/runtime: the final product/test bundle emitted
  `** TEST BUILD SUCCEEDED **` in
  `/tmp/recovery-task9-lifecycle-green-build.log`. That exact app installed and
  launched on clean iOS 26.2 simulator
  `CEC8381E-065C-468C-ACED-6A9DC716987B` as `blue.catbird` process 15022.
- Scope safety: this follow-up is based on Task 10's sealed ledger commit
  `7325dcd2` and does not alter its Task 10 section. No `CatbirdMLSCore` source
  was edited; its external dirty `MLSConversationManager.swift` remains outside
  this recovery commit.

### Task 10: Reconcile Threaded Replies with Current Main

**Files:**
- Modify only if evidence requires: `Catbird/Features/Feed/Views/PostView.swift`
- Modify only if evidence requires: `Catbird/Features/Feed/Views/Thread/UIKitThreadView.swift`
- Test: `CatbirdTests/ThreadReplyLayoutTests.swift`
- Exclude: account/settings cleanup from `b86c5ca`

**Interfaces:**
- Produces: sibling replies do not connect to one another, direct children retain connectors, omitted children retain continuation affordance

- [x] **Step 1: Run the current sibling-reply regression suite**

```bash
xcodebuild test -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,id=40111BBE-8709-40D0-9016-A27448486A80' \
  -only-testing:CatbirdTests/ThreadReplyLayoutTests
```

- [x] **Step 2: Compare behavior, not whole files**

Diff `b86c5ca` against the current two view files. If current code passes all three tests and exposes the same continuation behavior at runtime, mark `b86c5ca` superseded and make no product-code edit. Otherwise port only the missing connector predicate or continuation affordance.

- [ ] **Step 3: Verify nested, sibling, and omitted reply layouts**

Build and capture thread screenshots for all three arrangements. Confirm no regression to scroll position, initial reveal animation, or App Entity annotations.

- [x] **Step 4: Update ledger and commit**

```bash
jj describe -m 'Catbird: reconcile threaded reply layout'
jj new
```

#### Task 10 recovery evidence (2026-07-14)

- Source disposition: the audited layout files at recovery parent `33ff4233`
  match the reviewed state exactly. Historical `b86c5ca` used positional
  assumptions and an optional Option B mode that removed all connector rails in
  favor of 48/32/24-point avatars and indentation. Restoring it literally would
  violate this task's requirement that direct children retain connectors.
  Current `ThreadReplyLayoutBuilder` instead derives the root and child rails
  from actual parent URIs and derives continuation from either `moreReplies` or
  an omitted direct child. `ReplyView` consumes those exact values for the root
  rail, each visible child rail, and the `Continue thread` button. Therefore
  `b86c5ca` is superseded for this task and neither `PostView.swift` nor
  `UIKitThreadView.swift` was edited.
- Focused GREEN: a fresh `test-without-building` execution on clean iOS 26.2
  simulator `CEC8381E-065C-468C-ACED-6A9DC716987B`, with parallel testing
  disabled and one maximum worker, passed 3/3 in the single
  `ThreadReplyLayoutTests` suite and emitted `** TEST EXECUTE SUCCEEDED **`.
  Log: `/tmp/recovery-task10-thread-layout.log`; result bundle:
  `/tmp/CatbirdTask9RedDerivedData/Logs/Test/Test-Catbird-2026.07.14_07-17-41--0400.xcresult`.
- Build/runtime: the suite reused the exact product/test build already verified
  at the Task 9 parent rather than competing with another active Xcode build.
  That same `Catbird.app` was then installed and launched outside the test host
  on the clean simulator as `blue.catbird` process 72781.
- Scroll/reveal preservation: Task 10 made no product edit. The existing initial
  snapshot, non-animated main-post positioning, delayed drift correction, and
  post-stabilization reveal paths remain unchanged. Screenshot verification of
  nested, sibling, and omitted-child fixtures remains open because those
  semantic fixtures are not navigable from the simulator's unauthenticated
  state; Step 3 intentionally remains unchecked.
- Settings carry-forward at the Task 10 checkpoint: `ContentMediaSettingsView`
  exposed a `Threaded Replies View` toggle and persisted `threadedReplies`, but
  runtime code had no consumer. During Task 12 the product owner explicitly
  identified the compact avatar/indentation behavior as required. The final
  audit therefore restores that presentation layer while retaining Task 10's
  URI-based connector predicates instead of historical Option B's blanket
  all-rails-off behavior.
- App Entity carry-forward: parent thread cells currently assign a responder
  `appEntityIdentifier`, while main-post and reply cells only clear identifiers
  on reuse and `PostView` seeds the entity stores without adding a SwiftUI
  entity context. Task 11 must reconcile that responder-level annotation
  coverage from canonical App Intents sources; Task 10 did not change it.

### Task 11: Reconcile App Intents from Canonical Sources

**Files:**
- Audit: `Catbird/AppIntents/**`
- Create or reconcile: `manifests/app-intents.json`
- Create or reconcile: `Catbird/AppIntents/README.md`
- Test: `CatbirdUITests/AppIntentsSiriPathTests.swift`
- Test: `CatbirdTests/AppIntents/GeneratedIntentsTests.swift`
- Preserve: current OAuth/security implementation in `AuthManager.swift` and intent client resolution

**Interfaces:**
- Produces: approved shortcut set within the ten-shortcut cap, Messages draft handoff, supported record-write intents, reliable entity discovery/donation, and current secure client resolution

- [x] **Step 1: Freeze all generator inputs before generation**

```bash
jj status
jj new
```

Expected: clean checkpoint before any generator command.

- [x] **Step 2: Create a manifest-to-runtime audit table**

For each candidate commit from `67d8872` through `641531a`, record: user-visible intent, canonical manifest/schema entry, handwritten runtime implementation, generated artifact, shortcut inclusion, current disposition, and test coverage. Explicitly reconcile the 10-shortcut cap and exclude duplicate handwritten/generated Like/Repost implementations.

Include a thread-cell annotation row: verify canonical onscreen-entity behavior
for parent, main-post, and reply `UICollectionViewCell` responders. The current
state assigns `appEntityIdentifier` only for parent cells; main-post and reply
cells clear the property on reuse but do not assign it during configuration.
Reconcile this deliberately rather than treating Task 10's no-op as proof of
complete App Entity coverage.

- [x] **Step 3: Restore the canonical manifest, change inputs, and regenerate**

Start from `b8c552c:manifests/app-intents.json` and `8881885:Catbird/AppIntents/README.md`, then reconcile their declared intents with the completed audit table. Checkpoint both repositories and run the documented generator exactly:

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel/Petrel
jj status
jj new
python3 run.py \
  --manifest ../Catbird-recovery/manifests/app-intents.json swift
```

After generation:

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel/Catbird-recovery
jj diff --stat
rg -n '^(<<<<<<<|=======|>>>>>>>)' Catbird/AppIntents CatbirdUITests
```

Expected: only intended App Intents output and handwritten runtime/test changes, with no conflict markers. If output is broad or lands in the wrong path, use `jj op undo`, fix the generator input, and rerun.

- [ ] **Step 4: Test metadata and runtime paths**

Build first to validate App Intents metadata extraction. Run `AppIntentsSiriPathTests` on a physical iPhone, then exercise shortcut phrases, Compose Post, chat draft handoff, Like/Repost or their generated equivalents, onscreen post/profile entities, and locked-device behavior. Preserve current secure account/client resolution.

- [x] **Step 5: Update ledger and commit**

```bash
jj describe -m 'Catbird: reconcile App Intents recovery surface'
jj new
```

#### Task 11 recovery evidence (2026-07-14)

- Commit `116cdf7e` restores the canonical manifest and generated surface,
  reconciles the ten-shortcut cap, removes duplicate handwritten Like/Repost
  implementations, restores Messages draft handoff and direct-message intents,
  and wires post/profile entity discovery into the visible runtime surfaces.
- The generated and handwritten intent suites are included in the final 310-test
  iPhone unit run recorded by Task 12. App Intents metadata extraction also
  completes in the final iPad and macOS builds.
- Physical-iPhone Siri phrases, locked-device behavior, Messages schema
  invocation, and onscreen entity lookup remain required before Step 4 can be
  closed; simulator/unit/build evidence does not substitute for that device
  boundary.

### Task 12: Final Cross-Platform Verification and Integration Audit

**Files:**
- Modify: `LOST_WORK_RECOVERY_EXECUTION.md`
- Evidence: `/tmp/catbird-recovery-final/`

**Interfaces:**
- Consumes: all recovered slice commits
- Produces: closed ledger, build/test logs, screenshots, device results, integration-ready branch

- [x] **Step 1: Audit scope and conflict markers**

```bash
jj diff --from bfa9395512daedb6255f97390df47a9333d11bee --stat
jj log -r 'bfa9395512daedb6255f97390df47a9333d11bee..@' \
  -T 'commit_id.short() ++ " " ++ description.first_line() ++ "\n"'
rg -n '^(<<<<<<<|=======|>>>>>>>)' Catbird CatbirdTests CatbirdUITests
jj diff --from bfa9395512daedb6255f97390df47a9333d11bee --git \
  > /tmp/catbird-recovery-final/recovery.patch
git apply --check --whitespace=error-all \
  /tmp/catbird-recovery-final/recovery.patch
```

Expected: only planned files, one clear commit per slice, no conflict markers, and no whitespace errors.

- [x] **Step 2: Run the final automated matrix**

```bash
mkdir -p /tmp/catbird-recovery-final
xcodebuild test -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,id=40111BBE-8709-40D0-9016-A27448486A80' \
  | tee /tmp/catbird-recovery-final/iphone-tests.log
xcodebuild -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,id=56D76971-EC63-4C7C-B2D8-A6D0C3FD07B0' build \
  | tee /tmp/catbird-recovery-final/ipad-build.log
xcodebuild -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=macOS' build \
  | tee /tmp/catbird-recovery-final/macos-build.log
```

Expected: all builds and tests succeed, with any baseline-only failures clearly matched to Task 1 evidence.

- [ ] **Step 3: Run the final visual/device matrix**

Capture evidence for Feed Start, unified profile, composer states, FAB open/closed, drafts, search filters, repeated reposts across feeds, chat edit/unsend, MLS ordering, recovered settings, and threaded replies. On the physical iPhone, repeat photo, video, Siri, App Intents, and entity lookup tests.

For threaded replies, capture sibling, direct-child, and omitted-child layouts
and confirm initial position/reveal behavior. The product owner explicitly
approved restoring compact threaded presentation during this audit. Preserve
the current URI-based connector predicates; do not restore historical Option
B's all-rails-off behavior.

- [x] **Step 4: Close every ledger row**

No row may remain `candidate`. For every exclusion or supersession, include the replacement commit/code path and test or runtime evidence.

- [x] **Step 5: Seal the final audit**

```bash
jj describe -m 'Catbird: record lost-work recovery verification'
jj new
jj status
```

Expected: a clean working copy. Do not move `main`; present the branch and evidence for final review first.

#### Task 12 recovery evidence (2026-07-14)

- Scope audit: `/tmp/catbird-recovery-final/recovery-stat.txt` and
  `recovery-log.txt` record the complete recovery stack from the approved
  baseline. `conflict-markers.txt` is empty. The complete
  `recovery.patch` passes a reverse applicability and whitespace check against
  the recovered tree; reverse mode is used because the jj-only baseline commit
  is not exported as a Git tree object. No ledger disposition remains
  `candidate`.
- Threaded-reply correction: historical `b86c5ca` incorrectly bundled useful
  compact presentation with obsolete blanket connector suppression. The final
  audit restores 48/32/24-point avatars, 0/12/24-point capped indentation, and
  the enabled depth cap of five through `PostView` and
  `ThreadReplyPresentationMetrics`, while retaining URI-derived direct-child,
  sibling, and omitted-child connector rules. Focused RED/GREEN logs are
  `threaded-replies-red.log` and `threaded-replies-green-rerun2.log`; the final
  focused run passes 5 tests in 1 suite.
- Automated iPhone evidence: `iphone-unit-tests-final.log` passes 310 tests in
  55 suites. `iphone-ui-smoke-green.log` passes 5 UI smoke tests. The broader
  `iphone-tests-serial.log` also exposes 13 fixture/manual failures rather than
  concealing them: 11 moderation tests still search for the removed `MLS Chat`
  tab/fixture, and 2 repost-ghost tests explicitly require live feed data and
  physical evidence. Those suites need fixture modernization or their declared
  device environment; they are not product regressions introduced by this
  recovery patch.
- Cross-platform evidence: `ipad-build-final.log` and
  `macos-build-final.log` both end in `** BUILD SUCCEEDED **`. The macOS build
  required guarding the iOS 27 Messages schema files with `#if os(iOS)`, which
  preserves their iPhone behavior without compiling unavailable Messages APIs
  into Catbird for macOS.
- Lifecycle audit: captured-media testing exposed a pre-existing deinit
  resurrection in `FeedFeedbackManager`; removing its escaping best-effort
  `Task` closes that crash without changing interaction submission while the
  manager is alive. RED/GREEN evidence is recorded in
  `captured-media-deinit-red.log` and
  `captured-media-deinit-green-suite.log`.
- Runtime evidence: the signed-in iPhone simulator was used to inspect Feed
  Start, timeline, unified profile, FAB actions, drafts, composer/accessories,
  search filters, and the restored threaded-replies toggle. Thread captures
  `visual-threaded-replies-parent-child.png` and
  `visual-threaded-replies-compact.png` show a regular root, compact children,
  and preserved parent-to-direct-child rail without a false sibling rail.
- Remaining device gate: Step 3 stays open for physical-iPhone photo/video,
  Siri/App Intents, locked-device behavior, entity lookup, live repeated-repost
  evidence, and device-backed chat ordering/edit/unsend checks. The branch is
  integration-ready for code review, but those release gates are not claimed
  complete.
