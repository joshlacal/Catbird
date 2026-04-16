# Mac Sidebar Profile Header Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `Profile` tab in Catbird's macOS sidebar with a pinned profile card (banner + half-overlapping avatar + display name + handle, wrapped as one rounded button), and fix the feed scrollbar that currently sits in the middle of the detail pane.

**Architecture:** A new `MacOSSidebarProfileHeader` SwiftUI view is pinned above the existing `List` inside `MacOSUnifiedSidebar` via a `VStack`. Tapping it sets `selection = .profile`; the existing detail router (`MacOSDetailRouter`) is unchanged. The `Profile` row and `Cmd+4` keyboard shortcut are removed. The scrollbar fix moves the 700pt width constraint from the feed's `List` down to row content, so the `List` fills the detail pane and the scrollbar anchors to the trailing edge.

**Tech Stack:** SwiftUI (macOS 13+), Petrel (ATProto client + generated models), NukeUI (`LazyImage` for banner), existing `AsyncProfileImage` for the avatar.

**Spec:** `docs/superpowers/specs/2026-04-16-mac-sidebar-profile-header-design.md`

**Working directory for all commands:** `/Users/joshlacalamito/Developer/Catbird+Petrel/Catbird`

**Testing approach:** This is a UI-only change with no pure business logic to unit-test. Verification is a compile check (`xcodebuild build` for macOS) plus manual visual QA on a running Mac build. No new unit tests are added.

---

## File Map

| File | Role |
|---|---|
| `Catbird/Core/UI/MacOSSidebarProfileHeader.swift` | **New.** Self-contained rounded-rectangle button with banner + half-overlap avatar + name + handle. Owns no remote state; receives `profile`, `isSelected`, `onTap` from parent. |
| `Catbird/Core/UI/MacOSUnifiedSidebar.swift` | Wrap existing `List` in a `VStack` with the new header on top. Add `@State` for `ProfileViewDetailed` + loader. Remove the `Profile` row. |
| `Catbird/Core/UI/MacOSMainView.swift` | Drop the `Cmd+4 → Profile` hidden button. |
| `Catbird/Features/Feed/Views/FeedContent/FeedCollectionViewBridge.swift` | Move the 700pt width cap from the `List` itself down to each row's content (macOS branch only). |

---

## Task 1: Create `MacOSSidebarProfileHeader`

**Files:**
- Create: `Catbird/Core/UI/MacOSSidebarProfileHeader.swift`

- [ ] **Step 1.1: Create the new file with the full component**

Write `Catbird/Core/UI/MacOSSidebarProfileHeader.swift` with this exact content:

```swift
#if os(macOS)
import NukeUI
import Petrel
import SwiftUI

/// Pinned masthead at the top of the macOS sidebar showing the signed-in user's
/// banner, avatar (half-overlapping the banner), display name, and handle.
/// Acts as a single button that selects the `.profile` sidebar item.
struct MacOSSidebarProfileHeader: View {
  let profile: AppBskyActorDefs.ProfileViewDetailed?
  let isSelected: Bool
  let onTap: () -> Void

  private let bannerHeight: CGFloat = 68
  private let avatarSize: CGFloat = 52
  private let cornerRadius: CGFloat = 14
  private let horizontalInset: CGFloat = 12

  var body: some View {
    Button(action: onTap) {
      VStack(spacing: 0) {
        bannerView
          .frame(height: bannerHeight)
          .frame(maxWidth: .infinity)
          .clipped()

        VStack(alignment: .leading, spacing: 1) {
          // Reserve space for the avatar's lower half (26pt) plus breathing room.
          Spacer().frame(height: 34)

          Text(displayName)
            .font(.headline)
            .fontWeight(.bold)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)

          Text("@\(handle)")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, horizontalInset)
        .padding(.bottom, 12)
      }
      .background(Color(.windowBackgroundColor))
      .overlay(alignment: .topLeading) { avatarView }
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(
            isSelected ? Color.accentColor.opacity(0.6) : Color.clear,
            lineWidth: 1.5
          )
      )
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("My profile")
    .accessibilityHint("Shows your profile")
    .accessibilityAddTraits(.isButton)
  }

  // MARK: - Banner

  @ViewBuilder
  private var bannerView: some View {
    if let bannerURL = profile?.banner?.url {
      LazyImage(url: bannerURL) { state in
        if let image = state.image {
          image
            .resizable()
            .aspectRatio(contentMode: .fill)
        } else {
          fallbackGradient
        }
      }
    } else {
      fallbackGradient
    }
  }

  private var fallbackGradient: some View {
    LinearGradient(
      gradient: Gradient(colors: [
        Color.accentColor.opacity(0.35),
        Color.accentColor.opacity(0.1)
      ]),
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  // MARK: - Avatar

  @ViewBuilder
  private var avatarView: some View {
    AsyncProfileImage(url: profile?.finalAvatarURL(), size: avatarSize)
      .frame(width: avatarSize, height: avatarSize)
      .overlay(
        Circle().stroke(Color(.windowBackgroundColor), lineWidth: 2)
      )
      .padding(.leading, horizontalInset)
      .padding(.top, bannerHeight - avatarSize / 2)
  }

  // MARK: - Text helpers

  private var displayName: String {
    if let name = profile?.displayName, !name.isEmpty { return name }
    return profile?.handle.description ?? " "
  }

  private var handle: String {
    profile?.handle.description ?? ""
  }
}
#endif
```

- [ ] **Step 1.2: Add the new file to the Xcode project**

Run:
```bash
xcodebuild -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=macOS' -list >/dev/null
```

Then confirm the file is included in the build by opening Xcode and checking target membership, OR if the project uses a file-system-synchronized group (common in modern Catbird setups), just re-run the build below.

- [ ] **Step 1.3: Compile check**

Run:
```bash
xcodebuild -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -40
```

Expected: `** BUILD SUCCEEDED **`. If a "Cannot find 'MacOSSidebarProfileHeader' in scope" error appears during Task 2, re-add the file to the target.

- [ ] **Step 1.4: Commit**

```bash
git add Catbird/Core/UI/MacOSSidebarProfileHeader.swift
git commit -m "$(cat <<'EOF'
Catbird: Add MacOSSidebarProfileHeader component

Self-contained rounded-rectangle button showing a user's banner
with a half-overlapping avatar, display name, and handle. Used by
the macOS sidebar as a pinned masthead and selection target for
the .profile sidebar item.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Wire the header into `MacOSUnifiedSidebar` and drop the Profile row

**Files:**
- Modify: `Catbird/Core/UI/MacOSUnifiedSidebar.swift`

- [ ] **Step 2.1: Remove the `Profile` row from the functional section**

The current functional section (`MacOSUnifiedSidebar.swift:26-37`) reads:

```swift
      // MARK: - Functional Items
      Section {
        Label("Search", systemImage: "magnifyingglass")
          .tag(SidebarItem.search)

        notificationsRow

        chatRow

        Label("Profile", systemImage: "person")
          .tag(SidebarItem.profile)
      }
```

Replace it with:

```swift
      // MARK: - Functional Items
      Section {
        Label("Search", systemImage: "magnifyingglass")
          .tag(SidebarItem.search)

        notificationsRow

        chatRow
      }
```

(Only the `Profile` label + tag are removed; the surrounding structure is untouched.)

- [ ] **Step 2.2: Add profile state and loader inside `MacOSUnifiedSidebar`**

In `MacOSUnifiedSidebar.swift`, add a new `@State` property next to the other feed-state properties (near lines 16-20, after `@State private var isLoaded = false`):

```swift
  // Profile state for the pinned header
  @State private var profile: AppBskyActorDefs.ProfileViewDetailed?
```

Then add this loader at the end of the file's struct, right after the `initializeFeeds()` function (before the final closing brace):

```swift
  private func loadUserProfile() async {
    guard let client = appState.atProtoClient else { return }
    let did = appState.userDID
    guard !did.isEmpty else { return }

    do {
      let (code, data) = try await client.app.bsky.actor.getProfile(
        input: .init(actor: ATIdentifier(string: did))
      )
      if code == 200, let data {
        profile = data
      }
    } catch {
      logger.error("Failed to load user profile: \(error)")
    }
  }
```

- [ ] **Step 2.3: Fire the loader from `.task` and on account switch**

Locate the existing `.task` and `.onChange(of: appState.userDID)` modifiers in the `body` (currently lines 70-76):

```swift
    .task {
      await initializeFeeds()
    }
    .onChange(of: appState.userDID) { _, _ in
      isLoaded = false
      Task { await initializeFeeds() }
    }
```

Replace them with:

```swift
    .task {
      async let feeds: Void = initializeFeeds()
      async let userProfile: Void = loadUserProfile()
      _ = await (feeds, userProfile)
    }
    .onChange(of: appState.userDID) { _, _ in
      isLoaded = false
      profile = nil
      Task {
        async let feeds: Void = initializeFeeds()
        async let userProfile: Void = loadUserProfile()
        _ = await (feeds, userProfile)
      }
    }
```

This runs the two fetches concurrently and resets `profile` on account switch.

- [ ] **Step 2.4: Restructure `body` to pin the header above the `List`**

The current `body` (lines 24-77) starts with `var body: some View {` and returns a bare `List(selection: $selection) { ... } .listStyle(.sidebar) .task { ... } .onChange(of:) { ... }`.

Replace the body's top-level expression so the `List` is wrapped in a `VStack` with the profile header above it. Keep all existing sections and modifiers intact. The new body structure:

```swift
  var body: some View {
    VStack(spacing: 0) {
      MacOSSidebarProfileHeader(
        profile: profile,
        isSelected: selection == .profile,
        onTap: { selection = .profile }
      )
      .padding(.horizontal, 8)
      .padding(.top, 10)
      .padding(.bottom, 6)

      List(selection: $selection) {
        // MARK: - Functional Items
        Section {
          Label("Search", systemImage: "magnifyingglass")
            .tag(SidebarItem.search)

          notificationsRow

          chatRow
        }

        // MARK: - Timeline (always first, not draggable)
        Section {
          Label("Timeline", systemImage: "house")
            .tag(SidebarItem.feed(.timeline))
        }

        // MARK: - Pinned Feeds
        if !pinnedFeedsFiltered.isEmpty {
          Section("Pinned") {
            ForEach(pinnedFeedsFiltered, id: \.self) { feedURI in
              feedRow(for: feedURI)
            }
            .onMove { source, destination in
              movePinnedFeeds(from: source, to: destination)
            }
          }
        }

        // MARK: - Saved Feeds
        if !savedFeedsFiltered.isEmpty {
          Section("Saved") {
            ForEach(savedFeedsFiltered, id: \.self) { feedURI in
              feedRow(for: feedURI)
            }
            .onMove { source, destination in
              moveSavedFeeds(from: source, to: destination)
            }
          }
        }
      }
      .listStyle(.sidebar)
    }
    .task {
      async let feeds: Void = initializeFeeds()
      async let userProfile: Void = loadUserProfile()
      _ = await (feeds, userProfile)
    }
    .onChange(of: appState.userDID) { _, _ in
      isLoaded = false
      profile = nil
      Task {
        async let feeds: Void = initializeFeeds()
        async let userProfile: Void = loadUserProfile()
        _ = await (feeds, userProfile)
      }
    }
  }
```

Key points:
- `.task` and `.onChange` now attach to the outer `VStack` (not the `List`). That is correct — their behaviour is unchanged.
- The `Profile` row has been removed from the functional section (Step 2.1 change is preserved here).
- Everything else inside the `List` is identical to the previous body.

- [ ] **Step 2.5: Compile check**

Run:
```bash
xcodebuild -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -40
```

Expected: `** BUILD SUCCEEDED **`. Typical fixable errors if something got pasted wrong:
- "Cannot find 'profile' in scope": Step 2.2 property missing.
- "Cannot find 'loadUserProfile' in scope": Step 2.2 function missing.
- "Cannot find 'MacOSSidebarProfileHeader' in scope": Task 1 file not in target.

- [ ] **Step 2.6: Commit**

```bash
git add Catbird/Core/UI/MacOSUnifiedSidebar.swift
git commit -m "$(cat <<'EOF'
Catbird: Pin profile header in the macOS sidebar

Wrap the sidebar List in a VStack with a MacOSSidebarProfileHeader
pinned above. Remove the Profile row from the functional section —
the header is now the sole entry point for the .profile selection.
Fetch the user's detailed profile in parallel with feed init and
refresh on account switch.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Remove the `Cmd+4 → Profile` shortcut

**Files:**
- Modify: `Catbird/Core/UI/MacOSMainView.swift`

- [ ] **Step 3.1: Delete the Profile keyboard-shortcut button**

In `MacOSMainView.swift`, the `keyboardShortcutButtons` view (currently lines 43-60) contains:

```swift
  @ViewBuilder
  private var keyboardShortcutButtons: some View {
    Group {
      Button("Search") { selectedItem = .search }
        .keyboardShortcut("f", modifiers: .command)
      Button("Feeds") { selectedItem = .feed(.timeline) }
        .keyboardShortcut("1", modifiers: .command)
      Button("Notifications") { selectedItem = .notifications }
        .keyboardShortcut("2", modifiers: .command)
      Button("Chat") { selectedItem = .chat }
        .keyboardShortcut("3", modifiers: .command)
      Button("Profile") { selectedItem = .profile }
        .keyboardShortcut("4", modifiers: .command)
    }
    .frame(width: 0, height: 0)
    .opacity(0)
    .allowsHitTesting(false)
  }
```

Replace with the same block minus the last `Button("Profile") ... .keyboardShortcut("4", ...)` pair:

```swift
  @ViewBuilder
  private var keyboardShortcutButtons: some View {
    Group {
      Button("Search") { selectedItem = .search }
        .keyboardShortcut("f", modifiers: .command)
      Button("Feeds") { selectedItem = .feed(.timeline) }
        .keyboardShortcut("1", modifiers: .command)
      Button("Notifications") { selectedItem = .notifications }
        .keyboardShortcut("2", modifiers: .command)
      Button("Chat") { selectedItem = .chat }
        .keyboardShortcut("3", modifiers: .command)
    }
    .frame(width: 0, height: 0)
    .opacity(0)
    .allowsHitTesting(false)
  }
```

Leave `windowTitle` (lines 89-99) unchanged — `.profile` still returns `"Profile"` because the card is a valid selection target.

- [ ] **Step 3.2: Compile check**

Run:
```bash
xcodebuild -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3.3: Commit**

```bash
git add Catbird/Core/UI/MacOSMainView.swift
git commit -m "$(cat <<'EOF'
Catbird: Drop Cmd+4 Profile shortcut on macOS

The Profile row no longer exists in the sidebar; the profile header
card is now the sole entry point for the .profile selection, so the
stale keyboard shortcut is removed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Fix the macOS feed scrollbar position

**Files:**
- Modify: `Catbird/Features/Feed/Views/FeedContent/FeedCollectionViewBridge.swift`

- [ ] **Step 4.1: Move the 700pt max-width from the `List` down to row content**

In `FeedCollectionViewBridge.swift`, the macOS `FeedCollectionViewWrapper` body (inside the `#else` block for macOS, currently around lines 157-199) has this List section:

```swift
            } else {
                // Content list - use explicit ForEach to avoid generic confusion
                List {
                    ForEach(stateManager.posts, id: \.id) { cachedPost in
                        FeedPostRow(
                            viewModel: stateManager.viewModel(for: cachedPost),
                            navigationPath: $navigationPath,
                            feedTypeIdentifier: stateManager.currentFeedType.identifier
                        )
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .onAppear {
                            // Trigger load more when nearing end (last 5 items)
                            if let lastIndex = stateManager.posts.lastIndex(where: { $0.id == cachedPost.id }),
                               lastIndex >= stateManager.posts.count - 5,
                               !stateManager.isLoading {
                                Task {
                                    await stateManager.loadMore()
                                }
                            }
                        }
                    }

                    if stateManager.isLoading {
                        HStack {
                            Spacer()
                            ProgressView("Loading more...")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .padding(.vertical, 8)
                    }
                }
                .listStyle(.plain)
                .contentMargins(.top, 8, for: .scrollContent)
                .refreshable {
                    await stateManager.refreshUserInitiated()
                }
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
```

Replace the block (everything from `} else {` through the closing `}` of this branch) with:

```swift
            } else {
                // Content list - use explicit ForEach to avoid generic confusion
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
                        .onAppear {
                            // Trigger load more when nearing end (last 5 items)
                            if let lastIndex = stateManager.posts.lastIndex(where: { $0.id == cachedPost.id }),
                               lastIndex >= stateManager.posts.count - 5,
                               !stateManager.isLoading {
                                Task {
                                    await stateManager.loadMore()
                                }
                            }
                        }
                    }

                    if stateManager.isLoading {
                        HStack {
                            Spacer()
                            ProgressView("Loading more...")
                                .foregroundStyle(.secondary)
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
                .refreshable {
                    await stateManager.refreshUserInitiated()
                }
            }
```

Diff summary:
- Added `.frame(maxWidth: 700)` + `.frame(maxWidth: .infinity, alignment: .center)` to the `FeedPostRow` row.
- Added the same pair to the loading `HStack` row.
- Removed `.frame(maxWidth: 700)` and `.frame(maxWidth: .infinity)` from the `List` itself.

All other `FeedCollectionViewWrapper` logic (toolbar, `.task`, loading / empty states) is unchanged. The change is strictly scoped to the `#else` (macOS) branch — the `#if os(iOS)` branch is untouched.

- [ ] **Step 4.2: Compile check**

Run:
```bash
xcodebuild -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4.3: Commit**

```bash
git add Catbird/Features/Feed/Views/FeedContent/FeedCollectionViewBridge.swift
git commit -m "$(cat <<'EOF'
Catbird: Fix macOS feed scrollbar position

Move the 700pt width cap from the List itself down to each row's
content. The List now fills the detail pane (scrollbar anchored to
the window's trailing edge, matching macOS convention) while posts
remain visually centered at 700pt max.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Manual verification

**Files:** none (runtime verification).

- [ ] **Step 5.1: Full compile and run**

Build the app for macOS:
```bash
xcodebuild -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`.

Then run the built app. Either launch it from Xcode (press ⌘R on the Catbird scheme with the Mac destination selected), or from the built product path. Sign in if needed.

- [ ] **Step 5.2: Verify the profile card appears correctly**

With the app open and signed in:

1. The sidebar shows the profile card at the top, pinned above the sidebar `List`.
2. The card shows the real banner image (or gradient fallback if the account has no banner).
3. The avatar sits half on the banner, half below it (center of the avatar aligned with the banner's bottom edge).
4. Display name is bold; `@handle` appears beneath it in secondary grey.
5. Resize the sidebar column from narrow (~200pt) to wide (~320pt). The card reflows without clipping text or breaking the avatar overlap.
6. The gap between the avatar's bottom edge and the display name should read as comfortable (~8pt). If it looks cramped or too airy, adjust the `Spacer().frame(height: 34)` inside the content `VStack` (range ~28–40 is reasonable).

If any of these fail, record the symptom (screenshot) and check: did you paste the entire Task 1 file? Is `bannerHeight = 68`? Is `avatarSize = 52`? Is `padding(.top, bannerHeight - avatarSize / 2)` on the avatar?

- [ ] **Step 5.3: Verify selection behaviour**

1. Click the card. The detail pane shows your profile (`UnifiedProfileView`), and the card gains an accent-coloured stroke on its rounded-rectangle outline.
2. Click Timeline in the sidebar. The detail pane shows the timeline, and the card's stroke disappears.
3. Click the card again. Stroke returns.

- [ ] **Step 5.4: Verify Profile tab and Cmd+4 are gone**

1. The sidebar's top functional section shows only Search, Notifications, Chat — no Profile row.
2. Press `Cmd+4`. Nothing should happen (no selection change, no beep from an error — the key is simply unbound).
3. Press `Cmd+F` → Search is selected. `Cmd+1` → Timeline. `Cmd+2` → Notifications. `Cmd+3` → Chat. All still work.

- [ ] **Step 5.5: Verify account switch**

1. Switch to a different account via whatever path the app exposes on Mac (Settings → Accounts, or a deep link).
2. After the account transition completes, the card re-renders with the new user's banner, avatar, display name, and handle.

- [ ] **Step 5.6: Verify the feed scrollbar**

1. Select Timeline. Scroll the feed.
2. The scrollbar sits at the **right edge of the window** (not floating in the middle of the detail pane).
3. Posts remain centered and capped at 700pt wide. On a wide window (≥1600pt), there is visible empty space on both sides of the post column.
4. Pull-to-refresh still works (drag down past the top).
5. Loading-more still works (scroll near the bottom; the "Loading more..." row appears centered).

- [ ] **Step 5.7: Take a verification screenshot (optional but recommended)**

Capture the Mac window showing the new sidebar + feed and save it alongside the plan for future reference. This is not required; it's useful for PR descriptions.

- [ ] **Step 5.8: Final summary commit (optional)**

If any small refinements were needed during verification (e.g., slight banner-height tweak), commit them with a short descriptive message. If none were needed, skip this step.

---

## Spec Coverage Checklist

- [x] Profile card with banner, half-overlapping avatar, display name, handle, rounded-rectangle container → Task 1
- [x] Tap → navigate to profile → Task 2 (via `onTap: { selection = .profile }`)
- [x] Subtle selection state when profile is selected → Task 1 (accent stroke overlay driven by `isSelected`)
- [x] Remove the Profile row from the sidebar → Task 2
- [x] Remove the Cmd+4 keyboard shortcut → Task 3
- [x] Keep `.profile` in `SidebarItem` (no change) → covered in Task 2 (router untouched)
- [x] Fix the feed scrollbar to sit at the trailing edge → Task 4
- [x] Account-switch refetch → Task 2 (`.onChange(of: appState.userDID)` resets `profile` and reloads)
- [x] Manual verification covering all of the above → Task 5
