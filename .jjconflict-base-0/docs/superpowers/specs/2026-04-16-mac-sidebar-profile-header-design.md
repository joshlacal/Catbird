# Mac Sidebar Profile Header — Design

**Status:** Approved, ready for implementation plan
**Scope:** Catbird Mac client sidebar + feed detail pane

## Problem

On macOS, the sidebar exposes `Profile` as a sibling tab to Search / Notifications / Chat. It works, but it doesn't tell you *which* account you're on, doesn't show identity at a glance, and clashes with the richer identity treatment the iOS drawer already has (banner + avatar + display name + handle at the top of `FeedsStartPage`).

Separately, the macOS feed detail pane renders its scrollbar in the middle of the visible area instead of along the window's trailing edge, because the `List` is constrained to 700pt wide and centered inside a wider pane.

## Goals

1. Add a persistent profile card at the top of the Mac sidebar: banner image, half-overlapping avatar, display name, and handle — all wrapped as a single rounded button.
2. Tapping the card navigates the detail pane to the user's own profile.
3. Remove the now-redundant `Profile` row (and its `Cmd+4` shortcut) from the sidebar.
4. Fix the feed scrollbar so it sits along the trailing edge of the detail pane.

## Non-goals

- Long-press / right-click account-switcher on the sidebar card. (iOS drawer has this; Mac can add it later if desired.)
- Any changes to the iOS drawer, the iPad layout, or the feed-row layout itself.
- Any changes to `UnifiedProfileView` or its routing.
- Any refactor of `FeedCollectionViewWrapper` beyond the scrollbar fix.

## Design

### 1. New component: `MacOSSidebarProfileHeader`

A new SwiftUI view (`#if os(macOS)`) living under `Catbird/Catbird/Core/UI/`. It renders a single self-contained card:

```
┌──────────────────────────────┐  RoundedRectangle
│ ░░░ banner image ░░░░░░░░░░░ │  cornerRadius: 14, style: .continuous
│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │  banner height: 68pt
│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│ ●●●                          │  avatar 52pt, offset y: +26pt (half overlap)
│ ●●●                          │  white/background ring ~1.5pt, leading inset 12pt
│ ● Display Name               │  .headline .bold, lineLimit 1, tail-truncate
│   @handle                    │  .subheadline .secondary, lineLimit 1, tail-truncate
└──────────────────────────────┘
```

**Layout:**

Composition (inside `Button(action: onTap) { ... }.buttonStyle(.plain)`):

```
VStack(spacing: 0):
  banner   (height 68, .frame(maxWidth: .infinity), clipped)
  content  (VStack(alignment: .leading, spacing: 1))
             Spacer().frame(height: 30)          ← reserves avatar's bottom half + small gap
             Text(displayName)  .headline .bold
             Text("@\(handle)") .subheadline .secondary
           .padding(.horizontal, 12)
           .padding(.bottom, 12)

.overlay(alignment: .topLeading) {
  AsyncProfileImage(size: 52)
    .overlay(Circle().stroke(Color(.windowBackgroundColor), lineWidth: 2))
    .padding(.leading, 12)
    .padding(.top, 68 - 26)                       ← avatar center lands on banner's bottom edge
}

.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
```

Why overlay (not offset): the avatar is placed with absolute padding from the card's top-leading corner, so it doesn't consume layout space in the content `VStack`. The `Spacer().frame(height: 30)` inside the content column is what preserves headroom for the avatar's lower half (26pt overflow + 4pt breathing room) before the display name.

**Banner:** `LazyImage(url: profile?.banner?.url)` with `.aspectRatio(contentMode: .fill)`. Fallback when `banner == nil` or the image errors: a `LinearGradient` from `Color.accentColor.opacity(0.35)` → `Color.accentColor.opacity(0.1)` (mirrors `FeedsStartPage.fallbackGradientBanner`).

Using the same avatar-half-overlap pattern as `ProfileHeader` (`UnifiedProfileView.swift:1238`) guarantees visual parity with the main profile page.

**Selection state:**

The card's outer `RoundedRectangle` carries a stroke that is only visible when the sidebar's current selection is `.profile`:

```swift
.overlay(
  RoundedRectangle(cornerRadius: 14, style: .continuous)
    .stroke(
      isSelected ? Color.accentColor.opacity(0.6) : Color.clear,
      lineWidth: 1.5
    )
)
```

When unselected: no stroke, no extra background — the card's banner/avatar carry it visually.

**Profile data loading:**

- `@State private var profile: AppBskyActorDefs.ProfileViewDetailed?` (detailed is required because `ProfileViewBasic` doesn't include `banner`).
- `loadUserProfile()` helper: `try await client.app.bsky.actor.getProfile(input: .init(actor: ATIdentifier(string: did)))` — same call the iOS drawer uses in `FeedsStartPage.loadUserProfile()`.
- Fetched on `.task` and re-fetched on `appState.userDID` change (which fires on account switch).

**Accessibility:**

- `.accessibilityElement(children: .combine)`
- `.accessibilityLabel("My profile")`
- `.accessibilityHint("Shows your profile")`
- `.accessibilityAddTraits(.isButton)`

### 2. Changes to `MacOSUnifiedSidebar`

- `body` restructures from a bare `List` into a `VStack(spacing: 0)`:

  ```
  VStack(spacing: 0) {
    MacOSSidebarProfileHeader(
      profile: profile,
      isSelected: selection == .profile,
      onTap: { selection = .profile }
    )
    .padding(.horizontal, 8)
    .padding(.top, 10)
    .padding(.bottom, 6)

    List(selection: $selection) { /* existing sections minus Profile */ }
      .listStyle(.sidebar)
  }
  ```

- **Delete** the `Label("Profile", systemImage: "person").tag(SidebarItem.profile)` row from the functional items section (currently `MacOSUnifiedSidebar.swift:35-36`).
- Add `@State private var profile: AppBskyActorDefs.ProfileViewDetailed?` and `loadUserProfile()` in this view. Fire it from the existing `.task { await initializeFeeds() }` and `.onChange(of: appState.userDID)` handlers, running in parallel with the feeds fetch.

### 3. Changes to `MacOSMainView`

- Remove the `Button("Profile") { selectedItem = .profile }.keyboardShortcut("4", modifiers: .command)` block from `keyboardShortcutButtons` (currently `MacOSMainView.swift:54-55`).
- Remaining shortcuts: Search `Cmd+F`, Feeds `Cmd+1`, Notifications `Cmd+2`, Chat `Cmd+3`.
- No changes to `windowTitle`; `.profile` case still returns `"Profile"` when the card is selected.

### 4. Keep `.profile` in `SidebarItem`

`SidebarItem.profile` remains in the enum — it is still the selection target when the card is tapped and the routing key used by `MacOSDetailRouter`. The case's `systemImage` and `label` become unused but harmless.

### 5. Feed detail pane scrollbar fix

In `Catbird/Catbird/Features/Feed/Views/FeedContent/FeedCollectionViewBridge.swift`, the macOS `FeedCollectionViewWrapper` body:

**Current (problem):**

```swift
List { ForEach(...) { FeedPostRow(...) } }
  .listStyle(.plain)
  .contentMargins(.top, 8, for: .scrollContent)
  .refreshable { ... }
  .frame(maxWidth: 700)          // constrains the List itself
  .frame(maxWidth: .infinity)    // then centers that 700pt List
```

The scrollbar is glued to the right edge of the 700pt `List`, which sits centered inside the wider detail pane.

**Fix:**

Remove both `.frame` modifiers on the `List`. Push the width cap down to each row's content so the List fills the pane (scrollbar at the trailing edge) while posts remain visually centered at 700pt max.

```swift
List {
  ForEach(stateManager.posts, id: \.id) { cachedPost in
    FeedPostRow(
      viewModel: stateManager.viewModel(for: cachedPost),
      navigationPath: $navigationPath,
      feedTypeIdentifier: stateManager.currentFeedType.identifier
    )
    .frame(maxWidth: 700)
    .frame(maxWidth: .infinity, alignment: .center)
    .listRowSeparator(.hidden)
    .listRowInsets(EdgeInsets())
    .onAppear { /* unchanged load-more trigger */ }
  }

  if stateManager.isLoading {
    HStack {
      Spacer()
      ProgressView("Loading more...").foregroundStyle(.secondary)
      Spacer()
    }
    .frame(maxWidth: 700)
    .frame(maxWidth: .infinity, alignment: .center)
    .listRowSeparator(.hidden)
    .listRowInsets(EdgeInsets())
    .padding(.vertical, 8)
  }
}
.listStyle(.plain)
.contentMargins(.top, 8, for: .scrollContent)
.refreshable { await stateManager.refreshUserInitiated() }
```

The inner `.frame(maxWidth: 700)` + outer `.frame(maxWidth: .infinity, alignment: .center)` pattern caps the row content width and centers it inside a full-width row — the List fills the detail pane, and the scrollbar anchors to the window's trailing edge.

## Files touched

| File | Change |
|---|---|
| `Catbird/Catbird/Core/UI/MacOSSidebarProfileHeader.swift` | **New.** The profile-card view described in §1. |
| `Catbird/Catbird/Core/UI/MacOSUnifiedSidebar.swift` | Wrap existing `List` in a `VStack` with the new header pinned above; remove the Profile row; add `profile` state + loader. |
| `Catbird/Catbird/Core/UI/MacOSMainView.swift` | Drop the `Cmd+4 → Profile` shortcut button. |
| `Catbird/Catbird/Features/Feed/Views/FeedContent/FeedCollectionViewBridge.swift` | Scrollbar fix in the macOS `FeedCollectionViewWrapper` body. |
| `Catbird/Catbird/Core/Navigation/SidebarItem.swift` | No change. |
| `Catbird/Catbird/Core/UI/MacOSDetailRouter.swift` | No change. |

## Testing

Manual (Mac build, 2–3 min each):

1. **Card appearance, signed in**: Launch, verify card shows correct banner, avatar half-overlapping, display name, handle. Correct scaling when sidebar is resized to min (200pt) and max (320pt) widths.
2. **Card no banner**: Test against an account whose profile has `banner == nil`. Fallback gradient should render.
3. **Selection state**: Click card → detail pane shows `UnifiedProfileView`, card shows accent stroke. Click Timeline → card stroke disappears.
4. **Account switch**: Switch accounts. Card re-fetches and re-renders for the new user (banner + avatar + name + handle all update).
5. **Profile tab gone**: Verify the old Profile row is absent from the functional section. `Cmd+4` is a no-op.
6. **Other shortcuts**: `Cmd+F`, `Cmd+1`, `Cmd+2`, `Cmd+3` still navigate correctly.
7. **Scrollbar**: Open Timeline. Confirm scrollbar sits on the window's trailing edge, not inside the content area. Confirm posts remain centered at 700pt max. Confirm on a wide window (1600pt+) that rows aren't stretched beyond 700pt.
8. **Pull-to-refresh**: Still works on the feed.

Compile check:
- `xcodebuild -project Catbird/Catbird.xcodeproj -scheme Catbird -destination 'platform=macOS' build`
- No new warnings in the four touched files.

## Risks

- **Banner absence during first load**: The first time the sidebar appears on a fresh launch, `profile` is `nil` until the fetch completes. Card renders the gradient fallback + initial-letter avatar until then — same pattern as iOS drawer. Acceptable.
- **Scrollbar fix regressing row width on iOS**: The change is inside `#else ... #endif` (macOS-only branch of `FeedCollectionViewWrapper`). iOS uses `FeedCollectionViewIntegrated` (UIKit). No cross-platform risk.
- **`SidebarItem.profile` drift**: Leaving the enum case with unused properties is a minor lint opportunity. Accepted — removing the case would cascade into `MacOSDetailRouter`, `windowTitle`, and deep-link handlers for no concrete benefit.
