//
//  NewskieBadgeTests.swift
//  CatbirdTests
//
//  Tests for Newskie badge eligibility and dialog copy (WS-H / G61).
//

import Testing
import Foundation
@testable import Catbird

@Suite("NewskieBadge")
struct NewskieBadgeTests {
    private let now = Date(timeIntervalSince1970: 1700000000) // Reference fixed date
    
    // MARK: - Eligibility Boundary Tests
    
    @Test("Account created right now is eligible")
    func testNewAccountEligible() {
        let createdAt = now
        #expect(NewskieHelper.isNewskie(createdAt: createdAt, referenceDate: now) == true)
    }
    
    @Test("Account created 3 days ago is eligible")
    func testThreeDayAccountEligible() {
        let createdAt = now.addingTimeInterval(-3 * 24 * 60 * 60)
        #expect(NewskieHelper.isNewskie(createdAt: createdAt, referenceDate: now) == true)
    }
    
    @Test("Account created exactly 7 days ago is eligible at the boundary")
    func testExactlySevenDaysEligible() {
        let createdAt = now.addingTimeInterval(-7 * 24 * 60 * 60)
        #expect(NewskieHelper.isNewskie(createdAt: createdAt, referenceDate: now) == true)
    }
    
    @Test("Account created 7 days and 1 second ago is ineligible")
    func testSevenDaysPlusOneSecondIneligible() {
        let createdAt = now.addingTimeInterval(-(7 * 24 * 60 * 60 + 1))
        #expect(NewskieHelper.isNewskie(createdAt: createdAt, referenceDate: now) == false)
    }
    
    @Test("Account created 30 days ago is ineligible")
    func testOldAccountIneligible() {
        let createdAt = now.addingTimeInterval(-30 * 24 * 60 * 60)
        #expect(NewskieHelper.isNewskie(createdAt: createdAt, referenceDate: now) == false)
    }
    
    @Test("Future creation date is ineligible")
    func testFutureAccountIneligible() {
        let createdAt = now.addingTimeInterval(3600)
        #expect(NewskieHelper.isNewskie(createdAt: createdAt, referenceDate: now) == false)
    }
    
    @Test("Nil creation date is ineligible")
    func testNilDateIneligible() {
        #expect(NewskieHelper.isNewskie(createdAt: nil, referenceDate: now) == false)
    }
    
    // MARK: - Dialog Copy Tests
    
    @Test("Generates first-person copy without starter pack")
    func testFirstPersonWithoutStarterPack() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let message = NewskieHelper.dialogMessage(
            handle: "myuser.bsky.social",
            isSelf: true,
            createdAt: date,
            hasStarterPack: false
        )
        #expect(message.contains("You joined Bluesky"))
        #expect(message.contains("Welcome!"))
        #expect(!message.contains("starter pack"))
    }
    
    @Test("Generates first-person copy with starter pack")
    func testFirstPersonWithStarterPack() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let message = NewskieHelper.dialogMessage(
            handle: "myuser.bsky.social",
            isSelf: true,
            createdAt: date,
            hasStarterPack: true
        )
        #expect(message.contains("You joined Bluesky"))
        #expect(message.contains("using a starter pack"))
    }
    
    @Test("Generates third-person copy without starter pack")
    func testThirdPersonWithoutStarterPack() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let message = NewskieHelper.dialogMessage(
            handle: "alice.bsky.social",
            isSelf: false,
            createdAt: date,
            hasStarterPack: false
        )
        #expect(message.contains("@alice.bsky.social joined Bluesky"))
        #expect(!message.contains("starter pack"))
    }
    
    @Test("Generates third-person copy with starter pack")
    func testThirdPersonWithStarterPack() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let message = NewskieHelper.dialogMessage(
            handle: "alice.bsky.social",
            isSelf: false,
            createdAt: date,
            hasStarterPack: true
        )
        #expect(message.contains("@alice.bsky.social joined Bluesky"))
        #expect(message.contains("using a starter pack"))
    }
}
