////
////  CatbirdUITests.swift
////  CatbirdUITests
////
////  Created by Josh LaCalamito on 2/14/25.
////
//
//import MachO
//import FaultOrderingTests
//import XCTest
//
//final class CatbirdUITests: XCTestCase {
//    
//    override func setUpWithError() throws {
//        continueAfterFailure = false
//    }
//    
//    func testLaunchPerformance() throws {
//        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
//            measure(metrics: [XCTApplicationLaunchMetric()]) {
//                XCUIApplication().launch()
//            }
//        }
//    }
//}
//
//// MARK: - FaultOrdering Tests
//
//final class FaultOrderingLaunchTest: XCTestCase {
//    
//    @MainActor
//    func testLaunchWithFaultOrdering() throws {
//        logger.debug("🚀 Starting FaultOrdering test")
//        
//        let app = XCUIApplication()
//        
//        let test = FaultOrderingTest { app in
//            logger.debug("📱 Setting up app for FaultOrdering measurement")
//            
//            // Wait for app to stabilize
//            sleep(5)
//            
//            // Find main UI elements and keep app active
//            let collectionView = app.collectionViews.firstMatch
//            if collectionView.waitForExistence(timeout: 15) {
//                logger.debug("✅ Found collection view, starting interaction sequence")
//                
//                // Keep app active with realistic user interactions
//                for i in 0..<30 {
//                    // Scroll through feed
//                    collectionView.swipeUp(velocity: .slow)
//                    sleep(1)
//                    
//                    // Occasional taps to simulate user engagement
//                    if i % 5 == 0 {
//                        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
//                        logger.debug("⏳ Keeping app active: \(i)/30")
//                    }
//                    
//                    // Navigate between tabs periodically
//                    if i % 10 == 0 && i > 0 {
//                        let tabBar = app.tabBars.firstMatch
//                        if tabBar.exists {
//                            let buttons = tabBar.buttons
//                            if buttons.count > 1 {
//                                // Tap second tab
//                                buttons.element(boundBy: 1).tap()
//                                sleep(1)
//                                // Return to first tab
//                                buttons.element(boundBy: 0).tap()
//                                sleep(1)
//                            }
//                        }
//                    }
//                }
//            } else {
//                logger.debug("⚠️ Collection view not found, using fallback interactions")
//                // Fallback: generic screen taps
//                for i in 0..<20 {
//                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
//                    sleep(2)
//                    if i % 5 == 0 {
//                        logger.debug("⏳ Fallback interactions: \(i)/20")
//                    }
//                }
//            }
//            
//            logger.debug("✅ Completed interaction sequence")
//        }
//        
//        test.testApp(testCase: self, app: app)
//    }
//    
//    @MainActor
//    func testBasicAppLaunch() throws {
//        logger.debug("📱 Testing basic app launch without FaultOrdering")
//        
//        let app = XCUIApplication()
//        
//        // Launch without FaultOrdering to verify app stability
//        app.launchEnvironment = ["DISABLE_FAULT_ORDERING": "1"]
//        app.launch()
//        
//        // Verify app launches successfully
//        sleep(5)
//        XCTAssertEqual(app.state, .runningForeground, "App should launch successfully")
//        
//        // Basic interaction test
//        let collectionView = app.collectionViews.firstMatch
//        if collectionView.waitForExistence(timeout: 10) {
//            collectionView.swipeUp()
//            logger.debug("✅ Basic app functionality verified")
//        }
//        
//        app.terminate()
//    }
//    
//    @MainActor
//    func testFaultOrderingConfiguration() throws {
//        logger.debug("🔧 Testing FaultOrdering configuration")
//        
//        // Verify dylib can be found
//        if let dylibPath = getDylibPath(dylibName: "FaultOrdering") {
//            logger.debug("✅ FaultOrdering dylib found at: \(dylibPath)")
//        } else {
//            logger.debug("⚠️ FaultOrdering dylib not found - may need to be linked to app target")
//        }
//        
//        let app = XCUIApplication()
//        
//        // Test with explicit environment setup
//        var launchEnvironment = app.launchEnvironment
//        launchEnvironment["DEBUG_FAULT_ORDERING"] = "1"
//        if let dylibPath = getDylibPath(dylibName: "FaultOrdering") {
//            launchEnvironment["DYLD_INSERT_LIBRARIES"] = dylibPath
//        }
//        app.launchEnvironment = launchEnvironment
//        
//        app.launch()
//        sleep(3)
//        
//        XCTAssertEqual(app.state, .runningForeground, "App should launch with FaultOrdering environment")
//        
//        app.terminate()
//        logger.debug("✅ FaultOrdering configuration test completed")
//    }
//    
//    // Helper function to find dylib
//    private func getDylibPath(dylibName: String) -> String? {
//        let count = _dyld_image_count()
//        for i in 0..<count {
//            if let imagePath = _dyld_get_image_name(i) {
//                let imagePathStr = String(cString: imagePath)
//                if (imagePathStr as NSString).lastPathComponent == dylibName {
//                    return imagePathStr
//                }
//            }
//        }
//        return nil
//    }
//    
//    // Run tests in a specific order for better reliability
//    override class var defaultTestSuite: XCTestSuite {
//        let suite = XCTestSuite(forTestCaseClass: self)
//        
//        // Start with basic tests, then move to FaultOrdering
//        suite.addTest(FaultOrderingLaunchTest(selector: #selector(testBasicAppLaunch)))
//        suite.addTest(FaultOrderingLaunchTest(selector: #selector(testFaultOrderingConfiguration)))
//        suite.addTest(FaultOrderingLaunchTest(selector: #selector(testLaunchWithFaultOrdering)))
//        
//        return suite
//    }
//}



//
//  CatbirdUITests.swift
//  CatbirdUITests
//
//  Created by Josh LaCalamito on 2/14/25.
//

import MachO
import FaultOrderingTests
import XCTest

final class CatbirdUITests: XCTestCase {
    
    override func setUpWithError() throws {
        continueAfterFailure = false
    }
    
    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }
}

// MARK: - FaultOrdering Tests

final class FaultOrderingLaunchTest: XCTestCase {
    
    @MainActor
    func testLaunchWithFaultOrdering() throws {
        logger.debug("🚀 Starting FaultOrdering test")
        
        // Wait a bit to ensure any previous server is closed
        sleep(2)
        
        let app = XCUIApplication()
        
        let test = FaultOrderingTest { app in
            logger.debug("📱 Setting up app for FaultOrdering measurement")
            
            // Wait for app to stabilize
            sleep(5)
            /*
            // Find main UI elements and keep app active
            let collectionView = app.collectionViews.firstMatch
            if collectionView.waitForExistence(timeout: 15) {
                logger.debug("✅ Found collection view, starting interaction sequence")
                
                // Keep app active with realistic user interactions
                for i in 0..<30 {
                    // Scroll through feed
                    collectionView.swipeUp(velocity: .slow)
                    sleep(1)
                    
                    // Occasional taps to simulate user engagement
                    if i % 5 == 0 {
                        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                        logger.debug("⏳ Keeping app active: \(i)/30")
                    }
                    
                    // Navigate between tabs periodically
                    if i % 10 == 0 && i > 0 {
                        let tabBar = app.tabBars.firstMatch
                        if tabBar.exists {
                            let buttons = tabBar.buttons
                            if buttons.count > 1 {
                                // Tap second tab
                                buttons.element(boundBy: 1).tap()
                                sleep(1)
                                // Return to first tab
                                buttons.element(boundBy: 0).tap()
                                sleep(1)
                            }
                        }
                    }
                }
            } else {
                logger.debug("⚠️ Collection view not found, using fallback interactions")
                // Fallback: generic screen taps
                for i in 0..<20 {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                    sleep(2)
                    if i % 5 == 0 {
                        logger.debug("⏳ Fallback interactions: \(i)/20")
                    }
                }
            }
            */
            
            app.launch()
            logger.debug("✅ Completed interaction sequence")
        }
        
        test.testApp(testCase: self, app: app)
    }
    
    @MainActor
    func testBasicAppLaunch() throws {
        logger.debug("📱 Testing basic app launch without FaultOrdering")
        
        let app = XCUIApplication()
        
        // Launch without FaultOrdering to verify app stability
        app.launchEnvironment = ["DISABLE_FAULT_ORDERING": "1"]
        app.launch()
        
        // Verify app launches successfully
        sleep(5)
        XCTAssertEqual(app.state, .runningForeground, "App should launch successfully")
        
        // Basic interaction test
        let collectionView = app.collectionViews.firstMatch
        if collectionView.waitForExistence(timeout: 10) {
            collectionView.swipeUp()
            logger.debug("✅ Basic app functionality verified")
        }
        
        app.terminate()
    }
    
    @MainActor
    func testFaultOrderingConfiguration() throws {
        logger.debug("🔧 Testing FaultOrdering configuration")
        
        // Verify dylib can be found
        if let dylibPath = getDylibPath(dylibName: "FaultOrdering") {
            logger.debug("✅ FaultOrdering dylib found at: \(dylibPath)")
        } else {
            logger.debug("⚠️ FaultOrdering dylib not found - may need to be linked to app target")
        }
        
        let app = XCUIApplication()
        
        // Test with explicit environment setup
        var launchEnvironment = app.launchEnvironment
        launchEnvironment["DEBUG_FAULT_ORDERING"] = "1"
        if let dylibPath = getDylibPath(dylibName: "FaultOrdering") {
            launchEnvironment["DYLD_INSERT_LIBRARIES"] = dylibPath
        }
        app.launchEnvironment = launchEnvironment
        
        app.launch()
        sleep(3)
        
        XCTAssertEqual(app.state, .runningForeground, "App should launch with FaultOrdering environment")
        
        app.terminate()
        logger.debug("✅ FaultOrdering configuration test completed")
    }
    
    // Helper function to find dylib
    private func getDylibPath(dylibName: String) -> String? {
        let count = _dyld_image_count()
        for i in 0..<count {
            if let imagePath = _dyld_get_image_name(i) {
                let imagePathStr = String(cString: imagePath)
                if (imagePathStr as NSString).lastPathComponent == dylibName {
                    return imagePathStr
                }
            }
        }
        return nil
    }
    
    // Run tests in a specific order for better reliability
    override class var defaultTestSuite: XCTestSuite {
        let suite = XCTestSuite(forTestCaseClass: self)
        
        // Start with basic tests, then move to FaultOrdering
        suite.addTest(FaultOrderingLaunchTest(selector: #selector(testBasicAppLaunch)))
        suite.addTest(FaultOrderingLaunchTest(selector: #selector(testFaultOrderingConfiguration)))
        suite.addTest(FaultOrderingLaunchTest(selector: #selector(testLaunchWithFaultOrdering)))
        
        return suite
    }
}
