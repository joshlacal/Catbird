//
//  DateManagerTests.swift
//  CatbirdTests
//
//  Tests for shortTimeAgoString and formatTimeAgo relative date formatting.
//

import Foundation
import Testing
@testable import Catbird

@Suite("DateManager relative time formatting", .serialized)
struct DateManagerTests {
    @Test("shortTimeAgoString formats relative buckets correctly")
    func shortTimeAgoBuckets() {
        let calendar = Calendar.current
        let now = Date()

        // Just now (0 seconds)
        #expect(shortTimeAgoString(from: now) == "now")

        // 5 minutes ago
        if let fiveMinutesAgo = calendar.date(byAdding: .minute, value: -5, to: now) {
            #expect(shortTimeAgoString(from: fiveMinutesAgo) == "5m")
        }

        // 3 hours ago
        if let threeHoursAgo = calendar.date(byAdding: .hour, value: -3, to: now) {
            #expect(shortTimeAgoString(from: threeHoursAgo) == "3h")
        }

        // 2 days ago
        if let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: now) {
            #expect(shortTimeAgoString(from: twoDaysAgo) == "2d")
        }

        // 2 months ago
        if let twoMonthsAgo = calendar.date(byAdding: .month, value: -2, to: now) {
            #expect(shortTimeAgoString(from: twoMonthsAgo) == "2mo")
        }

        // 1 year ago
        if let oneYearAgo = calendar.date(byAdding: .year, value: -1, to: now) {
            #expect(shortTimeAgoString(from: oneYearAgo) == "1y")
        }
    }

    @Test("formatTimeAgo respects forAccessibility flag")
    func formatTimeAgoAccessibility() {
        let calendar = Calendar.current
        let now = Date()

        if let twoHoursAgo = calendar.date(byAdding: .hour, value: -2, to: now) {
            let compact = formatTimeAgo(from: twoHoursAgo, forAccessibility: false)
            #expect(compact == "2h")

            let accessible = formatTimeAgo(from: twoHoursAgo, forAccessibility: true)
            #expect(!accessible.isEmpty)
            #expect(accessible != compact)
        }
    }
}
