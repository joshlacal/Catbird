import Foundation

enum SettingsAccountSwitchError: LocalizedError {
  case localSaveRefused(String)
  var errorDescription: String? {
    switch self {
    case .localSaveRefused(let reason): reason
    }
  }
}
