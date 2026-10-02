import Foundation

@MainActor
enum WorkingDraftStashPolicy {
  enum Result: Equatable {
    case noWorkingDraft
    case destinationUnavailable
    case saveFailed
    case stashed

    var allowsTransition: Bool {
      self == .noWorkingDraft || self == .stashed
    }
  }

  static func perform(
    hasWorkingDraft: Bool,
    destinationAvailable: Bool,
    save: () async -> Bool,
    clearAfterSave: () -> Void
  ) async -> Result {
    guard destinationAvailable else { return .destinationUnavailable }
    guard hasWorkingDraft else { return .noWorkingDraft }
    guard await save() else { return .saveFailed }
    clearAfterSave()
    return .stashed
  }
}
