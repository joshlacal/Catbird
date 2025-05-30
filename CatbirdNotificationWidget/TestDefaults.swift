import Foundation
import WidgetKit

/// Utility for testing the widget's shared UserDefaults
struct TestDefaults {
    /// Manually writes test data to the shared UserDefaults
    static func writeTestData(count: Int) {
        // Create test widget data
        let testData = NotificationWidgetData(count: count, lastUpdated: Date())
        
        // Encode to JSON
        guard let data = try? JSONEncoder().encode(testData) else {
            logger.debug("Failed to encode test widget data")
            return
        }
        
        // Get shared UserDefaults
        if let defaults = UserDefaults(suiteName: "group.blue.catbird.shared") {
            // Write data
            defaults.set(data, forKey: "notificationWidgetData")
            defaults.synchronize()
            logger.debug("✅ Successfully wrote test data to shared UserDefaults: count=\(count)")
            
            // Verify the data was written
            if let savedData = defaults.data(forKey: "notificationWidgetData"),
               let decodedData = try? JSONDecoder().decode(NotificationWidgetData.self, from: savedData) {
                logger.debug("✅ Verification successful: count=\(decodedData.count), lastUpdated=\(decodedData.lastUpdated)")
            } else {
                logger.debug("❌ Failed to verify test data in shared UserDefaults")
            }
        } else {
            logger.debug("❌ Failed to access shared UserDefaults")
        }
        
        // Reload widget timelines
        WidgetCenter.shared.reloadAllTimelines()
        logger.debug("🔄 Requested widget refresh")
    }
    
    /// Reads and logger.debugs the current shared UserDefaults
    static func readTestData() {
        if let defaults = UserDefaults(suiteName: "group.blue.catbird.shared") {
            if let data = defaults.data(forKey: "notificationWidgetData") {
                do {
                    let widgetData = try JSONDecoder().decode(NotificationWidgetData.self, from: data)
                    logger.debug("📊 Current widget data: count=\(widgetData.count), lastUpdated=\(widgetData.lastUpdated)")
                } catch {
                    logger.debug("❌ Failed to decode data from shared UserDefaults: \(error.localizedDescription)")
                }
            } else {
                logger.debug("⚠️ No notification data found in shared UserDefaults")
            }
        } else {
            logger.debug("❌ Failed to access shared UserDefaults")
        }
    }
    
    /// Manually set a specific value
    static func forceValue(count: Int) {
        let testData = NotificationWidgetData(count: count, lastUpdated: Date())
        
        if let data = try? JSONEncoder().encode(testData) {
            UserDefaults(suiteName: "group.blue.catbird.shared")?.set(data, forKey: "notificationWidgetData")
            UserDefaults(suiteName: "group.blue.catbird.shared")?.synchronize()
            
            let sharedDefaults = UserDefaults(suiteName: "group.blue.catbird.shared")
            sharedDefaults?.set(data, forKey: "notificationWidgetData")
            sharedDefaults?.synchronize()
            
            logger.debug("🔧 Force-set notification count to \(count) in both standard and shared UserDefaults")
            
            // Reload widget
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
