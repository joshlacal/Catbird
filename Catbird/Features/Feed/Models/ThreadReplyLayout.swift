//
//  ThreadReplyLayout.swift
//  Catbird
//

import CoreGraphics
import Petrel

// MARK: - Layout Mode

/// The two thread presentations offered by the thread options menu.
enum ThreadLayoutMode: String, Hashable, Sendable {
  /// Every post sits at the same indent and each top-level reply shows a
  /// single short chain beneath it.
  case linear
  /// Replies indent under their parent and hang off the parent's rail.
  case tree

  init(threadedReplies: Bool) {
    self = threadedReplies ? .tree : .linear
  }

  /// `below` for `getPostThreadV2`.
  var fetchDepth: Int {
    switch self {
    case .linear: 10
    case .tree: 6
    }
  }

  /// `branchingFactor` for `getPostThreadV2`; `nil` keeps the AppView default.
  var fetchBranchingFactor: Int? {
    switch self {
    case .linear: 1
    case .tree: nil
    }
  }
}

// MARK: - Geometry

/// Every length used to place avatars and draw thread connectors.
///
/// Rows never measure each other: each row derives its avatar frame from
/// these constants and draws only its own connector pieces, so lines meet
/// across cell boundaries by construction.
enum ThreadReplyGeometry {
  /// Leading distance from the row edge to a depth-0 avatar.
  static let rowInset: CGFloat = 12
  static let lineWidth: CGFloat = 2
  /// Gap between a connector's end and the avatar it points at.
  static let lineGap: CGFloat = 3
  /// Top/bottom padding of a row that neither connects upward nor starts a branch.
  static let rowSpacing: CGFloat = 8
  /// Top padding of a row that connects upward or starts a branch. For a
  /// connected row this is the band the incoming line crosses.
  static let connectedTopSpacing: CGFloat = 12

  static let linearAvatarSize: CGFloat = 48
  static let treeAvatarSize: CGFloat = 28
  /// Horizontal distance from a parent's rail to its child's avatar edge.
  static let elbowRun: CGFloat = 14
  static let indentStep: CGFloat = treeAvatarSize
  static let elbowRadius: CGFloat = 6

  /// Posts shown per linear branch before a "Show more replies" row.
  static let linearBranchPostLimit = 3
  static let compactMaxIndentLevels = 5
  static let regularMaxIndentLevels = 8

  /// `PostView` centres its avatar in a column 6pt wider than the avatar and
  /// pads that column by 3pt, so the avatar sits 6pt in from the view's edge.
  static let postAvatarLeadingInset: CGFloat = 6
  /// `AuthorAvatarColumn` pads its avatar 3pt from the top of `PostView`.
  static let postAvatarTopInset: CGFloat = 3
  /// Distance from an avatar's trailing edge to `PostView`'s text column.
  static let postTextSpacing: CGFloat = 9
  /// Height of the label area in read-more rows.
  static let readMoreHeight: CGFloat = 28

  /// x of the vertical line through every linear-mode avatar.
  static var linearLineX: CGFloat { rowInset + linearAvatarSize / 2 }

  /// Top of the anchor post's avatar inside its cell.
  static let anchorAvatarTop: CGFloat = connectedTopSpacing

  static func maxIndentLevels(isRegularWidth: Bool) -> Int {
    isRegularWidth ? regularMaxIndentLevels : compactMaxIndentLevels
  }

  /// x of the rail drawn beneath the avatar of a tree row at `level`.
  static func railX(level: Int) -> CGFloat {
    rowInset + CGFloat(level) * indentStep + elbowRun
  }
}

// MARK: - Rows

/// One visible item in a thread: a post, a tombstone, or a control row.
///
/// Rows carry their full connector state, so a cell renders from its row
/// alone. `mode` participates in equality so a layout change reconfigures
/// every cell.
struct ThreadRow: Hashable, Sendable, Identifiable {
  enum TombstoneReason: Hashable, Sendable {
    case blocked
    case notFound
    case noUnauthenticated
    case unexpected
  }

  enum Kind: Hashable, Sendable {
    /// Ancestors above the first loaded one exist but were not fetched.
    case readMoreUp
    case ancestor
    case anchor
    case reply
    case tombstone(TombstoneReason)
    /// Replies that are not rendered inline; `target` is the post that shows them.
    case readMore(count: Int, target: ATProtocolURI)
    /// Replies the AppView ranks as low quality, available on request.
    case showOtherReplies
  }

  let id: String
  let kind: Kind
  /// API depth: negative for ancestors, 0 for the anchor, 1+ for replies.
  let depth: Int
  let parentID: String?
  /// Tree: `depth - 1`, bounded by the indent cap (read-more rows sit one
  /// level below their parent). Linear: always 0.
  let indentLevel: Int
  /// Tree: one entry per ancestor level; `true` when that level's rail runs
  /// the full height of this row because a later sibling still hangs off it.
  let continuingRails: [Bool]
  /// A connector enters this row from its parent.
  let lineIn: Bool
  /// A connector leaves this row towards the next row.
  let lineOut: Bool
  let isLastSibling: Bool
  /// First row of a top-level reply branch; drawn with a divider above it.
  let startsBranch: Bool
  let mode: ThreadLayoutMode

  var isPost: Bool {
    switch kind {
    case .ancestor, .anchor, .reply: true
    case .readMoreUp, .tombstone, .readMore, .showOtherReplies: false
    }
  }

  /// Reply-side rows in tree mode use the compact avatar and indentation;
  /// ancestors and the anchor keep the linear geometry in both modes.
  var usesTreeGeometry: Bool {
    guard mode == .tree, depth > 0 else { return false }
    switch kind {
    case .reply, .tombstone, .readMore: return true
    case .readMoreUp, .ancestor, .anchor, .showOtherReplies: return false
    }
  }
}

/// Frames and connector endpoints for one row, derived from its `ThreadRow`.
struct ThreadRowMetrics: Equatable, Sendable {
  let row: ThreadRow

  init(row: ThreadRow) {
    self.row = row
  }

  var topPadding: CGFloat {
    row.lineIn || row.startsBranch
      ? ThreadReplyGeometry.connectedTopSpacing
      : ThreadReplyGeometry.rowSpacing
  }

  var bottomPadding: CGFloat { ThreadReplyGeometry.rowSpacing }

  /// Diameter of the avatar, or height of the box a connector points at in
  /// rows without an avatar.
  var markerSize: CGFloat {
    switch row.kind {
    case .readMore, .readMoreUp, .showOtherReplies:
      ThreadReplyGeometry.readMoreHeight
    case .ancestor, .anchor, .reply, .tombstone:
      row.usesTreeGeometry ? ThreadReplyGeometry.treeAvatarSize : ThreadReplyGeometry.linearAvatarSize
    }
  }

  /// Leading edge of the avatar (or of the label/card in non-post rows).
  var markerLeading: CGFloat {
    if row.usesTreeGeometry {
      return ThreadReplyGeometry.rowInset + CGFloat(row.indentLevel) * ThreadReplyGeometry.indentStep
    }
    switch row.kind {
    case .readMore, .readMoreUp:
      // Linear read-more labels align with the text column of the posts above.
      return ThreadReplyGeometry.rowInset + ThreadReplyGeometry.linearAvatarSize
        + ThreadReplyGeometry.postTextSpacing
    case .ancestor, .anchor, .reply, .tombstone, .showOtherReplies:
      return ThreadReplyGeometry.rowInset
    }
  }

  var markerTop: CGFloat {
    row.isPost ? topPadding + ThreadReplyGeometry.postAvatarTopInset : topPadding
  }

  var markerCenterY: CGFloat { markerTop + markerSize / 2 }

  /// Leading edge of the row's content view. `PostView` insets its own avatar,
  /// so post rows start that much earlier.
  var contentLeading: CGFloat {
    row.isPost ? markerLeading - ThreadReplyGeometry.postAvatarLeadingInset : markerLeading
  }

  /// x of the line that leaves this row towards its children.
  var outgoingLineX: CGFloat {
    row.usesTreeGeometry
      ? ThreadReplyGeometry.railX(level: row.indentLevel)
      : ThreadReplyGeometry.linearLineX
  }

  /// x of the line that enters this row from its parent.
  var incomingLineX: CGFloat {
    row.usesTreeGeometry && row.indentLevel > 0
      ? ThreadReplyGeometry.railX(level: row.indentLevel - 1)
      : ThreadReplyGeometry.linearLineX
  }

  /// Whether the incoming line bends into the marker instead of dropping
  /// straight onto it.
  var incomingLineBends: Bool {
    abs(incomingLineX - (markerLeading + markerSize / 2)) > 0.5
  }

  /// Tombstone cards span the row, so linear lines meet their top edge.
  private var isCardRow: Bool {
    if case .tombstone = row.kind { return true }
    return false
  }

  /// y where the outgoing line starts, given the row's rendered height.
  func outgoingLineStartY(rowHeight: CGFloat) -> CGFloat {
    if isCardRow {
      return rowHeight - bottomPadding + ThreadReplyGeometry.lineGap
    }
    return markerTop + markerSize + ThreadReplyGeometry.lineGap
  }
}
