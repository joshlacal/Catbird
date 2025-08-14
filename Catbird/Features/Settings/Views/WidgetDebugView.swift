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

      Section("Feed Widget Debug") {
        Button("Test Feed Widget Data") {
          testFeedWidgetData()
        }
        
        Button("Check Feed Widget Data") {
          checkFeedWidgetData()
        }
        
        Button("Clear Feed Widget Data") {
          FeedWidgetDataProvider.shared.clearWidgetData()
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
    .toolbarTitleDisplayMode(.inline)
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

  // Test feed widget data creation and saving
  private func testFeedWidgetData() {
    // Create some test posts
    let testPosts = [
      WidgetPost(
        id: "test1",
        authorName: "Test User",
        authorHandle: "@test.bsky.social",
        authorAvatarURL: nil,
        text: "This is a test post for widget debugging!",
        timestamp: Date(),
        likeCount: 42,
        repostCount: 5,
        replyCount: 3,
        imageURLs: [],
        isRepost: false,
        repostAuthorName: nil
      ),
      WidgetPost(
        id: "test2",
        authorName: "Debug Bot",
        authorHandle: "@debug.bsky.social",
        authorAvatarURL: nil,
        text: "Widget debugging in progress... 🔧",
        timestamp: Date().addingTimeInterval(-3600),
        likeCount: 21,
        repostCount: 2,
        replyCount: 1,
        imageURLs: [],
        isRepost: false,
        repostAuthorName: nil
      )
    ]
    
    let testData = FeedWidgetDataEnhanced(
      posts: testPosts,
      feedType: "timeline",
      lastUpdated: Date(),
      profileHandle: nil,
      totalPostCount: testPosts.count
    )
    
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let encoded = try encoder.encode(testData)
      let defaults = UserDefaults(suiteName: "group.blue.catbird.shared")
      defaults?.set(encoded, forKey: "feedWidgetData")
      defaults?.synchronize()
      
      logger.info("✅ Successfully wrote test feed widget data with \(testPosts.count) posts")
      
      // Force reload
      WidgetCenter.shared.reloadTimelines(ofKind: "CatbirdFeedWidget")
    } catch {
      logger.error("❌ Failed to encode feed widget data: \(error.localizedDescription)")
    }
  }
  
  // Check current feed widget data
  private func checkFeedWidgetData() {
    let defaults = UserDefaults(suiteName: "group.blue.catbird.shared")
    
    if let data = defaults?.data(forKey: "feedWidgetData") {
      do {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        if let enhancedData = try? decoder.decode(FeedWidgetDataEnhanced.self, from: data) {
          logger.info("✅ Found enhanced feed widget data: \(enhancedData.posts.count) posts, feedType: \(enhancedData.feedType), updated: \(enhancedData.lastUpdated)")
        } else if let basicData = try? decoder.decode(FeedWidgetData.self, from: data) {
          logger.info("✅ Found basic feed widget data: \(basicData.posts.count) posts, feedType: \(basicData.feedType), updated: \(basicData.lastUpdated)")
        } else {
          logger.error("❌ Found widget data but unable to decode it")
        }
      } catch {
        logger.error("❌ Error checking feed widget data: \(error.localizedDescription)")
      }
    } else {
      logger.info("ℹ️ No feed widget data found")
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
