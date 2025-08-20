import SwiftUI
#if os(iOS)
import ExyteChat

// MARK: - Custom Message Menu Action

enum CustomMessageMenuAction: String, CaseIterable, MessageMenuAction {
  case copy
//  case reply
  case deleteForMe
  case report
  
    func title() -> String {
    switch self {
    case .copy:
      return "Copy"
//    case .reply:
//      return "Reply"
    case .deleteForMe:
      return "Delete for me"
    case .report:
      return "Report"
    }
  }
  
    func icon() -> Image {
    switch self {
    case .copy:
      return Image(systemName: "doc.on.doc")
//    case .reply:
//      return Image(systemName: "arrowshape.turn.up.left")
    case .deleteForMe:
      return Image(systemName: "trash")
    case .report:
      return Image(systemName: "exclamationmark.triangle")
    }
  }
}

#else

// macOS stub for CustomMessageMenuAction
enum CustomMessageMenuAction: String, CaseIterable {
  case copy
  case deleteForMe
  case report
  
  func title() -> String {
    switch self {
    case .copy:
      return "Copy"
    case .deleteForMe:
      return "Delete for me"
    case .report:
      return "Report"
    }
  }
  
  func icon() -> Image {
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

#endif