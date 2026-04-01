//
//  RefreshWidgetIntent.swift
//  CatbirdFeedWidget
//

#if os(iOS)
import AppIntents
import WidgetKit

@available(iOS 17.0, *)
struct RefreshFeedWidgetIntent: AppIntent {
  static var title: LocalizedStringResource = "Refresh Feed"

  func perform() async throws -> some IntentResult {
    WidgetCenter.shared.reloadTimelines(ofKind: "CatbirdFeedWidget")
    return .result()
  }
}
#endif
