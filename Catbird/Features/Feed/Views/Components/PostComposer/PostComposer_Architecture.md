# Post Composer — Architecture & Roadmap

This document describes the current architecture of the Post Composer, proposes targeted improvements to align with iOS 26-era APIs and robustness goals, and outlines a clean, feature‑rich UIKit variant that shares the same domain layer.

- Source root: `Catbird/Features/Feed/Views/Components/PostComposer/`
- Key types: `PostComposerView`, `PostComposerViewModel`, `ThreadPostEditorView`, `MediaUploadManager`, `RichTextFacetUtils`
- Protocol client: Petrel (AT Protocol) via `AppState.atProtoClient` and `postManager`

## Overview

The composer is a modular SwiftUI feature that supports:
- Rich text with live facet parsing (links, mentions, hashtags) and URL cards.
- Images (multi‑select), video (incl. GIF→video conversion), alt text, and a simple audio→visualizer→video flow.
- Replies, quotes, single posts, and multi‑post threads with per‑entry media and state.
- Draft persistence and a minimize/restore workflow integrated with `AppState.composerDraftManager`.
- Labels, language tags, and thread‑gating rules aligned with the Bluesky protocol.

## Current Architecture

- View layer (SwiftUI)
  - `PostComposerView`: Container, sheets, pickers, toolbars, and submit/minimize. Uses `.interactiveDismissDisabled(true)`, shows account switcher, emoji picker, link creation, label selector, threadgate, GIF picker, audio recorder/preview.
  - Components: `ThreadPostEditorView`, `EnhancedRichTextEditor`/`ModernEnhancedRichTextEditor` (link facets, paste handling, attributed text), `ComposeURLCardView`, `LabelSelectorView`, `ReplyingToView`, `OutlineTagsView`, `AltTextEditorView`, `MediaGalleryView`.

- View model (domain + state)
  - `@MainActor @Observable PostComposerViewModel` centralizes state and behavior: text, attributed text (NSAttributedString + AttributedString), languages, labels, outline tags; reply/quote; media (images/video/GIF), alt text editing; URL detection + cards; mention suggestions/resolution; posting state; threadgate settings.
  - Files by concern:
    - `PostComposerCore.swift`: reset, thread entry CRUD, validation, language detection, single/whole‑thread post creation, embed builders, thumbnail pre‑uploads.
    - `PostComposerTextProcessing.swift`: parsing with `PostParser.parsePostContent`, AttributedString↔NSAttributedString bridges (iOS 26+), `toFacets()` and `facetsAsAttributedString` via Petrel.
    - `PostComposerMediaManagement.swift`: add/remove/load media, photos picker flow, alt text editing, video thumbnailing, source tracking, GIF→video conversion entry points.
    - `PostComposerUploading.swift`: upload images/video via Petrel (`uploadBlob`, chunked video through `MediaUploadManager`), HEIC→JPEG, compression.
    - `PostComposerModels.swift`: `PostComposerDraft`, codable wrappers for thread entries/media for persistence.
    - Utils: `RichTextFacetUtils` (link facet helpers), `LanguageHelpers`.
  - Integration points: `AppState.atProtoClient`, `AppState.postManager`, `AppState.composerDraftManager`.

- Data flow
  - Text updates → parse with `PostParser` → facets → style with `AppBskyFeedPost.facetsAsAttributedString` → detect URLs → fetch URL cards → pre‑upload thumbnails.
  - Media selection → normalization (GIF clears other media, video exclusive) → upload on submit → embed union construction.
  - Thread mode → per‑entry state saved/loaded via `updateCurrentThreadEntry()`/`loadEntryState()` → batch creation via `postManager.createThread`.

- Concurrency & state
  - Concurrency: async/await at API edges, `@MainActor` for UI state. Loop‑prevention guards (`isUpdatingText`, `isDraftMode`).
  - Drafts: serialize minimal safe state; do not persist raw media blobs.

- Posting pipeline
  - Build facets (including unresolved mention resolution), embed (images/video/GIF/quote/external), labels (`ComAtprotoLabelDefs.SelfLabels`), languages, threadgate rules → `postManager.createPost` or `createThread`.

- Testing
  - `CatbirdTests/PostComposerFixesTests.swift`, `CatbirdTests/PostComposerIntegrationTests.swift` cover state flow, draft I/O, thread mode, and regressions (loop prevention, media sync).

## iOS 26 Alignment (Modernization Plan)

- Attributed text first
  - Standardize on `AttributedString` for editing, selection, and styling; keep `NSAttributedString` as compatibility bridge only. Centralize bridges in a single adapter to avoid duplication across `Core` and `TextProcessing`.
  - Use `AttributedTextSelection` for precise link insertion and selection‑aware facet editing.

- Modern TextEditor path
  - Collapse to a single `ModernEnhancedRichTextEditor` that wraps iOS 26’s TextEditor pipeline. Keep a thin legacy fallback behind availability checks.
  - Move `toFacets()` extraction and `facetsAsAttributedString` styling behind a protocol so both editors share identical behavior.

- Photos & paste improvements
  - Migrate Photos/Video loading fully to Transferable models; consolidate paste providers so image, GIF, genmoji, and URL detection share a single sanitizer.
  - Add in‑place video trimming (AVAssetExport) and lossless image orientation fix pre‑upload.

- Drag & drop + keyboard
  - Support system drag & drop for images/URLs into the editor; add iPad keyboard shortcuts for media, labels, and thread actions.

- App Intents & Share Extension
  - Add App Intent “Compose Post” for Shortcuts/Siri with fields: text, images, URL, reply/quote. Provide a Share Extension target to hand off content into the same draft model.

- Accessibility & intl
  - Guided alt‑text prompts, VoiceOver ordering for editor→media grid, dynamic type audit. Persist per‑account language defaults and auto‑tag with `NLLanguageRecognizer` confidence thresholds.

## Robustness Improvements

- Unidirectional data flow
  - Replace ad‑hoc flags with a small reducer/state machine in the view model: Actions (EditText, AddMedia, ResolveMention, DetectURLs, Submit, SubmitSucceeded/Failed…), Effects (async tasks), State transitions verified by tests.

- Actors for network surfaces
  - Introduce `ComposerNetworkActor` for mention search, URL card fetch, and thumbnail uploads with request coalescing, cancellation, and debouncing. Keeps UI code deterministic.

- Offline and retry semantics
  - Queue posts (and threads) offline with durable storage and background upload using BackgroundTasks. Exponential backoff and API error mapping (auth, rate limit, transient, validation) → user‑visible status with retry.

- Media pipeline hardening
  - Strict MIME and size checks, predictable compression targets, progressive upload with cancellation hooks. Unified error surfaces for image/video/GIF flows.

- Validation + telemetry
  - Pre‑submit validator (char count, empty post, embed conflicts, missing alt text) produces actionable messages. Structured logging with subsystems (`PostComposer.View`, `.VM`, `.Network`).

- Test coverage
  - Add tests for: mention resolution merge, AttributedString facet round‑trips, URL card thumbnail pre‑upload, offline queue persistence, and reducer transition matrix.

## Bluesky Ecosystem Fit

- Facets and byte ranges
  - Use Petrel’s builders for mentions/links/hashtags with byte‑precise slices. Keep a single offset calculator and fuzz test against multibyte text.

- Embeds parity
  - Support: images (≤4 with alt/aspect), video, external link (with uploaded thumb), quote, and future record embeds; refuse incompatible combos with clear UI.

- Labels, languages, threadgate
  - Self labels via `ComAtprotoLabelDefs.SelfLabels`, multi‑language tagging, and `AppBskyFeedThreadgate` rules from `threadgateSettings` with saved presets per account.

- Draft and minimize semantics
  - Preserve draft across sessions; minimize → docked chip in the timeline with quick restore. Clear draft on successful submit or explicit discard.

## UIKit Variant (Clean, Feature‑Packed, Robust)

Goals
- Share domain logic and models with SwiftUI; UIKit is a presentation layer for teams preferring TextKit and precise keyboard control.

Architecture
- Modules
  - `ComposerDomain` (SPM target): current `PostComposerViewModel` (refactored into reducer‑style), models, parsing, media/upload, Petrel integration, tests.
  - `ComposerUIKIt`: UIKit views/controllers, accessories, and layout. Can embed SwiftUI components via `UIHostingController` where convenient.
- Coordinators
  - `PostComposerCoordinator` owns navigation and sheets (labels, threadgate, GIF, account switcher), hosts `PostComposerViewController` and child controllers.
- Controllers & views
  - `PostComposerViewController`: root container with `UITextView` (TextKit 2) for attributed editing + custom layout manager for facet highlighting and tappable ranges.
  - `ComposerAccessoryBar`: inputAccessoryView with actions (photo, video, GIF, labels, thread, link, language, CW), character counter, progress.
  - `MediaGridViewController`: `UICollectionViewCompositionalLayout` for images/GIF/video tiles with alt‑text badges and reorder/delete.
  - `MentionAutocompleteController`: table overlay anchored to caret; async search with debounce and cancellation.
  - `URLPreviewCell`: rich link preview with thumbnail, title, remove; pre‑upload thumbs.

Feature set
- Drag & drop into text view or media grid; context menus for alt text, reorder, and quick replace.
- Keyboard shortcuts (⌘I image, ⌘V video, ⌘G GIF, ⌘L link, ⌘↩︎ post, ⌘T thread entry).
- Fine‑grained selection APIs for link creation and facet editing, undo/redo robustly integrated with TextKit 2.

Robustness
- Same reducer/actor domain; controllers bind via observation or async streams. Strict separation of UI and domain allows deterministic tests.
- Snapshot tests for controller states; integration tests for posting pipeline and media flows.

Migration strategy
- Start by embedding current `ModernEnhancedRichTextEditor` inside a UIKit shell (`UIHostingController`). Replace piece‑by‑piece with TextKit 2 while keeping domain intact.

## Implementation Checklist

- Consolidate attributed text bridges; adopt AttributedString first tooling and a single editor abstraction.
- Introduce reducer + `ComposerNetworkActor`; replace flags with actions and effects.
- Add offline queue + background uploads with retry.
- Harden media pipeline (format checks, compression targets, failure surfaces) and add tests.
- Ship App Intent + Share Extension for composition.
- Build UIKit package with Coordinator, AccessoryBar, TextKit 2 editor, media grid, and autocomplete overlay.

## Key Paths & Types (for reference)

- Views: `PostComposerView.swift`, `Components/ThreadPostEditorView.swift`, `Components/EnhancedRichTextEditor.swift`, `Media/*`, `Audio/*`
- ViewModel & domain: `PostComposerViewModel.swift`, `PostComposerCore.swift`, `PostComposerTextProcessing.swift`, `PostComposerMediaManagement.swift`, `PostComposerUploading.swift`
- Utilities: `Utils/RichTextFacetUtils.swift`, `Utils/LanguageHelpers.swift`
- Tests: `CatbirdTests/PostComposerFixesTests.swift`, `CatbirdTests/PostComposerIntegrationTests.swift`

