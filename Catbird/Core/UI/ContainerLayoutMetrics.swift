import SwiftUI

enum ContainerLayoutMetrics {
  static func drawerWidth(availableWidth: CGFloat) -> CGFloat {
    guard availableWidth.isFinite, availableWidth > 0 else { return 0 }
    switch availableWidth {
    case ..<768: return availableWidth
    case ..<1024: return min(420, availableWidth * 0.45)
    case ..<1200: return min(480, availableWidth * 0.4)
    case ..<1600: return min(550, availableWidth * 0.38)
    default: return min(600, availableWidth * 0.32)
    }
  }

  static func bannerHeight(viewportHeight: CGFloat, preferredHeight: CGFloat = 200) -> CGFloat {
    guard viewportHeight.isFinite, viewportHeight > 0 else { return preferredHeight }
    return min(preferredHeight, viewportHeight * 0.25)
  }

  static func externalMediaHeight(viewportHeight: CGFloat) -> CGFloat {
    guard viewportHeight.isFinite, viewportHeight > 0 else { return 500 }
    return min(500, viewportHeight * 0.6)
  }
}

private struct ContainerViewportSizeKey: EnvironmentKey {
  static let defaultValue: CGSize? = nil
}

extension EnvironmentValues {
  var containerViewportSize: CGSize? {
    get { self[ContainerViewportSizeKey.self] }
    set { self[ContainerViewportSizeKey.self] = newValue }
  }
}

#if os(iOS)
import UIKit

/// Reads the window hosting this view, including UIKit-hosted feed cells.
// UIHostingConfiguration does not supply a view-controller hierarchy. A native
// view can read its receiving window in both feed cells and controller hosts.
struct WindowViewportReader: UIViewRepresentable {
  var onChange: (CGSize) -> Void

  func makeUIView(context: Context) -> ViewportView {
    ViewportView(onChange: onChange)
  }

  func updateUIView(_ view: ViewportView, context: Context) {
    view.onChange = onChange
    view.publishViewportSize()
  }

  final class ViewportView: UIView {
    var onChange: (CGSize) -> Void
    private var lastSize: CGSize?

    init(onChange: @escaping (CGSize) -> Void) {
      self.onChange = onChange
      super.init(frame: .zero)
      backgroundColor = .clear
      isOpaque = false
      isUserInteractionEnabled = false
      isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { return nil }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      lastSize = nil
      publishViewportSize()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      publishViewportSize()
    }

    override func safeAreaInsetsDidChange() {
      super.safeAreaInsetsDidChange()
      publishViewportSize()
    }

    func publishViewportSize() {
      guard let receivingWindow = window else { return }
      let size = receivingWindow.bounds.size
      guard
        size.width.isFinite, size.height.isFinite,
        size.width > 0, size.height > 0, size != lastSize else { return }
      lastSize = size
      DispatchQueue.main.async { [weak self, weak receivingWindow] in
        guard let self, let receivingWindow, self.window === receivingWindow,
          receivingWindow.bounds.size == size, self.lastSize == size else { return }
        self.onChange(size)
      }
    }
  }
}
#endif
