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
  let pages: [FeedsLaunchpadPage]
  @Binding var currentPage: Int?
  /// Exact per-page frame height. This must equal the `containerHeight` the
  /// caller fed into `FeedsLaunchpadLayout.pages(...)` so the paging snap
  /// step lands on the same geometry the chunker assumed for row-fitting.
  /// Passed explicitly (rather than derived from `containerRelativeFrame`)
  /// because the ScrollView's relative container is its safe-area-adjusted
  /// viewport, not the full-bleed height the rest of the drawer uses.
  let pageHeight: CGFloat
  let verticalPadding: CGFloat
  let horizontalPadding: CGFloat
  /// Per-page background drop target (drop on empty space appends to the
  /// page's section). nil disables the drop area for that page.
  let pageDropDelegate: (FeedsLaunchpadPage) -> (any DropDelegate)?
  @ViewBuilder let slotView: (FeedsLaunchpadSlot) -> SlotContent

  var body: some View {
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
    // Without this, the ScrollView insets its content by the safe area
    // (including the drawer's floating bottom-bar toolbar), so its reported
    // viewport is shorter than `pageHeight` — pages would then snap short of
    // full-bleed and drift out of alignment by an accumulating amount each
    // page. Ignoring it here keeps the viewport == pageHeight == the height
    // FeedsLaunchpadLayout used to chunk rows, so pages snap flush.
    .ignoresSafeArea(edges: .vertical)
    .scrollTargetBehavior(.paging)
    .scrollPosition(id: $currentPage)
    .scrollIndicators(.hidden)
    .overlay(alignment: .trailing) {
      FeedsLaunchpadPageIndicator(pageCount: pages.count, currentPage: $currentPage)
        .padding(.trailing, DesignTokens.Spacing.sm)
    }
    .onChange(of: pages.count) { _, newCount in
      if let page = currentPage, page >= newCount {
        currentPage = max(newCount - 1, 0)
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

struct FeedsLaunchpadPageIndicator: View {
  let pageCount: Int
  @Binding var currentPage: Int?

  var body: some View {
    if pageCount > 1 {
      VStack(spacing: 8) {
        ForEach(0..<pageCount, id: \.self) { index in
          Circle()
            .fill(index == (currentPage ?? 0) ? Color.primary : Color.primary.opacity(0.3))
            .frame(width: 6, height: 6)
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
