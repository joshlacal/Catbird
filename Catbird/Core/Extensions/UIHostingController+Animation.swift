import SwiftUI
import UIKit

extension UIHostingController {
  // Static method to disable animations globally during critical updates
  static func swizzleViewWillTransition() {
    UIView.setAnimationsEnabled(false)
    SwiftUI.withTransaction(SwiftUI.Transaction(animation: .none)) {
      // This is a dummy transaction to disable any SwiftUI animations
    }
  }

  // Restore animations after update
  static func restoreAnimations() {
    UIView.setAnimationsEnabled(true)
  }
}
