import CoreGraphics
import Testing

@testable import Catbird

struct FeedsLaunchpadLayoutTests {
  // pageHeight = 800 - 2*12 = 776. Page-1 prefix = banner 190 + title 92 +
  // default 96 = 378. Pinned rows on page 1: remaining = 776-378-48 = 350
  // -> fits 2 rows (120 + 132 = 252 <= 350; 3 rows = 384 > 350).
  // Full section page: 776-48 = 728 -> fits 5 rows.
  private func metrics(
    containerHeight: CGFloat = 800,
    cellHeight: CGFloat = 120
  ) -> FeedsLaunchpadMetrics {
    FeedsLaunchpadMetrics(
      containerHeight: containerHeight,
      verticalPadding: 12,
      columns: 4,
      cellHeight: cellHeight,
      rowSpacing: 12,
      bannerHeight: 190,
      titleRowHeight: 92,
      addFeedButtonHeight: 60,
      defaultButtonHeight: 96,
      sectionHeaderHeight: 48
    )
  }

  private func feeds(_ prefix: String, _ n: Int) -> [String] {
    (0..<n).map { "\(prefix)-\($0)" }
  }

  @Test func sectionsSplitAcrossPages() {
    let pages = FeedsLaunchpadLayout.pages(
      pinnedGridFeeds: feeds("pin", 12),  // 3 rows of 4
      savedFeeds: feeds("sav", 6),        // 2 rows
      includeAddFeedButton: false,
      metrics: metrics()
    )
    #expect(pages.count == 3)

    // Page 0: prefix + pinned header + 2 rows
    #expect(pages[0].section == .pinned)
    #expect(pages[0].slots.prefix(3) == [.banner, .titleRow, .defaultButton])
    #expect(pages[0].slots[3] == .sectionHeader(.pinned, isContinuation: false))
    #expect(pages[0].slots.count == 6)  // + 2 feed rows

    // Page 1: pinned continuation, 1 remaining row
    #expect(pages[1].section == .pinned)
    #expect(pages[1].slots.first == .sectionHeader(.pinned, isContinuation: true))
    #expect(pages[1].slots.count == 2)

    // Page 2: saved starts fresh
    #expect(pages[2].section == .saved)
    #expect(pages[2].slots.first == .sectionHeader(.saved, isContinuation: false))
    #expect(pages[2].slots.count == 3)  // header + 2 rows
  }

  @Test func savedAlwaysStartsFreshPage() {
    let pages = FeedsLaunchpadLayout.pages(
      pinnedGridFeeds: feeds("pin", 4),  // 1 row — page 1 has spare room
      savedFeeds: feeds("sav", 4),
      includeAddFeedButton: false,
      metrics: metrics()
    )
    #expect(pages.count == 2)
    #expect(pages[0].section == .pinned)
    #expect(pages[1].section == .saved)
  }

  @Test func emptyFeedsYieldSinglePrefixPage() {
    let pages = FeedsLaunchpadLayout.pages(
      pinnedGridFeeds: [], savedFeeds: [],
      includeAddFeedButton: false, metrics: metrics()
    )
    #expect(pages.count == 1)
    #expect(pages[0].section == nil)
    #expect(pages[0].slots == [.banner, .titleRow, .defaultButton])
  }

  @Test func tinyContainerPushesPinnedToPageTwo() {
    // pageHeight = 500-24 = 476; prefix 378; 476-378-48 = 50 < cellHeight
    let pages = FeedsLaunchpadLayout.pages(
      pinnedGridFeeds: feeds("pin", 4), savedFeeds: [],
      includeAddFeedButton: false,
      metrics: metrics(containerHeight: 500)
    )
    #expect(pages[0].section == nil)
    #expect(pages[0].slots == [.banner, .titleRow, .defaultButton])
    #expect(pages[1].slots.first == .sectionHeader(.pinned, isContinuation: false))
  }

  @Test func largerCellsProduceMorePages() {
    let small = FeedsLaunchpadLayout.pages(
      pinnedGridFeeds: feeds("pin", 20), savedFeeds: feeds("sav", 20),
      includeAddFeedButton: false, metrics: metrics(cellHeight: 120)
    )
    let large = FeedsLaunchpadLayout.pages(
      pinnedGridFeeds: feeds("pin", 20), savedFeeds: feeds("sav", 20),
      includeAddFeedButton: false, metrics: metrics(cellHeight: 240)
    )
    #expect(large.count > small.count)
  }

  @Test func rowsChunkByColumnsPreservingOrder() {
    let pages = FeedsLaunchpadLayout.pages(
      pinnedGridFeeds: feeds("pin", 5), savedFeeds: [],
      includeAddFeedButton: false, metrics: metrics()
    )
    guard case .feedRow(_, let row0) = pages[0].slots[4],
          case .feedRow(_, let row1) = pages[0].slots[5] else {
      Issue.record("expected two feed rows")
      return
    }
    #expect(row0 == ["pin-0", "pin-1", "pin-2", "pin-3"])
    #expect(row1 == ["pin-4"])
  }

  @Test func editModeInsertsAddFeedButtonAndReducesFit() {
    // pageHeight 700-24 = 676. Without add: 676-378-48 = 250 -> 1 row
    // (2 rows = 252 > 250). With add: 250-60 = 190 -> still 1 row; use a
    // height where the button flips fit: 726-24 = 702; 702-378-48 = 276 ->
    // 2 rows; with add: 276-60 = 216 -> 1 row.
    let without = FeedsLaunchpadLayout.pages(
      pinnedGridFeeds: feeds("pin", 8), savedFeeds: [],
      includeAddFeedButton: false, metrics: metrics(containerHeight: 726)
    )
    let with = FeedsLaunchpadLayout.pages(
      pinnedGridFeeds: feeds("pin", 8), savedFeeds: [],
      includeAddFeedButton: true, metrics: metrics(containerHeight: 726)
    )
    #expect(without[0].slots.filter { if case .feedRow = $0 { return true }; return false }.count == 2)
    #expect(with[0].slots.contains(.addFeedButton))
    #expect(with[0].slots[2] == .addFeedButton)  // after banner, titleRow
    #expect(with[0].slots.filter { if case .feedRow = $0 { return true }; return false }.count == 1)
  }
}
