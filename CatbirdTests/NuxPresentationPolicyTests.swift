import XCTest
@testable import Catbird
import Petrel

final class NuxPresentationPolicyTests: XCTestCase {

    @MainActor
    func testEmptyServerNuxStatesYieldsNil() {
        let presenter = NuxAnnouncementPresenter()
        let prefs = Preferences(accountDID: "did:plc:test")
        prefs.nuxStates = []

        let next = presenter.evaluateNextAnnouncement(from: prefs)
        // Unassigned / empty server preferences must not synthesize default campaigns
        XCTAssertNil(next)
    }

    @MainActor
    func testDeterministicOrderingWithExplicitAssignedNuxes() {
        let presenter = NuxAnnouncementPresenter()
        let prefs = Preferences(accountDID: "did:plc:test")
        // Supply assigned incomplete NUXes in reverse/arbitrary order
        prefs.nuxStates = [
            NuxState(id: NuxID.activitySubscriptions.rawValue, completed: false, data: nil, expiresAt: nil),
            NuxState(id: NuxID.groupChatsAnnouncement.rawValue, completed: false, data: nil, expiresAt: nil),
            NuxState(id: NuxID.draftsAnnouncement.rawValue, completed: false, data: nil, expiresAt: nil),
            NuxState(id: NuxID.bookmarksAnnouncement.rawValue, completed: false, data: nil, expiresAt: nil)
        ]

        let next = presenter.evaluateNextAnnouncement(from: prefs)
        // First in evaluationOrder is BookmarksAnnouncement
        XCTAssertEqual(next, NuxID.bookmarksAnnouncement)
    }

    @MainActor
    func testAbsentCampaignsNotSynthesized() {
        let presenter = NuxAnnouncementPresenter()
        let prefs = Preferences(accountDID: "did:plc:test")
        // Bookmarks is earlier in evaluationOrder, but absent from server preferences
        prefs.nuxStates = [
            NuxState(id: NuxID.draftsAnnouncement.rawValue, completed: false, data: nil, expiresAt: nil)
        ]

        let next = presenter.evaluateNextAnnouncement(from: prefs)
        // Must select the first assigned eligible campaign (Drafts), not synthesize absent Bookmarks
        XCTAssertEqual(next, NuxID.draftsAnnouncement)
    }

    @MainActor
    func testCompletedNuxSkipping() {
        let presenter = NuxAnnouncementPresenter()
        let prefs = Preferences(accountDID: "did:plc:test")
        prefs.nuxStates = [
            NuxState(id: NuxID.bookmarksAnnouncement.rawValue, completed: true, data: nil, expiresAt: nil),
            NuxState(id: NuxID.draftsAnnouncement.rawValue, completed: false, data: nil, expiresAt: nil)
        ]

        let next = presenter.evaluateNextAnnouncement(from: prefs)
        // Next after completed Bookmarks is assigned Drafts
        XCTAssertEqual(next, NuxID.draftsAnnouncement)
    }

    @MainActor
    func testCompletedNuxWithNoRemainingIncompleteYieldsNil() {
        let presenter = NuxAnnouncementPresenter()
        let prefs = Preferences(accountDID: "did:plc:test")
        prefs.nuxStates = [
            NuxState(id: NuxID.bookmarksAnnouncement.rawValue, completed: true, data: nil, expiresAt: nil)
        ]

        let next = presenter.evaluateNextAnnouncement(from: prefs)
        // Completed Bookmarks is skipped; no other campaign assigned -> nil
        XCTAssertNil(next)
    }

    @MainActor
    func testExpiredNuxSkipping() {
        let presenter = NuxAnnouncementPresenter()
        let prefs = Preferences(accountDID: "did:plc:test")
        let pastDate = Date().addingTimeInterval(-3600) // 1 hour ago
        prefs.nuxStates = [
            NuxState(id: NuxID.bookmarksAnnouncement.rawValue, completed: false, data: nil, expiresAt: pastDate),
            NuxState(id: NuxID.draftsAnnouncement.rawValue, completed: true, data: nil, expiresAt: nil),
            NuxState(id: NuxID.groupChatsAnnouncement.rawValue, completed: false, data: nil, expiresAt: nil)
        ]

        let next = presenter.evaluateNextAnnouncement(from: prefs)
        // Bookmarks is expired, Drafts is completed, so next assigned incomplete is GroupChats
        XCTAssertEqual(next, NuxID.groupChatsAnnouncement)
    }

    @MainActor
    func testAllCompletedYieldsNil() {
        let presenter = NuxAnnouncementPresenter()
        let prefs = Preferences(accountDID: "did:plc:test")
        prefs.nuxStates = NuxID.allCases.map {
            NuxState(id: $0.rawValue, completed: true, data: nil, expiresAt: nil)
        }

        let next = presenter.evaluateNextAnnouncement(from: prefs)
        XCTAssertNil(next)
    }

    @MainActor
    func testAllExpiredYieldsNil() {
        let presenter = NuxAnnouncementPresenter()
        let prefs = Preferences(accountDID: "did:plc:test")
        let pastDate = Date().addingTimeInterval(-3600) // 1 hour ago
        prefs.nuxStates = NuxID.allCases.map {
            NuxState(id: $0.rawValue, completed: false, data: nil, expiresAt: pastDate)
        }

        let next = presenter.evaluateNextAnnouncement(from: prefs)
        XCTAssertNil(next)
    }

    @MainActor
    func testNilPreferencesYieldsNil() {
        let presenter = NuxAnnouncementPresenter()
        let next = presenter.evaluateNextAnnouncement(from: nil)
        XCTAssertNil(next)
    }
    @MainActor
    func testSuppressionWhenBlockingSheetsActive() {
        let presenter = NuxAnnouncementPresenter()

        // Welcome sheet active suppresses
        presenter.evaluateAndPresentIfNeeded(isWelcomeShowing: true, isComposerShowing: false)
        XCTAssertNil(presenter.activeAnnouncement)

        // Composer active suppresses
        presenter.evaluateAndPresentIfNeeded(isWelcomeShowing: false, isComposerShowing: true)
        XCTAssertNil(presenter.activeAnnouncement)
    }

    // MARK: - NuxNudge Behavioral Policy Tests

    @MainActor
    func testNudgeEligibilityRequiresExactServerPresentState() {
        let prefs = Preferences(accountDID: "did:plc:test")
        let testDID = "did:plc:test"

        // 1. Absent from preferences -> ineligible (no synthesis)
        prefs.nuxStates = []
        XCTAssertFalse(NuxNudgeModifier.isNudgeEligible(id: .bookmarksAnnouncement, from: prefs, forDID: testDID))
        XCTAssertFalse(NuxNudgeModifier.isNudgeEligible(id: .activitySubscriptions, from: prefs, forDID: testDID))

        // 2. Present, incomplete, unexpired -> eligible for exact ID
        prefs.nuxStates = [
            NuxState(id: NuxID.bookmarksAnnouncement.rawValue, completed: false, data: nil, expiresAt: nil),
            NuxState(id: NuxID.activitySubscriptions.rawValue, completed: false, data: nil, expiresAt: nil)
        ]
        XCTAssertTrue(NuxNudgeModifier.isNudgeEligible(id: .bookmarksAnnouncement, from: prefs, forDID: testDID))
        XCTAssertTrue(NuxNudgeModifier.isNudgeEligible(id: .activitySubscriptions, from: prefs, forDID: testDID))
        XCTAssertFalse(NuxNudgeModifier.isNudgeEligible(id: .draftsAnnouncement, from: prefs, forDID: testDID))
        XCTAssertFalse(NuxNudgeModifier.isNudgeEligible(id: .groupChatsAnnouncement, from: prefs, forDID: testDID))

        // 3. Completed state -> ineligible
        prefs.nuxStates = [
            NuxState(id: NuxID.bookmarksAnnouncement.rawValue, completed: true, data: nil, expiresAt: nil)
        ]
        XCTAssertFalse(NuxNudgeModifier.isNudgeEligible(id: .bookmarksAnnouncement, from: prefs, forDID: testDID))

        // 4. Expired state -> ineligible
        let pastDate = Date().addingTimeInterval(-3600)
        prefs.nuxStates = [
            NuxState(id: NuxID.activitySubscriptions.rawValue, completed: false, data: nil, expiresAt: pastDate)
        ]
        XCTAssertFalse(NuxNudgeModifier.isNudgeEligible(id: .activitySubscriptions, from: prefs, forDID: testDID))
    }

    @MainActor
    func testNudgeEligibilityIsDIDScoped() {
        let prefs = Preferences(accountDID: "did:plc:accountA")
        prefs.nuxStates = [
            NuxState(id: NuxID.bookmarksAnnouncement.rawValue, completed: false, data: nil, expiresAt: nil),
            NuxState(id: NuxID.activitySubscriptions.rawValue, completed: false, data: nil, expiresAt: nil)
        ]

        // Matching DID -> eligible
        XCTAssertTrue(NuxNudgeModifier.isNudgeEligible(id: .bookmarksAnnouncement, from: prefs, forDID: "did:plc:accountA"))
        XCTAssertTrue(NuxNudgeModifier.isNudgeEligible(id: .activitySubscriptions, from: prefs, forDID: "did:plc:accountA"))

        // Mismatched DID (e.g. cross-account switch / stale preferences) -> ineligible
        XCTAssertFalse(NuxNudgeModifier.isNudgeEligible(id: .bookmarksAnnouncement, from: prefs, forDID: "did:plc:accountB"))
        XCTAssertFalse(NuxNudgeModifier.isNudgeEligible(id: .activitySubscriptions, from: prefs, forDID: "did:plc:accountB"))

        // Empty userDID -> ineligible
        XCTAssertFalse(NuxNudgeModifier.isNudgeEligible(id: .bookmarksAnnouncement, from: prefs, forDID: ""))

        // Nil preferences -> ineligible
        XCTAssertFalse(NuxNudgeModifier.isNudgeEligible(id: .bookmarksAnnouncement, from: nil, forDID: "did:plc:accountA"))
    }
}
