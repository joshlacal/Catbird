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
