//
//  CatbirdUITests.swift
//  CatbirdUITests
//
//  Created by Josh LaCalamito on 2/14/25.
//

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