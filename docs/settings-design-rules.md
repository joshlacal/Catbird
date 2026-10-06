# Shared visual rules for retained Catbird screens

Catbird's retained screens already use shared typography and colors, but two parallel text APIs produced visibly different behavior. The named `design…` helpers used fixed system fonts, bypassing the font preferences honored by `appFont`. This change routes those helpers through the existing font manager without changing their base sizes or weights. Screen owners retain responsibility for their layouts; the rules below identify specific adoption work and the rendered checks that qualify it.

Governing scope: [parallel execution plan](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/execution-plans/2026-10-02-live-feedback-parallel-execution.md), [live feedback LITE-004](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/qa/catbird-lite-live-feedback.md#lite-004--audit-design-token-adoption-and-visual-consistency), [Lite release plan](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/execution-plans/2026-09-29-catbird-1.0-app-store-plan.md), and [resizability review](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/qa/iphone-resizability-reference-review.md). The isolated source base is Lite `f0ca2f5334ac87fd53ac30f50861f296576c8051`. The [owned decision record](#provisional-decisions-for-integration) below is for integration into the workspace decision queue; this lane does not edit the shared queue concurrently.

## What the source actually uses

The following inventory counts lexical references in the retained feature directories. A count includes conditional platform/DEBUG code and does not establish reachability or visual consistency. Font usage counts cover `appFont`, `appBody`, `appHeadline`, `appTitle*` and `appCaption`; spacing helper aliases are not counted in the `DesignTokens` column.

| Feature directory | `DesignTokens` references / files | App typography calls / files | Named `design…` typography calls / files |
| --- | ---: | ---: | ---: |
| Settings | 0 / 0 | 232 / 18 | 0 / 0 |
| Feed | 50 / 4 | 376 / 55 | 12 / 1 |
| Notifications | 2 / 1 | 18 / 3 | 0 / 0 |
| Chat | 79 / 10 | 45 / 11 | 55 / 9 |
| Search | 25 / 7 | 224 / 29 | 0 / 0 |
| Profile | 7 / 2 | 94 / 14 | 0 / 0 |

Settings' zero direct token references do not mean it lacks shared styling: it uses the shared font manager, semantic colors, Form/List and native controls. Conversely, token use in Messages did not imply accessibility correctness: its named text helpers bypassed that manager. No feature-directory callers of `solarium*` were found. `Core/UI/SearchBarView.swift` uses the Solarium modifiers, but no caller outside that component/its previews was found. Solarium therefore does not justify a broad production migration; leave it unchanged.

| Surface and actual component | Existing treatment | Action for the screen owner |
| --- | --- | --- |
| Feed rows, `FeedContent/FeedPostRow.swift` | Custom full-width `Color.separator` boundary after content; the UIKit feed has its own layout owner | Preserve the row boundary and inset content independently. Do not replace it with a card outline or avatar-aligned rule. Confirm both feed implementations where supported. |
| Notifications, `NotificationsView.swift` and `NotificationsActivityListView.swift` | Zero row insets plus leading/trailing separator alignment; subcontent can have an inset internal rule | Keep outer notification boundaries full width. An internal grouped subrow rule may align to that group's text; it must not replace the outer boundary. |
| Messages, `ConversationRow.swift` / `ConversationListView.swift` | 48-point avatar, 12-point avatar/text gap, 3-point text-stack gap, 6-point vertical content padding; default List outer insets remain | Keep the inbox inset intentionally. Its separator reaches its row-content bounds, not the screen edge. Keep inbox/search-result rows in the same context aligned. Larger text must not force the sender name to disappear beside timestamp/unread controls. |
| Search results, `MainViews/ResultsView.swift` | Zero List insets, custom 0.5-point full-row boundaries; built-in rules hidden | Preserve full-row result boundaries. Body inset and separator extent are different decisions. Avoid applying safe-area extension to interactive content. |
| Search discovery, `MainViews/DiscoveryView.swift` | 24-point outer section rhythm; mixed 12/16-point cards and 4/8-point shadows; compact topic chips; nested lists and horizontal collections | Use section spacing to distinguish independent discovery sections. Reserve rules for rows inside a section. Prefer one card treatment for equivalent items; do not draw both a heavy card outline and a separator for the same boundary. Retain all discovery functions. |
| Feeds drawer, `FeedsStartPage.swift` / `FeedsLaunchpadGlass.swift` | Token spacing mixed with intentional container geometry; headline/handle over artwork; caption2 grid names; separate native glass treatments | Keep existing container sizing, drawer-only scroll-edge suppression and glass grouping. Improve primary identity/grid labels with semantic roles and multiline height; do not make the default-feed action visually indistinguishable from selected-feed state. |
| Profile, `Unified/ProfileHeader.swift` | Existing identity hierarchy and semantic typography; secondary handle | Reuse the hierarchy concept for account headers, with multiline names and secondary handles. Do not move unrelated profile controls or add identical shadows to all headers. |
| Settings and support Forms | Native grouped rows, labels, switches, pickers, sections and footers | Let Form own row metrics and separators. Group by user intent. Keep explanatory copy in the label/section footer and allow wrapping. Retry/purchase status must be visible text with a usable control, not a toast-only result. |

## Shared rules to apply in owned screen changes

1. **Typography follows preferences.** Use `appFont(AppTextRole…)` for semantic roles or `appFont(size:weight:relativeTo:)` where an intentional base size is necessary. The eight named `design…` helpers now bridge to the latter. `designHeadline` retains its historical 24-point base; it is not equivalent to the 17-point `AppTextRole.headline`. For new UI, choose the semantic role by purpose. `designFont` remains explicitly fixed-size for the existing decorative live-status badge and must not be introduced for readable settings, names or body copy.
2. **Specify weight through a functioning API.** `AppTextRole.weight(...)` currently returns the same role; a selected/unselected distinction expressed only there has no effect. Use the explicit weighted app-font overload when a different weight matters, and pair selected state with another non-color-only cue. Coordinate a future shared API repair rather than adding more no-op role chaining.
3. **Spacing has a purpose.** Existing custom-component tokens provide 3-point microspacing, 6-point small gaps, 12-point internal gaps, 18-point outer padding, and 24-point section separation. Use equivalent tokens in newly edited custom components. Do not change an existing native 16-point Form/List inset to 15 merely to satisfy the grid. Do not scale container width or safe-area offsets from spacing tokens.
4. **A button size is not a touch target.** The existing 30/36/42-point button tokens describe visuals. Keep native control hit areas, or provide at least a 44-by-44-point interaction region for custom iOS controls. Use minimum heights instead of fixed heights around text; a control must grow when the user's font size grows. Independent adjacent buttons must not gain overlapping hit areas.
5. **Use semantic color and surfaces.** Primary/secondary text, accent actions, theme-aware backgrounds and `Color.separator` already exist. Keep explicit white-on-artwork text only where the underlying treatment guarantees readability on bright, dark and busy artwork. Do not add a global border/shadow/material layer to make otherwise unrelated components uniform. Native Form, navigation and toolbar glass remain system-owned.
6. **Separate content boundaries from content inset.** Feed and notification boundaries stay full width. Inbox boundaries intentionally follow native List content bounds. Search results act like feed rows; discovery acts like grouped sections. A new universal `SeparatorStyle` abstraction is unnecessary for these established, different containers.
7. **Measure the receiving container.** Use local available width and each safe-area edge. Do not use physical screen width or device identity to size row text, cards or overlays. Preserve view/navigation/editor identity across layout changes. Larger text should increase height or switch horizontal controls to a vertical arrangement before truncating the primary task.

## Implemented change and impacted callers

`Core/UI/DesignTokens.swift` changes only the eight named typography helpers and clarifies token scope. Their original baseline values remain: title1 28/bold, title2 22/semibold, headline 24/semibold, body 17/regular, bodyLarge 18/regular, callout 16/medium, caption 12/medium and footnote 13/regular. Each now supplies a corresponding Dynamic Type reference style. The existing app font manager supplies family, app size, Bold Text, letter spacing, line spacing, Dynamic Type enablement and maximum size. Consequently, the previous hard-coded extra line gaps and caption tracking now follow the user's chosen preferences; that is intentional.

The change reaches 67 existing calls without sweeping through screen files:

| Caller | Named helper calls |
| --- | ---: |
| `Chat/Views/Components/ChatMessageComposerView.swift` | 4 |
| `Chat/Views/Components/ChatParticipantViews.swift` | 8 |
| `Chat/Views/Components/RequestRow.swift` | 6 |
| `Chat/Views/ContactSearchList.swift` | 2 |
| `Chat/Views/ConversationListView.swift` | 4 |
| `Chat/Views/ConversationRow.swift` | 7 |
| `Chat/Views/GroupConfigView.swift` | 9 |
| `Chat/Views/MessageRequestsView.swift` | 12 |
| `Chat/Views/NewConversationView.swift` | 3 |
| `Feed/Views/MuteWordsSettingsView.swift` | 12 |

All paths above are relative to `Catbird/Features`. The standalone `designFont` live-status badge caller is unchanged. No spacing values, button heights, radii, divider placements, preferences, persistence or user data change in this patch.

## Rendered verification

The [typography harness](../tools/settings-visual-harness/README.md) compiles the production `DesignTokens.swift`, `FontManager.swift` and `Typography.swift` directly. It replaces only application state and unrelated contrast dependencies, makes no network requests and uses no real account. It measures all eight helper roles under app font-size, family, Bold Text, letter-spacing and line-spacing changes, and records the actual simulator preferred content-size category for comparison across launches. A visible gallery covers supporting copy, a message-style sample, an error state and a native retry control. It is component evidence, not a rendered production Settings screen or authenticated Messages qualification.

Screen owners must capture their actual production layout with normal and accessibility text, light/dark appearance, long names and loading/empty/error states. Test narrow/wide/short/tall/square receiving containers and return to the original size. The iOS 27.0 toolchain does not establish iPhone Duo 27.1 qualification. The completed component run below does not close the actual-screen, authenticated-device or resize-continuity gates.

### Completed component evidence

The standalone app compiled and ran on the dedicated `Catbird-Settings-Lane` simulator (`A37026BF-E9CC-4E69-AD2F-3425D737E09A`). The production helper input is sealed commit `f2b0d0f1150b3b5323e00b0bb77622174bafab90`; its `FontManager` and `Typography` inputs remain the frozen Lite base. Both current and baseline compilers used `swiftc -j 2`, Swift 5 language mode, the installed iOS simulator SDK and an iOS 18 deployment target. This is a simulator component executable, not a Lite app build or an iOS 18 runtime test.

- [Default light gallery](/Users/joshlacalamito/Developer/_catbird-settings-evidence/typography/default-light.png): all longer supporting/message/error text and the native retry control remain visible. The on-screen result reports 40 passed checks.
- [Large serif dark gallery](/Users/joshlacalamito/Developer/_catbird-settings-evidence/typography/large-serif-dark.png): larger app text, serif family, Bold Text, relaxed lines and loose tracking render through the production helpers; primary text wraps and the retry control remains visible.
- [Accessibility gallery](/Users/joshlacalamito/Developer/_catbird-settings-evidence/typography/accessibility-light.png): actual system accessibility size renders enlarged, wrapping text in the scroll container. This top-of-scroll screenshot does not establish bottom-control reachability at that size.
- [Normal receipt](/Users/joshlacalamito/Developer/_catbird-settings-evidence/typography/default-metrics.json) and [accessibility receipt](/Users/joshlacalamito/Developer/_catbird-settings-evidence/typography/accessibility-metrics.json): raw UIKit categories are `UICTContentSizeCategoryL` and `UICTContentSizeCategoryAccessibilityXXXL`. Each passes all 40 app-preference checks. The [cross-launch checker result](/Users/joshlacalamito/Developer/_catbird-settings-evidence/typography/verification.txt) passes 32 further assertions: every role grows with Dynamic Type and retains identical width/height when Dynamic Type is disabled.
- The body sample grows from **170 × 28.5 points** to **434.5 × 65.5 points** in unconstrained measurement. These dimensions include fixture padding and are a scaling test, not a production row size or overflow claim.
- [Baseline negative control](/Users/joshlacalamito/Developer/_catbird-settings-evidence/typography/baseline-negative-control.json): the same harness using the frozen base's `DesignTokens.swift` fails `title1 ignored app font size`. The [baseline screenshot](/Users/joshlacalamito/Developer/_catbird-settings-evidence/typography/baseline-negative-control.png) retains that visible failure. This rules out a test that passes regardless of helper wiring.

All four screenshots are **1206 × 2622 pixels**, verified from PNG headers in the [image manifest](/Users/joshlacalamito/Developer/_catbird-settings-evidence/typography/image-manifest.json). The [current source manifest](/Users/joshlacalamito/Developer/_catbird-settings-evidence/typography/current/source-manifest.json) and [baseline source manifest](/Users/joshlacalamito/Developer/_catbird-settings-evidence/typography/baseline/source-manifest.json) retain the exact compiled Swift files plus hashes; compiler and binary hashes sit beside each manifest. The baseline harness adds explicit failure-receipt writing; its success checks are identical. Runtime accessibility capture is retained in [the UI snapshot](/Users/joshlacalamito/Developer/_catbird-settings-evidence/typography/accessibility-ui-snapshot.json). No authenticated app, account preference, purchase, or production service was exercised. The fixture was terminated and its simulator text size/appearance returned to default/light when the slot was released.

## Provisional decisions for integration

### 2026-10-02 · Settings / LITE-004 · Share preference-aware named typography helpers

Chose: Route existing named `design…` typography helpers through `appFont(size:weight:relativeTo:)` while retaining their base sizes and weights (provisional). Because: actual Messages and Muted Words consumers bypass the user's font settings today. Rejected: replacing all screen calls or changing the 24-point legacy headline to the 17-point semantic headline (unnecessary layout churn). Reversible until: merge of the settings/support feedback bookmark. Override by: revert only the named-helper forwarding changes in `Core/UI/DesignTokens.swift` and retain the inventory.

### 2026-10-02 · Settings / LITE-004 · Preserve list boundaries by container purpose

Chose: Full-width feed/notification/search-result boundaries, native inset Messages inbox boundaries, and section spacing with internal rules for Search discovery (provisional). Because: these reflect timeline, inbox and discovery hierarchy without conflating row inset with separator extent. Rejected: one blanket separator or card style across every surface (discards the preferred feed/notification treatment and native Form behavior). Reversible until: merge of the corresponding screen owner's bookmark. Override by: request an owned-screen visual comparison and change that screen's row container; do not change a global token to force all separators.
