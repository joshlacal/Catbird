//
//  FeedsLaunchpadLayout.swift
//  Catbird
//
//  Pure page-chunking math for the side-drawer feeds launchpad. No SwiftUI:
//  callers measure heights (Dynamic Type included) and pass them in, so this
//  stays deterministic and unit-testable.
//

import CoreGraphics
import Foundation

enum FeedsLaunchpadSection: String, Equatable, Sendable {
  case pinned
  case saved
}

enum FeedsLaunchpadSlot: Equatable, Sendable {
  case banner
  case titleRow
  case addFeedButton
  case defaultButton
  case sectionHeader(FeedsLaunchpadSection, isContinuation: Bool)
  case feedRow(FeedsLaunchpadSection, feeds: [String])
}

struct FeedsLaunchpadPage: Equatable, Identifiable, Sendable {
  let index: Int
  /// The single section whose rows appear on this page (pages never mix
  /// sections; nil for a prefix-only page). Drives the page-background drop.
  let section: FeedsLaunchpadSection?
  let slots: [FeedsLaunchpadSlot]
  var id: Int { index }
}

struct FeedsLaunchpadMetrics: Equatable, Sendable {
  var containerHeight: CGFloat
  var verticalPadding: CGFloat
  var columns: Int
  var cellHeight: CGFloat
  var rowSpacing: CGFloat
  var bannerHeight: CGFloat
  var titleRowHeight: CGFloat
  var addFeedButtonHeight: CGFloat
  var defaultButtonHeight: CGFloat
  var sectionHeaderHeight: CGFloat
}

enum FeedsLaunchpadLayout {
  /// `pinnedGridFeeds` excludes the default feed (rendered in the big
  /// button); `savedFeeds` is the full saved list.
  static func pages(
    pinnedGridFeeds: [String],
    savedFeeds: [String],
    includeAddFeedButton: Bool,
    metrics: FeedsLaunchpadMetrics
  ) -> [FeedsLaunchpadPage] {
    let pageHeight = metrics.containerHeight - metrics.verticalPadding * 2
    guard pageHeight > 0, metrics.columns > 0, metrics.cellHeight > 0 else { return [] }

    let rowUnit = metrics.cellHeight + metrics.rowSpacing

    func rowsThatFit(in remaining: CGFloat) -> Int {
      guard remaining >= metrics.cellHeight else { return 0 }
      return 1 + Int((remaining - metrics.cellHeight) / rowUnit)
    }

    func chunkRows(_ feeds: [String]) -> [[String]] {
      stride(from: 0, to: feeds.count, by: metrics.columns).map {
        Array(feeds[$0..<min($0 + metrics.columns, feeds.count)])
      }
    }

    var pages: [FeedsLaunchpadPage] = []

    // Page 1 fixed prefix.
    var page1Slots: [FeedsLaunchpadSlot] = [.banner, .titleRow]
    var prefixHeight = metrics.bannerHeight + metrics.titleRowHeight
    if includeAddFeedButton {
      page1Slots.append(.addFeedButton)
      prefixHeight += metrics.addFeedButtonHeight
    }
    page1Slots.append(.defaultButton)
    prefixHeight += metrics.defaultButtonHeight

    var pinnedRows = chunkRows(pinnedGridFeeds)
    var page1Section: FeedsLaunchpadSection?

    if !pinnedRows.isEmpty {
      let remaining = pageHeight - prefixHeight - metrics.sectionHeaderHeight
      let fit = rowsThatFit(in: remaining)
      if fit > 0 {
        page1Slots.append(.sectionHeader(.pinned, isContinuation: false))
        let take = min(fit, pinnedRows.count)
        page1Slots.append(contentsOf: pinnedRows.prefix(take).map { .feedRow(.pinned, feeds: $0) })
        pinnedRows.removeFirst(take)
        page1Section = .pinned
      }
    }
    pages.append(FeedsLaunchpadPage(index: 0, section: page1Section, slots: page1Slots))

    func appendSectionPages(
      _ section: FeedsLaunchpadSection,
      rows: [[String]],
      startsAsContinuation: Bool
    ) {
      var rows = rows
      var isContinuation = startsAsContinuation
      while !rows.isEmpty {
        let remaining = pageHeight - metrics.sectionHeaderHeight
        // Guarantee forward progress even in degenerate geometry.
        let take = min(max(1, rowsThatFit(in: remaining)), rows.count)
        var slots: [FeedsLaunchpadSlot] = [.sectionHeader(section, isContinuation: isContinuation)]
        slots.append(contentsOf: rows.prefix(take).map { .feedRow(section, feeds: $0) })
        rows.removeFirst(take)
        pages.append(FeedsLaunchpadPage(index: pages.count, section: section, slots: slots))
        isContinuation = true
      }
    }

    appendSectionPages(.pinned, rows: pinnedRows, startsAsContinuation: page1Section == .pinned)
    appendSectionPages(.saved, rows: chunkRows(savedFeeds), startsAsContinuation: false)

    return pages
  }
}
