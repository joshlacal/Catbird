import SwiftUI

// MARK: - Custom Message Menu Action

/// Menu actions available for chat messages
enum CustomMessageMenuAction: String, CaseIterable {
  case copy
  case deleteForMe
  case report

  var title: String {
    switch self {
    case .copy:
      return String(localized: "Copy", comment: "Context menu action to copy message text")
    case .deleteForMe:
      return String(localized: "Delete for me", comment: "Context menu action to delete a message locally")
    case .report:
      return String(localized: "Report", comment: "Context menu action to report a message")
    }
  }

  var icon: Image {
    switch self {
    case .copy:
      return Image(systemName: "doc.on.doc")
    case .deleteForMe:
      return Image(systemName: "trash")
    case .report:
      return Image(systemName: "exclamationmark.triangle")
    }
  }
}
