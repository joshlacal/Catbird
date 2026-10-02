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
struct WindowViewportReader: UIViewControllerRepresentable {
  var onChange: (CGSize) -> Void

  func makeUIViewController(context: Context) -> ViewportController {
    ViewportController(onChange: onChange)
  }

  func updateUIViewController(_ controller: ViewportController, context: Context) {
    controller.viewportView.onChange = onChange
    controller.viewportView.publishViewportSize()
  }

  final class ViewportController: UIViewController {
    let viewportView: ViewportView

    init(onChange: @escaping (CGSize) -> Void) {
      viewportView = ViewportView(onChange: onChange)
      super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func loadView() { view = viewportView }

    override func viewWillLayoutSubviews() {
      super.viewWillLayoutSubviews()
      viewportView.publishViewportSize()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
      super.viewWillTransition(to: size, with: coordinator)
      coordinator.animate(alongsideTransition: nil) { [weak self] _ in
        self?.viewportView.publishViewportSize()
      }
    }
  }

  final class ViewportView: UIView {
    var onChange: (CGSize) -> Void
    private var lastSize: CGSize?

    init(onChange: @escaping (CGSize) -> Void) {
      self.onChange = onChange
      super.init(frame: .zero)
      isUserInteractionEnabled = false
      isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { return nil }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      publishViewportSize()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      publishViewportSize()
    }

    func publishViewportSize() {
      guard let size = window?.bounds.size,
        size.width.isFinite, size.height.isFinite,
        size.width > 0, size.height > 0, size != lastSize else { return }
      lastSize = size
      DispatchQueue.main.async { [weak self] in
        guard let self, let currentSize = self.window?.bounds.size,
          currentSize == self.lastSize else { return }
        self.onChange(currentSize)
      }
    }
  }
}
#endif
