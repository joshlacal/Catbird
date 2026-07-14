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
| `d062c2a`, `8e2b09d`, `650f738`, `2f3f4cc` | Feed icons and banner geometry | candidate |
| `412bb74` | Draft/AppView sync and drafts sheet | recovered |
| `4e833ba` | Composer chips/accessory redesign | candidate; exclude unrelated auth/chat content |
| `17a4479` through `f7322e3`, plus `08e7368`, `dd7fde8` | FAB and capture actions | candidate; `dd7fde8` cell annotations audited under App Intents |
| `fea6386`, `dfb0b1e`, `19ae89a`, `29ab384`, `8881885` | Honest search filters | candidate |
| `68043cb` | Repost/per-feed cache identity | candidate |
| `d5eefcd`, `d06e076` | Own-message actions and sequence-zero ordering | candidate |
| `10f1c17` | Settings runtime wiring | candidate; file-by-file semantic audit |
| `b86c5ca` | Threaded replies and account cleanup | candidate; compare with current sibling-reply tests |
| `67d8872` through `641531a` | App Intents expansion and runtime hardening | candidate; regenerate, never copy generated files |

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

- [x] **Step 3: Verify selection and sync UI**

Run the tests again, build, launch Drafts, select a local draft, return to the composer, and confirm its text/thread metadata restore. If a test account supports AppView drafts, pull then push a text-only draft and confirm round-trip behavior.

Evidence: all 16 enumerated `DraftSyncTranslationTests` passed on simulator
`40111BBE-8709-40D0-9016-A27448486A80`; the fresh `Catbird` simulator build
exited 0; and the built app installed, launched, and rendered its authenticated
timeline (`/tmp/catbird-task3-launch.png`). Scripted simulator tooling could not
reliably navigate into the Drafts sheet, so local selection/thread restoration
is covered by the focused regression rather than a manual tap-through. No
AppView text-only push/pull was performed because that would mutate the signed-in
account's remote draft state.

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

- [ ] **Step 1: Restore the two focused test files from `4e833ba` and run them**

Tests must cover hidden/visible chip state, threadgate summary text, counter hidden far from the limit, visible at fifty remaining, and custom maximum count.

```bash
xcodebuild test -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,id=40111BBE-8709-40D0-9016-A27448486A80' \
  -only-testing:CatbirdTests/ComposerChipsStripTests \
  -only-testing:CatbirdTests/ComposerCounterDisplayTests
```

Expected: FAIL for every absent historical interface; already-passing cases receive `already present` ledger evidence.

- [ ] **Step 2: Port only the composer-owned portion of `4e833ba`**

Implement `ComposerChipsStrip` and `ComposerAccessoryBar`, then wire them through `PostComposerViewUIKit.swift`, `+Actions`, `+Metadata`, `+Sheets`, and `+Thread`. Exclude `AuthManager`, profile, and chat files from this commit. Preserve current submit validation and media-state synchronization.

- [ ] **Step 3: Test and visually verify**

Run the focused tests plus `PostComposerFixesTests`, build, and capture composer screenshots for empty, language-selected, labels-selected, threadgate-selected, and near-character-limit states.

- [ ] **Step 4: Update ledger and commit**

```bash
jj describe -m 'Catbird: recover composer chips and accessory controls'
jj new
```

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

- [ ] **Step 1: Restore capture ingestion tests and verify failure**

Restore the photo-add and image-limit tests from `51036b1`, then run:

```bash
xcodebuild test -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,id=40111BBE-8709-40D0-9016-A27448486A80' \
  -only-testing:CatbirdTests/CapturedMediaIngestTests
```

Expected: FAIL until captured-media interfaces exist.

- [ ] **Step 2: Add the capture boundary**

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

- [ ] **Step 3: Restore ingestion and the single-orb menu**

Port the ingestion boundary from `51036b1` plus the shared `syncMediaStateToCurrentThread()` call from `670c265`. Reconstruct the FAB chain through `f7322e3`, then apply the single-orb correction from `08e7368`. New Post opens a clean composer; Browse Drafts robustly opens the draft destination; capture actions first stash the current working draft.

- [ ] **Step 4: Verify automated and runtime behavior**

Run capture and composer tests, build, then verify the morph under Reduce Motion on/off and Reduce Transparency on/off. On a physical iPhone, capture one photo and one video, cancel each flow once, and confirm an existing text draft survives all four paths.

- [ ] **Step 5: Update ledger and commit**

```bash
jj describe -m 'Catbird: recover compose FAB quick actions and media capture'
jj new
```

### Task 6: Recover Honest Search Filters

**Files:**
- Create or reconcile: `Catbird/Features/Search/Models/SearchFilterState.swift`
- Modify: `SearchModels.swift`, `RefinedSearchViewModel.swift`, `RefinedSearchView.swift`, `SaveSearchSheet.swift`, `SavedSearchesSection.swift`, `BasicFilterView.swift`
- Create or reconcile: `SearchFilterBar.swift`, `SearchFiltersSheet.swift`
- Remove only if still present: `AdvancedSearchParams.swift`, `AdvancedFilterView.swift`, `SearchSortSelector.swift`
- Test: `CatbirdTests/SearchFilterStateTests.swift`

**Interfaces:**
- Produces: `SearchFilterState` with `.sort`, `.dateRange`, custom bounds, optional language, `activeFilterCount`, `sortValue`, `languageContainer`, and `dateBounds(now:)`

- [ ] **Step 1: Restore the complete focused test suite and run it**

The suite from `8881885` must cover defaults, counts, API sort mapping, fixed/custom bounds, language conversion, Codable round-trip, and legacy saved-search reset.

- [ ] **Step 2: Implement supported parameters only**

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

- [ ] **Step 4: Update ledger and commit**

```bash
jj describe -m 'Catbird: recover supported search filters'
jj new
```

### Task 7: Recover Repost and Per-Feed Cache Correctness

**Files:**
- Modify: `Catbird/App/CatbirdApp.swift`
- Modify: `Catbird/Core/Services/BackgroundCacheRefreshManager.swift`
- Modify: `Catbird/Features/Feed/Models/CachedFeedViewPost.swift`
- Modify: `Catbird/Features/Feed/Views/Post/EnhancedFeedPost.swift`
- Test: `CatbirdTests/CachedFeedViewPostIdentityTests.swift`

**Interfaces:**
- Produces: stable cache identity that distinguishes organic/repost variants and feed membership without changing current repost-menu behavior

- [ ] **Step 1: Restore and run the four identity regressions**

Tests must prove repost differs from organic, repost identity is stable, a profile repost cannot clobber the timeline organic row, and the same organic post can coexist in two feeds.

- [ ] **Step 2: Reconcile `68043cb` narrowly**

Implement the identity/key behavior and header containment only. Before committing, verify `jj diff` contains no repost-menu action or menu-layout change.

- [ ] **Step 3: Test, build, and visually verify**

Run `CachedFeedViewPostIdentityTests`, build, browse two feeds containing the same post/repost, refresh, relaunch, and confirm headers never bleed between rows or feeds.

- [ ] **Step 4: Update ledger and commit**

```bash
jj describe -m 'Catbird: recover repost-aware feed cache identity'
jj new
```

### Task 8: Reconcile Chat Actions and MLS Display Ordering

**Files:**
- Modify: files listed by `git diff-tree -r d5eefcd` and `git diff-tree -r d06e076`
- Test: `CatbirdTests/MLSPendingSendTests.swift`
- Test: `CatbirdTests/MLSMessageDisplayOrderTests.swift`
- Test: `CatbirdTests/UnifiedChatRenderSignatureTests.swift`

**Interfaces:**
- Produces: own-message capability metadata, edit/unsend actions routed through `MLSConversationDataSource`, and `MLSMessageAdapter.sortedForDisplay(_:)` with timestamp anchoring for delivered sequence-zero rows

- [ ] **Step 1: Run current ordering and pending-send tests**

Determine whether newer `main` already supersedes `d06e076`. Keep current ordering if it passes the six historical display-order cases, including all input permutations.

- [ ] **Step 2: Add failing edit/unsend capability tests before UI wiring**

Use a test adapter whose current-user message reports editable/unsendable and whose remote message reports neither. Assert action dispatch targets the exact message ID and that a successful unsend removes or tombstones the row according to the current data-source contract.

- [ ] **Step 3: Reconcile UI and data source**

Port `d5eefcd` through the protocol, adapter, data source, bubble, bridge, controller, and UIKit MLS composer. Never expose edit/unsend for another sender. Preserve current read cursors, epochs, and sequence persistence.

- [ ] **Step 4: Test and verify**

Run all three focused suites, build, then use two accounts to edit and unsend an own message while confirming the peer observes the update and neither account shows ordering jumps.

- [ ] **Step 5: Update ledger and commit**

```bash
jj describe -m 'Catbird: reconcile own-message actions and MLS ordering'
jj new
```

### Task 9: Audit Settings for Runtime Effects

**Files:**
- Audit: every file from `git diff-tree --no-commit-id --name-status -r 10f1c17`
- Modify: only settings views/models and current runtime consumers with absent behavior
- Test: create `CatbirdTests/SettingsRuntimeWiringTests.swift` if no existing focused test covers a recovered setting

**Interfaces:**
- Produces: a one-to-one mapping from each visible control to persisted state and an observable runtime consumer

- [ ] **Step 1: Build a setting-to-consumer table in the ledger**

For each `10f1c17` hunk, record control label, storage property, runtime consumer, and disposition. Audit these concrete mappings: `requireAltText` to composer submit validation; `highlightLinks` and `linkStyle` to attributed post links; `confirmBeforeActions` to mute/unfollow confirmation; `showReadingTimeEstimates` to post metadata; `showLanguageIndicators` to declared-language chips; `disableHaptics` to every `PlatformHaptics` entry point; `loggedOutVisibility` to the self-label record write; `threadSortOrder` to `getPostThreadV2.sort`; `largerAltTextBadges` to image-grid ALT badges; and `mlsMessageRetentionDays` to retention-policy startup sync. Exclude cosmetic churn, broad `AppState` replacements, the OAuth-blocked account actions removed by the historical commit, and any setting already wired differently on current `main`.

- [ ] **Step 2: Test the concrete pure mappings first**

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

- [ ] **Step 4: Test, update ledger, and commit**

```bash
xcodebuild test -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,id=40111BBE-8709-40D0-9016-A27448486A80' \
  -only-testing:CatbirdTests/SettingsRuntimeWiringTests
jj describe -m 'Catbird: recover missing settings runtime wiring'
jj new
```

If every historical setting is already present or superseded, commit only the evidence-bearing ledger update with message `Catbird: audit recovered settings wiring`.

### Task 10: Reconcile Threaded Replies with Current Main

**Files:**
- Modify only if evidence requires: `Catbird/Features/Feed/Views/PostView.swift`
- Modify only if evidence requires: `Catbird/Features/Feed/Views/Thread/UIKitThreadView.swift`
- Test: `CatbirdTests/ThreadReplyLayoutTests.swift`
- Exclude: account/settings cleanup from `b86c5ca`

**Interfaces:**
- Produces: sibling replies do not connect to one another, direct children retain connectors, omitted children retain continuation affordance

- [ ] **Step 1: Run the current sibling-reply regression suite**

```bash
xcodebuild test -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,id=40111BBE-8709-40D0-9016-A27448486A80' \
  -only-testing:CatbirdTests/ThreadReplyLayoutTests
```

- [ ] **Step 2: Compare behavior, not whole files**

Diff `b86c5ca` against the current two view files. If current code passes all three tests and exposes the same continuation behavior at runtime, mark `b86c5ca` superseded and make no product-code edit. Otherwise port only the missing connector predicate or continuation affordance.

- [ ] **Step 3: Verify nested, sibling, and omitted reply layouts**

Build and capture thread screenshots for all three arrangements. Confirm no regression to scroll position, initial reveal animation, or App Entity annotations.

- [ ] **Step 4: Update ledger and commit**

```bash
jj describe -m 'Catbird: reconcile threaded reply layout'
jj new
```

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

- [ ] **Step 1: Freeze all generator inputs before generation**

```bash
jj status
jj new
```

Expected: clean checkpoint before any generator command.

- [ ] **Step 2: Create a manifest-to-runtime audit table**

For each candidate commit from `67d8872` through `641531a`, record: user-visible intent, canonical manifest/schema entry, handwritten runtime implementation, generated artifact, shortcut inclusion, current disposition, and test coverage. Explicitly reconcile the 10-shortcut cap and exclude duplicate handwritten/generated Like/Repost implementations.

- [ ] **Step 3: Restore the canonical manifest, change inputs, and regenerate**

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

- [ ] **Step 5: Update ledger and commit**

```bash
jj describe -m 'Catbird: reconcile App Intents recovery surface'
jj new
```

### Task 12: Final Cross-Platform Verification and Integration Audit

**Files:**
- Modify: `LOST_WORK_RECOVERY_EXECUTION.md`
- Evidence: `/tmp/catbird-recovery-final/`

**Interfaces:**
- Consumes: all recovered slice commits
- Produces: closed ledger, build/test logs, screenshots, device results, integration-ready branch

- [ ] **Step 1: Audit scope and conflict markers**

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

- [ ] **Step 2: Run the final automated matrix**

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

- [ ] **Step 4: Close every ledger row**

No row may remain `candidate`. For every exclusion or supersession, include the replacement commit/code path and test or runtime evidence.

- [ ] **Step 5: Seal the final audit**

```bash
jj describe -m 'Catbird: record lost-work recovery verification'
jj new
jj status
```

Expected: a clean working copy. Do not move `main`; present the branch and evidence for final review first.
