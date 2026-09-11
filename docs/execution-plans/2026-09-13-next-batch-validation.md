# Catbird next-batch integration — September 13, 2026

This batch follows the signed arm64 app installed on Josh’s iPhone, version 1.0 (2), source d86722bbe3e9cc8abc4b6e5cee5665cb4e56223e. The installed app stays available while later repairs are integrated and validated locally. A second physical-device installation is not authorized.

## Integrated source

Reviewed isolated integration: 7ba63d03c0c8441d116087d3c135d84f70e66ad9; initial canonical snapshot: 6389e5ac. Exactly 20 files were restored after verifying canonical still matched the installed source; unrelated changes were preserved.

- AskCatbird: 92c5839991dc6721a80353501872f9302da9642d, seven files. Input presentation, bounded thread-reading tools, readable references, and a closed Private Cloud Compute gate for this unprovisioned build. Independent read-only review found no blocker.
- Public thread detail: eight-file preserved patch, SHA256 fb6ad2a29f0e549aa39c4e0b964966ba167cc2662056dd7fa3eda63aa66dfd87. Depth-aware sibling preservation, continuation controls, measured avatar connectors, reply prompt sizing and bottom occlusion. The old owner jj snapshot is stale and is not authoritative.
- Feed grouping: 2fd4bbfb, two files. Select the feed entry by ancestry and server order instead of potentially equal/skewed timestamps.
- Feed description/removal controls: 1366e93b82472b227af05f173e73c8eff1c415ba, three files. Full descriptions and icon-relative accessible removal controls.

## Validation boundaries

One serial simulator build/test run covers AskCatbirdToolPolicyTests, AskCatbirdThreadFormatterTests, CopilotCloudAvailabilityTests, CopilotReferencePresentationTests, ThreadReplyLayoutTests, ThreadBlockedItemsTests, ThreadComposePromptLayoutTests, and CachedFeedViewPostIdentityTests. Results will be recorded after completion. Standalone/component evidence from owners does not establish full app or phone behavior.

Chat-detail scroll anchoring/reaction inspection is awaiting separate review and integration. The broader feed-discovery proposal was subsequently approved for implementation and remains isolated while this run is active. No remote push, deployment, uninstall, or data reset is part of this work.

## First executable result

All 61 selected tests passed, zero failures/skips, 166.8 seconds. Result bundle: /Users/joshlacalamito/Library/Developer/XcodeBuildMCP/workspaces/Catbird-Petrel-7447cfa27eae/result-bundles/test_sim_2026-09-13T13-16-04-897Z_pid63431_fbdcd684.xcresult. The app and test targets built successfully. Exported attachments are in /private/tmp/catbird-next-batch-attachments. Visual inspection confirms one/two/three avatar/action rows and connecting lines, but ImageRenderer omits UIKit post text and shows unsupported-view placeholders. These attachments do not establish readable full-post rendering; a UIKit-hosted capture is required.

## Chat and unavailable Circles follow-up

Corrected complete chat patch v2 SHA256 cf647522dc939f7252975a6c5349928e9c34b75b001d37d380fce8da3cadfc86 passed independent source review after active account/client guards were repaired. Nine reviewed paths (chat eight plus feed entry removal) integrated into canonical 56e1cd35 from isolated 9b94ab8d8e1735dbabeff798a1b5b6655d4d11c5. The unsupported Circles placeholder was a real remaining else branch in FeedsStartPage; it is now absent while Account Settings consent remains. Five UIKit scroll tests are pending execution.

## Second validation attempt

The chat/OCR app and test build succeeded. Test execution on FEA6F8AE did not launch Catbird; testmanagerd remained active, and unrelated simulator PosterBoard/ClockPoster crash reports were observed. The tool timed out at 300 seconds while xcodebuild continued. The verified own runner PID29690 was interrupted and subsequently exited; no app assertions ran. Build log test_sim_2026-09-13T13-24-55-802Z_pid63431_06c05a79.log and prepared product test_sim_2026-09-13T13-24-55-802Z_pid63431_52f9a6b5.xctestproducts are preserved. Retry will use this product without compiling.

Discovery review before integration found pending intents resurrecting legacy removals, stale local membership overwriting another device additions, and same-DID client replacement retaining an old query provider. These are assigned to the isolated owner with regression coverage required.

## No-build retry results

On simulator 2A3194, chat tests executed: four passed and short-transcript boundary failed because contentSize did not grow. Owner is fixing fixture observation and requiring measured geometry changes before accepting anchor assertions. Failure retained in test_sim_2026-09-13T13-34-52-508Z_pid63431_6a3e95b8.xcresult.

The complete feed identity suite then passed all 27 tests, including actual UIKit hierarchy/OCR capture. Exported /private/tmp/catbird-feed-uikit-attachments images were inspected: one/two/three readable sentinel post bodies and correct connectors, no placeholder symbols; heights215/330/445. Result test_sim_2026-09-13T13-35-54-101Z_pid63431_a4174427.xcresult. This resolves the fixture pixel gap, not the original user live payload gap.

## Chat fixture strengthened; real failures exposed

The v3 fixture now reads observable heights in a SwiftUI body, attaches to a UIWindowScene, and waits for actual measured height changes. Four tests fail and one passes: reading anchor jumps200pt, prepend shifts62/262pt, simultaneous bottom growth misses513pt, and short transcript stays0 instead of403pt. Dynamic Type passes. Result test_sim_2026-09-13T13-37-43-883Z_pid63431_fd6a1401.xcresult is retained. Chat owner has exclusive serial compiler access and four-file canonical ownership to repair; this implementation is not accepted yet.

## Discovery final review

Revised v2 resolves all three original findings. A final new-account edge was found: no server saved-feed preference starts from an empty list and can remove Following/change default when saving or pinning the first feed. Owner is adding the established Following fallback plus empty-save/pin/default-order tests before acceptance. Discovery remains isolated.

## Prepared discovery and chat trial

Discovery v3 source review cleared all known blockers including new-account Following. Prepared isolated final tree ddd1eceb3931b81136d00d58aa84b3419f266413 contains26 paths including tracked docs; patch backup is outside source. It is not yet canonical while chat owns the serial build slot.

First flow-layout trial passed measured reading anchor, prepend, and Dynamic Type, but two bottom-follow cases failed. A second trial captures bottom intent from the last completed layout and strengthens starting-bottom preconditions. No acceptance claim yet.

## Discovery integrated and executable validation

Reviewed 26-path discovery tree ddd1eceb3931b81136d00d58aa84b3419f266413 integrated into canonical c88a8e57 while preserving chat trials and unrelated changes. A compiler failure identified the shared feedLibraryActions lazy initializer requiring explicit @MainActor; the one-line owner-reviewed fix was applied. Governing documents: docs/design-docs/feed-discovery-experience-proposal.md and docs/superpowers/plans/feed-discovery-experience.md; decisions are in docs/DECISIONS.md.

The next serial run built the app and tests and passed all 35 discovery unit tests plus FeedDiscoveryJourneyTests/testNormalModeEntryProvidesNativeSearchAndCanClose. The journey uses the existing fixture account and verifies normal-mode Add Feed, native search, and Close; it does not establish live preference saves or account authorization. The same run failed the selected chat short-transcript test. Result bundle: /Users/joshlacalamito/Library/Developer/XcodeBuildMCP/workspaces/Catbird-Petrel-7447cfa27eae/result-bundles/test_sim_2026-09-13T14-05-11-880Z_pid63431_501f94fe.xcresult. A UIKitToolbar hierarchy warning was retained; discovery visual review remains pending.

## Chat baseline diagnostics

Before delayed growth, layout attributes and cell bounds retained 138 points while both prior preferred size and fresh fitting returned 111 points. SwiftUI reported 110.976 points for the row and the expected 80-point embed. Screenshot: /private/tmp/catbird-discovery-chat-results/2CB422CD-CF12-490C-8239-A18925D19CE5.png. This is a real baseline mismatch; previous passes without rendered geometry checks are not accepted. A bounded trial explicitly enables constraint-driven collection self-sizing invalidation; all six meaningful layout tests are being rerun. No further phone installation is authorized or performed.

## Constraint invalidation trial retained

Explicit enabledIncludingConstraints did not resolve sizing: six tests failed at rendered baseline, before exercising growth. Result test_sim_2026-09-13T14-13-15-996Z_pid63431_f604b9ab.xcresult, build succeeded. The next bounded trial restores superclass preferredLayoutAttributesFitting bookkeeping before enforcing full-width fitting. This remains unaccepted until actual geometry tests pass.

## Discovery visual evidence and remaining boundaries

The screenshot journey passed after using the actual Home accessibility label when tab_home is absent. Result test_sim_2026-09-13T14-24-00-786Z_pid63431_7824f3d3.xcresult. Inspected screenshots show normal-mode Add Feed, native Search your feeds in the header, and Discover Feeds with native Search feeds, Close, and a retryable authentication error for the fixture account. Durable screenshots are in /Users/joshlacalamito/.codex/visualizations/2026/09/13/01a09aa7-6232-76c2-bc59-568ec2dd00a1/next-batch-feeds-normal.png and next-batch-discovery-auth-error.png. The fixture enables Circles, so its visible supported card is expected; this is not an unsupported-account screenshot. The blue fallback banner does not establish the user's actual profile artwork transition. Live save/reopen and actual profile banner remain unverified.

## Chat diagnosis narrowed to UIKit safe-area propagation

Explicit shouldInvalidateLayout acceptance of changed preferred dimensions resolves the initial short-transcript baseline and reaches growth. Remaining mismatches measure exactly the per-cell 62-point top safe area; SwiftUI ignoresSafeArea did not remove that amount from UIKit fitting. Diagnostics confirm cell and content safeAreaInsets.top=62. That failed trial is retained in 7824f3d3; a new cell-level zero safe-area override leaves inset ownership with the collection. Composer inset growth separately missed the 120-point bottom increase, so the collection now captures bottom intent before inset changes and schedules layout. Both changes remain under test.

## Bottom geometry repaired; reading cases remain

Result test_sim_2026-09-13T14-28-02-298Z_pid63431_829817f4.xcresult passed three real UIKit tests: composer inset growth, simultaneous bottom embeds, and short-to-scrollable transcript growth. Cell-level safe-area ownership removed the evidenced 62-point sizing error. Reading-anchor, history-prepend, and Dynamic Type cases still failed. The first two retain stale preferred sizes after SwiftUI has rendered the correct new size; a shared weak-cell ChatTranscriptContent geometry notification is being validated in all four production cell registrations and the fixture. The six-test suite remains the acceptance gate.

## Final chat acceptance and integrated runtime

All seven meaningful rendered UIKit chat tests passed, zero failures/skips, in 124.283 seconds. Result: /Users/joshlacalamito/Library/Developer/XcodeBuildMCP/workspaces/Catbird-Petrel-7447cfa27eae/result-bundles/test_sim_2026-09-13T14-35-18-612Z_pid63431_cabd62f1.xcresult. This covers delayed growth/shrink while reading, history prepend, Dynamic Type, bottom growth, short-to-scrollable growth, and single/coalesced composer inset changes. App and test targets built successfully. Final independent source review found no release-blocking issue. The prior five-pass/one-Dynamic-Type-failure receipt b993fdcb is retained. The final correction uses one reader anchor for the entire layout pass and suppresses competing per-cell adjustments; a weak SwiftUI geometry callback explicitly invalidates stale preferred size. Post-test edits to production source were indentation only.

Product integration snapshot: 5229636e010db74d42df67d50dd32ab6eea63478. The canonical checkout includes unrelated work and was not sealed wholesale. No additional phone installation, push, production deploy, uninstall, account reset, or data erase occurred.

The tested app installed and launched on the released signed-in simulator 0F51. An existing system deep-link dialog ignored automation; a data-preserving simulator shutdown/boot cleared it. Normal launch then succeeded (PID26918), and the real timeline rendered readable posts. Screenshot: /Users/joshlacalamito/.codex/visualizations/2026/09/13/01a09aa7-6232-76c2-bc59-568ec2dd00a1/next-batch-signed-in-timeline.jpg. Runtime log: /Users/joshlacalamito/Library/Developer/XcodeBuildMCP/workspaces/Catbird-Petrel-7447cfa27eae/logs/blue.catbird_2026-09-13T14-39-33-362Z_helperpid26706_ownerpid63447_c452a05f.log. Feed selector taps still reported success without changing the screen, so signed-in discovery and the actual profile artwork transition remain unverified.

Remaining manual verification: on the simulator, tap the grid feed selector; inspect the real profile banner with Search your feeds inactive/active; open Add Feed, inspect real results and a preview, then close. Verify save/reopen only in an appropriate test account. For chat, open an existing conversation containing delayed post embeds, scroll while embeds resolve, expand/collapse the keyboard and composer, and inspect reaction details on each transport. No message needs to be sent. These live/gesture/transport checks and physical-device validation are not established by the seven geometry tests.

## Preserved change and lint receipt

Validated follow-up is sealed as bab9a76c979bc0226f46f8962772cf9990777850 in /private/tmp/catbird-next-batch-validated, based on c88a8e57. A fresh empty jj change was opened immediately. Its seven files matched canonical byte-for-byte before this receipt-only append; the canonical working change was not sealed. Focused SwiftLint completed successfully: 60 warnings, zero serious violations across five Swift files. Full log: /private/tmp/catbird-next-batch-swiftlint.log. Warnings remain and are not represented as a clean lint run.

No build or test process remains active for this integration. Simulator 0F51 remains booted with the tested app and existing account; automation still cannot reliably navigate it. The physical phone remains on the earlier explicitly authorized installation. Cross-task status delivery was rejected by automatic approval review; the originating coordinator explicitly confirmed receipt via its monitor and requested ordinary task commentary instead, so no user action is pending for that rejected callback.
