import SwiftUI

// Only application state is replaced. FontManager, Typography and DesignTokens
// compile directly from the production sources listed in build.sh.
@Observable final class AppSettingsModel {
  var fontStyle = "system"
  var fontSize = "default"
  var lineSpacing = "normal"
  var letterSpacing = "normal"
  var dynamicTypeEnabled = true
  var maxDynamicTypeSize = "accessibility5"
  var boldText = false
  var increaseContrast = false
}

@Observable final class AppState {
  let appSettings = AppSettingsModel()
}

extension Color {
  static var systemBackground: Color { Color(uiColor: .systemBackground) }
  static var systemGroupedBackground: Color { Color(uiColor: .systemGroupedBackground) }

  static func adaptiveForeground(appState: AppState?, defaultColor: Color) -> Color {
    defaultColor
  }
}

extension View {
  func contrastAwareBackground(appState: AppState?, defaultColor: Color) -> some View {
    background(defaultColor)
  }
}
