# Post Composer — Implementation Tasks (Parallelizable)

This checklist breaks the remaining work into clear, parallel tracks with dependencies, acceptance criteria, and suggested ownership. Use it to coordinate multiple implementers or agents.

- Scope: Complete a robust, production‑ready composer with UIKit text editor + SwiftUI shell, aligned with iOS 26, Bluesky protocol, and Catbird’s architecture.
- Entry points: `PostComposerViewUIKit.swift` (new), `PostComposerView.swift` (existing), `PostComposerViewModel.swift` + extensions (domain), `Components/*`, `Media/*`, `Utils/*`.

## 0) Adoption & Toggle
- [ ] Add feature flag to choose `PostComposerViewUIKit` vs existing `PostComposerView`.
- [ ] Update all presentation sites (e.g., `ContentView.swift`) to use the flag.
- [ ] Ensure restore‑from‑draft path can instantiate either view.
- Acceptance: Flag on → UIKit path; off → legacy path; both can post successfully.
- Depends on: None.

## 1) UIKit Editor Integration (Core)
- [ ] Consolidate editor abstraction: keep UIKit `EnhancedRichTextEditor` as default; legacy `RichTextEditor` remains fallback.
- [ ] Ensure AttributedString↔NSAttributedString bridge is centralized (single adapter) and used by VM.
- [ ] Verify link menu (“Create Link”) appears with selected text; invokes `LinkCreationDialog` and updates facets.
- [ ] Selection→facet mapping correctness (byte ranges) verified with multibyte text tests.
- Acceptance: Editing, selection, link creation behave identically to legacy; facets serialize correctly.
- Depends on: Existing `EnhancedRichTextEditor`, VM insert helpers.

## 2) Media Pickers & Sheets (UIKit View)
- [ ] Add Photos pickers (images, video) to `PostComposerViewUIKit` matching legacy toolbar.
- [ ] Integrate GIF picker sheet; ensure GIF clears other media and starts GIF→video flow.
- [ ] Integrate audio recorder and visualizer preview sheets; pipe generated video into VM.
- [ ] Integrate Alt Text editor sheet driven by `currentEditingMediaId`.
- Acceptance: All media types selectable; conflicts resolved; alt text editable; previews and progress shown.
- Depends on: Existing components in `Media/*`, `Audio/*`, VM methods.

## 3) URL Cards & Thumbnails
- [ ] Ensure URL detection feeds `urlCards` and UI shows `ComposeURLCardView`.
- [ ] Call `viewModel.preUploadThumbnails()` on appear and when cards change.
- [ ] Add retry control to each card via `retryThumbnailUpload` if needed.
- Acceptance: New URLs display cards; thumbnails uploaded eagerly or on demand; removal works.
- Depends on: `PostComposerCore` URL handling + thumbnail cache.

## 4) Threading UI in UIKit Shell
- [ ] Reuse `ThreadPostEditorView` via `UIHostingController` inside UIKit composer; wire tap handlers to VM.
- [ ] Ensure `addNewThreadEntry`, `updateCurrentThreadEntry`, `loadEntryState` work with UIKit view.
- [ ] Provide “Create Thread”/“Exit Thread” toggles and vertical thread list.
- Acceptance: Create, navigate, remove, and post threads end‑to‑end from UIKit composer.
- Depends on: Existing SwiftUI thread components; VM thread APIs.

## 5) Draft/Minimize Workflow
- [ ] Hook minimize button to `onMinimize` with `saveDraftState()`; dismiss and show minimized chip in timeline.
- [ ] Verify restore path reconstructs selection, media, facets (best effort) without loops.
- Acceptance: Draft survives app relaunch; restore is stable; minimize UX matches existing flow.
- Depends on: `composerDraftManager` and VM draft APIs.

## 6) Accessibility & Internationalization
- [ ] VoiceOver order: editor → media grid → url cards → actions.
- [ ] Dynamic Type, sufficient contrast; focus restores after sheet dismissals.
- [ ] Alt‑text prompts and missing alt checks.
- Acceptance: Basic accessibility audit passes; alt text guidance present; language tags default correctly.
- Depends on: Existing A11y patterns; `detectLanguage()`.

## 7) Keyboard Shortcuts & Drag/Drop (iPadOS)
- [ ] Add keyboard shortcuts: ⌘I image, ⌘V video, ⌘G GIF, ⌘L link, ⌘↩︎ post, ⌘T thread.
- [ ] Enable drag & drop of images/URLs into editor and media grid.
- Acceptance: Shortcuts work; drops attach media or add links; no crashes.
- Depends on: UIKit text view + SwiftUI drop modifiers.

## 8) Offline Queue & Background Uploads
- [ ] Implement durable queue for posts/threads with BackgroundTasks scheduling.
- [ ] Add exponential backoff and error classification (auth/rate/transient/validation).
- [ ] User feedback for pending/failed posts with retry.
- Acceptance: Airplane mode post queues; auto‑uploads when online; retries with clear status.
- Depends on: AppState storage; postManager; BackgroundTasks.

## 9) Network Actor & Debounce
- [ ] Introduce `ComposerNetworkActor` to centralize mention search, URL cards, thumbnail uploads with debouncing and cancellation.
- [ ] Replace ad‑hoc calls in VM with actor methods; add coalescing for repeated inputs.
- Acceptance: Fewer redundant calls; cancellation respected; no UI jank.
- Depends on: VM refactor points; lightweight actor scaffolding.

## 10) Validation, Errors, Telemetry
- [ ] Pre‑submit validator: character limits, empty content, embed conflicts, missing alt text.
- [ ] Map Petrel errors to user‑friendly messages; structured logs (`PostComposer.View`, `.VM`, `.Network`).
- Acceptance: Clear errors; logs capture key paths; no silent failures.
- Depends on: VM/state machine entry points.

## 11) Testing
- [ ] Unit: facet byte ranges (multibyte), link creation selection math, URL card lifecycle, thumbnail pre‑upload.
- [ ] Integration: draft save/restore; thread create; GIF→video; video upload failure paths.
- [ ] UI tests: accessibility traversal; link menu action; posting happy path.
- Acceptance: New tests pass locally and CI; failures are actionable.
- Depends on: Test harness; sample data.

## 12) Performance
- [ ] Debounce text parsing; avoid duplicate facet/style passes.
- [ ] Memory guardrails for large media; predictable image compression targets.
- [ ] On‑device profiling for typing latency and upload throughput.
- Acceptance: Typing latency stable; memory within budget; no hitches during uploads.
- Depends on: VM hot paths; media pipeline.

## 13) App Intents & Share Extension
- [ ] App Intent: “Compose Post” with parameters (text, images, URL, reply/quote).
- [ ] Share Extension: hand off to shared draft model; deep link to composer.
- Acceptance: Intent shows in Shortcuts; Share works from Photos/Safari.
- Depends on: Draft model; routing.

## 14) Documentation & Developer UX
- [ ] Update `PostComposer_Architecture.md` with UIKit variant details and new flows.
- [ ] Add usage examples and integration notes for adopters.
- Acceptance: New contributors can implement a sub‑task from docs alone.
- Depends on: Completed changes.

---

## Suggested Parallelization Map
- Track A (UIKit Editor & Links): Sections 1, 3, 7, 10, 11 (facet tests)
- Track B (Media & Sheets): Section 2, 12 (media perf), 11 (media tests)
- Track C (Threading & Drafts): Sections 4, 5, 11 (thread/draft tests)
- Track D (Network & Offline): Sections 8, 9, 10, 11 (integration tests)
- Track E (A11y, Docs, Intents): Sections 6, 13, 14

## Coordination Notes
- Define acceptance criteria per PR using this checklist.
- Gate risky work (8–9) behind flags; land editor/media first.
- Keep changes atomic; rely on existing tests; add targeted new tests only.

