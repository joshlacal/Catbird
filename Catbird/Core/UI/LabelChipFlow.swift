import SwiftUI

// MARK: - Flow Layout

/// Places label chips left to right and wraps them onto new rows, so many
/// labels (for example from several novelty labelers) stay compact.
struct LabelChipFlowLayout: Layout {
  var horizontalSpacing: CGFloat = 6
  var verticalSpacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(subviews: subviews, maxWidth: proposal.width ?? .infinity)
    let width = rows.map(\.width).max() ?? 0
    let height = rows.reduce(0) { $0 + $1.height } + verticalSpacing * CGFloat(max(rows.count - 1, 0))
    return CGSize(width: proposal.width.map { min(width, $0) } ?? width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in arrange(subviews: subviews, maxWidth: bounds.width) {
      var x = bounds.minX
      for item in row.items {
        subviews[item.index].place(
          at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
          proposal: ProposedViewSize(item.size)
        )
        x += item.size.width + horizontalSpacing
      }
      y += row.height + verticalSpacing
    }
  }

  private struct Row {
    var items: [(index: Int, size: CGSize)] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
    var rows: [Row] = []
    var current = Row()
    for index in subviews.indices {
      // A chip never exceeds the row; long names truncate inside the chip.
      var size = subviews[index].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
      size.width = min(size.width, maxWidth)
      let needed = current.items.isEmpty ? size.width : current.width + horizontalSpacing + size.width
      if needed > maxWidth, !current.items.isEmpty {
        rows.append(current)
        current = Row()
      }
      current.width = current.items.isEmpty ? size.width : current.width + horizontalSpacing + size.width
      current.height = max(current.height, size.height)
      current.items.append((index, size))
    }
    if !current.items.isEmpty { rows.append(current) }
    return rows
  }
}

// MARK: - Chip

/// One label as a compact capsule.
struct LabelChip: View {
  let title: String
  var systemImage: String? = nil
  var tint: Color = .secondary

  var body: some View {
    HStack(spacing: 4) {
      if let systemImage {
        Image(systemName: systemImage)
          .imageScale(.small)
          .accessibilityHidden(true)
      }
      Text(title)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .appFont(AppTextRole.caption)
    .foregroundStyle(tint)
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(Capsule().fill(tint.opacity(0.12)))
    .overlay(Capsule().strokeBorder(tint.opacity(0.18), lineWidth: 0.5))
  }
}
