import Foundation

/// The model each account chose for Ask Catbird. On Device is the default and
/// the stored choice applies only to the account that made it.
struct CopilotRoutePreference {
  private let defaults: UserDefaults
  private static let keyPrefix = "askCatbird.modelRoute."

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func route(for accountDID: String) -> CopilotModelRoute {
    guard !accountDID.isEmpty,
          let raw = defaults.string(forKey: Self.keyPrefix + accountDID),
          let route = CopilotModelRoute(rawValue: raw) else { return .onDevice }
    return route
  }

  func setRoute(_ route: CopilotModelRoute, for accountDID: String) {
    guard !accountDID.isEmpty else { return }
    if route == .onDevice {
      defaults.removeObject(forKey: Self.keyPrefix + accountDID)
    } else {
      defaults.set(route.rawValue, forKey: Self.keyPrefix + accountDID)
    }
  }
}
