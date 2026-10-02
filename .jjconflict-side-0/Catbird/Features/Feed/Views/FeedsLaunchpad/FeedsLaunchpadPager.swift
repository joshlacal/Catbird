//
//  FeedsLaunchpadPager.swift
//  Catbird
//
//  Vertical paging container for the side-drawer feeds launchpad. Pages are
//  precomputed by FeedsLaunchpadLayout; this view only presents them.
//

#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

struct FeedsLaunchpadPager<SlotContent: View>: View {
  @Binding var currentPage: Int?
  let verticalPadding: CGFloat
  let horizontalPadding: CGFloat
  /// Builds the page list for a given viewport height. The pager measures
  /// its OWN resolved height via the `GeometryReader` below — as a normal,
  /// safe-area-respecting descendant of the drawer's `NavigationStack`, that
  /// height already excludes the stack's real toolbar chrome (close button,
  /// floating bottom-bar toolbar), so nothing else needs to reserve space
  /// for it. The SAME measured number then sizes every page frame and
  /// drives the paging snap below, so chunking, framing, and snapping read
  /// one shared value instead of three independently-computed ones that can
  /// silently drift apart. Do not pass in a height computed elsewhere, and
  /// do not add `.ignoresSafeArea()` here — that would let content escape
  /// the NavigationStack's legitimately-reserved chrome space.
  let makePages: (CGFloat) -> [FeedsLaunchpadPage]
  /// Per-page background drop target (drop on empty space appends to the
  /// page's section). nil disables the drop area for that page.
  let pageDropDelegate: (FeedsLaunchpadPage) -> (any DropDelegate)?
  /// Reports the computed page count on first measurement and on every
  /// change. The page indicator is rendered by the CALLER, outside this
  /// view, rather than as an internal overlay here — see the call site
  /// (`FeedsStartPage.drawerContent`) for why: a non-glass overlay nested
  /// inside this view ends up inside the caller's `GlassEffectContainer`
  /// scope on iOS 26+, which silently sampled it into the shared glass
  /// backdrop instead of drawing it as an opaque layer.
  var onPageCountChange: (Int) -> Void = { _ in }
  /// Reports the measured viewport height (same value fed into `makePages`)
  /// on first measurement and on every change — e.g. rotation or a Dynamic
  /// Type size change. The caller uses this to clamp Dynamic-Type-sensitive
  /// slot heights (like the banner) so a rendered slot never disagrees with
  /// the height `makePages` chunked against. Additive/no-op by default so
  /// existing call sites are unaffected.
  var onPageHeightChange: (CGFloat) -> Void = { _ in }
  @ViewBuilder let slotView: (FeedsLaunchpadSlot) -> SlotContent

  var body: some View {
    GeometryReader { geometry in
      let pageHeight = geometry.size.height
      let pages = makePages(pageHeight)

      ScrollView(.vertical) {
        LazyVStack(spacing: 0) {
          ForEach(pages) { page in
            pageView(page)
              .frame(height: pageHeight)
              .id(page.index)
          }
        }
        .scrollTargetLayout()
      }
      .scrollTargetBehavior(.paging)
      .scrollPosition(id: $currentPage)
      .scrollIndicators(.hidden)
      // ScrollView otherwise renders its content on into the neighboring
      // safe-area strip (converting it to a content inset, the standard
      // continuous-feed behavior) — so even though `pageHeight` is correct,
      // the NEXT page's top was still visible under the NavigationStack's
      // floating bottom-bar toolbar at rest. Pinning to the measured size and
      // clipping stops rendering at the exact viewport edge; the strip below
      // shows only the drawer's backdrop, never page content.
      .frame(width: geometry.size.width, height: geometry.size.height)
      .clipped()
      .onChange(of: pages.count, initial: true) { _, newCount in
        onPageCountChange(newCount)
        if let page = currentPage, page >= newCount {
          currentPage = max(newCount - 1, 0)
        }
      }
      .onChange(of: pageHeight, initial: true) { _, newHeight in
        onPageHeightChange(newHeight)
      }
    }
  }

  @ViewBuilder
  private func pageView(_ page: FeedsLaunchpadPage) -> some View {
    let content = VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(page.slots.enumerated()), id: \.offset) { _, slot in
        slotView(slot)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, verticalPadding)
    .padding(.horizontal, horizontalPadding)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .contentShape(Rectangle())

    if let delegate = pageDropDelegate(page) {
      content.onDrop(of: [UTType.plainText.identifier], delegate: delegate)
    } else {
      content
    }
  }
}

/// iOS-home-screen-style page indicator: dots housed in a vertical capsule,
/// each individually tappable to jump pages. Two layers share one geometry:
/// a visual (non-interactive) capsule of narrow 6pt dots, and an invisible
/// tap-target layer widened to 44pt horizontally and 20pt tall (matching the
/// same `dotSpacing` gap as the visual layer, so targets stay well clear of
/// each other). A 6pt-tall target (matching the visual dot) proved too thin
/// to hit reliably, and expanding each dot's `.contentShape` independently
/// (rather than giving it a real, larger layout frame) caused neighboring
/// 44pt-tall regions to overlap almost completely and made taps resolve to
/// the wrong page. VoiceOver still sees one adjustable element, matching the
/// pre-existing accessibility contract.
struct FeedsLaunchpadPageIndicator: View {
  let pageCount: Int
  @Binding var currentPage: Int?

  private let dotSize: CGFloat = 6
  private let dotSpacing: CGFloat = 8
  private let tapTargetHeight: CGFloat = 20

  var body: some View {
    if pageCount > 1 {
      ZStack(alignment: .trailing) {
        VStack(spacing: dotSpacing) {
          ForEach(0..<pageCount, id: \.self) { index in
            Circle()
              .fill(index == (currentPage ?? 0) ? Color.primary : Color.primary.opacity(0.3))
              .frame(width: dotSize, height: dotSize)
          }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 5)
        .background(Capsule().fill(.ultraThinMaterial))
        .allowsHitTesting(false)

        VStack(spacing: dotSpacing) {
          ForEach(0..<pageCount, id: \.self) { index in
            Button {
              withAnimation(.easeInOut(duration: 0.2)) {
                currentPage = index
              }
            } label: {
              // A fully-transparent `Color.clear` label intermittently drops
              // out of hit-testing even with an explicit `.contentShape` —
              // a documented SwiftUI quirk. A technically-nonzero alpha
              // keeps the tap target reliable while staying visually
              // invisible against the capsule behind it.
              Color.white.opacity(0.001)
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: tapTargetHeight)
            .contentShape(Rectangle())
          }
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Feeds pages")
      .accessibilityValue("Page \((currentPage ?? 0) + 1) of \(pageCount)")
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment:
          currentPage = min((currentPage ?? 0) + 1, pageCount - 1)
        case .decrement:
          currentPage = max((currentPage ?? 0) - 1, 0)
        @unknown default:
          break
        }
      }
    }
  }
}
#endif
