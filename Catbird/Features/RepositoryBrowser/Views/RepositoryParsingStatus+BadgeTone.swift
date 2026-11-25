//
//  RepositoryParsingStatus+BadgeTone.swift
//  Catbird
//
//  Shared status -> CatbirdBadge tone mapping for the Repository Browser.
//

import SwiftUI

extension RepositoryParsingStatus {
  /// Badge tone for this parsing status (cancelled keeps its previous "warning" meaning).
  var badgeTone: CatbirdBadgeTone {
    switch self {
    case .notStarted:
      return .neutral
    case .inProgress:
      return .accent
    case .completed:
      return .success
    case .partiallyCompleted, .cancelled:
      return .warning
    case .failed:
      return .danger
    }
  }
}
