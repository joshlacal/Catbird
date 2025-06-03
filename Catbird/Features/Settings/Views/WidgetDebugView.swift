import OSLog
import SwiftUI
import WidgetKit

/// A view to help debug widget data issues
struct WidgetDebugView: View {
  @Environment(AppState.self) private var appState
  @State private var testCount = 42

  private let logger = Logger(subsystem: "blue.catbird", category: "WidgetDebug")

  var body: some View {
    Form {
      Section("Debug Widget Data") {
        Stepper("Test Count: \(testCount)", value: $testCount, in: 0...999)

        Button("Update Widget") {
          appState.notificationManager.testUpdateWidget(count: testCount)
        }

        Button("Reset Widget") {
          appState.notificationManager.updateWidgetUnreadCount(testCount)
        }

        Button("Force Reload All Widgets") {
          forceReloadWidgets()
        }
      }

      Section("Diagnostics") {
        Button("Check App Group Access") {
          checkAppGroup()
        }

        Button("Write Test Data Directly") {
          writeDirectTestData()
        }
      }
    }
    .navigationTitle("Widget Debugger")
    .navigationBarTitleDisplayMode(.inline)
  }

  // Force reload all widgets
  private func forceReloadWidgets() {
    WidgetCenter.shared.reloadAllTimelines()
    logger.info("📱 Force reloaded all widget timelines")
  }

  // Check app group access
  private func checkAppGroup() {
    let defaults = UserDefaults(suiteName: "group.blue.catbird.shared")
    if defaults != nil {
      logger.info("✅ Successfully accessed App Group UserDefaults")

      // Try to write and read a test value
      defaults?.set("test_value", forKey: "widget_debug_test")
      if let value = defaults?.string(forKey: "widget_debug_test") {
        logger.info("✅ Successfully wrote and read test value: \(value)")
      } else {
        logger.error("❌ Failed to read test value from App Group")
      }
    } else {
      logger.error("❌ Failed to access App Group UserDefaults")
    }
  }

  // Write test data directly to shared defaults
  private func writeDirectTestData() {
    let widgetData = NotificationWidgetData(count: testCount, lastUpdated: Date())

    do {
      let encoded = try JSONEncoder().encode(widgetData)
      let defaults = UserDefaults(suiteName: "group.blue.catbird.shared")
      defaults?.set(encoded, forKey: "notificationWidgetData")
      defaults?.synchronize()  // Force immediate write
      logger.info("✅ Successfully wrote direct test data with count=\(testCount)")

      // Force reload
      WidgetCenter.shared.reloadTimelines(ofKind: "CatbirdNotificationWidget")
    } catch {
      logger.error("❌ Failed to encode widget data: \(error.localizedDescription)")
    }
  }
}

// Add for preview
#Preview {
  WidgetDebugView()
    .environment(AppState.shared)
}
