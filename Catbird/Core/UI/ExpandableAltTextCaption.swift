import SwiftUI

// MARK: - ExpandableAltTextCaption

/// Alt text caption shown over full-screen image viewers.
///
/// Collapses to `collapsedLineLimit` lines and offers "Show More" only when the text
/// doesn't fit within that limit. Truncation is measured against the caption's actual
/// width and font, so it re-evaluates on rotation, window resizing and Dynamic Type changes.
struct ExpandableAltTextCaption: View {
  let text: String
  @Binding var isExpanded: Bool
  var collapsedLineLimit: Int = 2
  var alignment: Alignment = .center

  @State private var collapsedHeight: CGFloat = 0
  @State private var fullHeight: CGFloat = 0

  /// Whether the full text needs more lines than the collapsed limit allows.
  private var isTruncatable: Bool {
    fullHeight > collapsedHeight + 1
  }

  private var canToggle: Bool {
    isExpanded || isTruncatable
  }

  var body: some View {
    VStack(spacing: 4) {
      Text(text)
        .appFont(AppTextRole.caption)
        .lineLimit(isExpanded ? nil : collapsedLineLimit)
        .multilineTextAlignment(.leading)
        .background { truncationProbe }

      if !isExpanded && isTruncatable {
        Button(action: expand) {
          Text("Show More")
            .appFont(AppTextRole.caption2)
            .foregroundColor(Color.accentColor)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Show more alt text")
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: alignment)
    .background(Material.ultraThin)
    .cornerRadius(10)
    .padding(.horizontal)
    .accessibilityElement(children: isExpanded ? .contain : .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(text)
    .accessibilityAddTraits(canToggle ? .isButton : [])
    .accessibilityHint(accessibilityHint)
    .onTapGesture {
      guard canToggle else { return }
      withAnimation(.easeInOut(duration: 0.2)) {
        isExpanded.toggle()
      }
    }
  }

  // MARK: - Truncation Measurement

  /// Invisible copies of the caption, laid out at the visible text's width: one capped at the
  /// collapsed line limit and one unlimited. A taller unlimited copy means the text is truncated.
  private var truncationProbe: some View {
    ZStack {
      Text(text)
        .appFont(AppTextRole.caption)
        .lineLimit(collapsedLineLimit)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.size.height
        } action: { height in
          collapsedHeight = height
        }

      Text(text)
        .appFont(AppTextRole.caption)
        .lineLimit(nil)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.size.height
        } action: { height in
          fullHeight = height
        }
    }
    .opacity(0)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  // MARK: - Actions

  private func expand() {
    withAnimation(.easeInOut(duration: 0.2)) {
      isExpanded = true
    }
  }

  // MARK: - Accessibility

  private var accessibilityLabel: String {
    if isExpanded || !isTruncatable {
      return "Alt text"
    }
    return "Alt text (collapsed)"
  }

  private var accessibilityHint: String {
    guard canToggle else { return "" }
    return isExpanded ? "Double tap to collapse" : "Double tap to expand"
  }
}
