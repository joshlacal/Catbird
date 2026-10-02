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
      return "Copy"
    case .deleteForMe:
      return "Delete for me"
    case .report:
      return "Report"
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
