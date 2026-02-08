//
//  MLSChatModerationUITests.swift
//  CatbirdUITests
//
//  Created by Claude Code
//  UI tests for MLS chat moderation and admin features
//

import XCTest

/// UI test suite for MLS chat moderation features
/// Tests user flows for reporting, admin actions, and member management
final class MLSChatModerationUITests: XCTestCase {

  var app: XCUIApplication!

  // MARK: - Setup & Teardown

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()

    // Launch arguments for test environment
    app.launchArguments = [
      "-UITestMode", "true",
      "-MLSTestMode", "true",
      "-SkipOnboarding", "true"
    ]

    // Launch environment variables
    app.launchEnvironment = [
      "DISABLE_ANIMATIONS": "1",
      "MLS_TEST_ADMIN_MODE": "1"
    ]

    app.launch()
  }

  override func tearDownWithError() throws {
    app = nil
  }

  // MARK: - Admin Member Removal Tests

  func testAdminCanRemoveMembers() throws {
    // Navigate to MLS chat conversation
    navigateToMLSConversation()

    // Open member list
    let membersButton = app.buttons["conversation.members"]
    XCTAssertTrue(membersButton.waitForExistence(timeout: 5))
    membersButton.tap()

    // Find member to remove
    let memberCell = app.cells["member.did:plc:violator999"]
    XCTAssertTrue(memberCell.waitForExistence(timeout: 3))

    // Long press to show context menu (admin only)
    memberCell.press(forDuration: 1.0)

    // Tap "Remove Member" option
    let removeButton = app.buttons["Remove Member"]
    XCTAssertTrue(removeButton.waitForExistence(timeout: 2))
    removeButton.tap()

    // Confirm removal in alert
    let confirmAlert = app.alerts["Remove Member"]
    XCTAssertTrue(confirmAlert.waitForExistence(timeout: 2))

    let confirmButton = confirmAlert.buttons["Remove"]
    confirmButton.tap()

    // Verify member is removed from UI
    XCTAssertFalse(memberCell.exists, "Member should be removed from list")

    // Verify success message
    let successMessage = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'removed'")).firstMatch
    XCTAssertTrue(successMessage.waitForExistence(timeout: 3))
  }

  func testNonAdminCannotRemoveMembers() throws {
    // Launch as non-admin user
    app.launchEnvironment["MLS_TEST_ADMIN_MODE"] = "0"
    app.terminate()
    app.launch()

    navigateToMLSConversation()

    // Open member list
    let membersButton = app.buttons["conversation.members"]
    XCTAssertTrue(membersButton.waitForExistence(timeout: 5))
    membersButton.tap()

    // Find member cell
    let memberCell = app.cells.firstMatch
    XCTAssertTrue(memberCell.waitForExistence(timeout: 3))

    // Long press should NOT show admin options
    memberCell.press(forDuration: 1.0)

    let removeButton = app.buttons["Remove Member"]
    XCTAssertFalse(removeButton.exists, "Non-admin should not see remove option")
  }

  // MARK: - Report Member Tests

  func testReportMemberFlow() throws {
    navigateToMLSConversation()

    // Find a message from violator
    let messageCell = app.cells.containing(NSPredicate(format: "identifier CONTAINS 'message'")).firstMatch
    XCTAssertTrue(messageCell.waitForExistence(timeout: 5))

    // Long press message to show context menu
    messageCell.press(forDuration: 1.0)

    // Tap "Report" option
    let reportButton = app.buttons["Report"]
    XCTAssertTrue(reportButton.waitForExistence(timeout: 2))
    reportButton.tap()

    // Select report category
    let harassmentOption = app.buttons["category.harassment"]
    XCTAssertTrue(harassmentOption.waitForExistence(timeout: 3))
    harassmentOption.tap()

    // Add details (optional)
    let detailsTextField = app.textViews["report.details"]
    if detailsTextField.exists {
      detailsTextField.tap()
      detailsTextField.typeText("Repeated offensive messages in conversation")
    }

    // Submit report
    let submitButton = app.buttons["Submit Report"]
    XCTAssertTrue(submitButton.exists)
    submitButton.tap()

    // Verify confirmation
    let confirmationAlert = app.alerts["Report Submitted"]
    XCTAssertTrue(confirmationAlert.waitForExistence(timeout: 3))

    let okButton = confirmationAlert.buttons["OK"]
    okButton.tap()
  }

  func testCannotReportSelf() throws {
    navigateToMLSConversation()

    // Find own message
    let ownMessage = app.cells.containing(NSPredicate(format: "identifier CONTAINS 'message.own'")).firstMatch
    XCTAssertTrue(ownMessage.waitForExistence(timeout: 5))

    // Long press own message
    ownMessage.press(forDuration: 1.0)

    // "Report" option should NOT be available for own messages
    let reportButton = app.buttons["Report"]
    XCTAssertFalse(reportButton.exists, "Cannot report own messages")
  }

  // MARK: - Admin Dashboard Tests

  func testAdminDashboardShowsCorrectStats() throws {
    navigateToMLSConversation()

    // Open conversation settings
    let settingsButton = app.buttons["conversation.settings"]
    XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
    settingsButton.tap()

    // Navigate to Admin Dashboard (admin only)
    let adminDashboard = app.buttons["Admin Dashboard"]
    XCTAssertTrue(adminDashboard.waitForExistence(timeout: 3))
    adminDashboard.tap()

    // Verify stats are displayed
    XCTAssertTrue(app.staticTexts["Total Reports"].exists)
    XCTAssertTrue(app.staticTexts["Pending Reports"].exists)
    XCTAssertTrue(app.staticTexts["Resolved Reports"].exists)
    XCTAssertTrue(app.staticTexts["Total Removals"].exists)

    // Verify numeric values are shown
    let totalReportsValue = app.staticTexts.matching(identifier: "stats.totalReports").firstMatch
    XCTAssertTrue(totalReportsValue.exists)

    // Verify category breakdown
    XCTAssertTrue(app.staticTexts["Harassment"].exists)
    XCTAssertTrue(app.staticTexts["Spam"].exists)
    XCTAssertTrue(app.staticTexts["Hate Speech"].exists)

    // Verify resolution time metric
    XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Average Resolution'")).firstMatch.exists)
  }

  func testNonAdminCannotAccessAdminDashboard() throws {
    // Launch as non-admin
    app.launchEnvironment["MLS_TEST_ADMIN_MODE"] = "0"
    app.terminate()
    app.launch()

    navigateToMLSConversation()

    // Open conversation settings
    let settingsButton = app.buttons["conversation.settings"]
    XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
    settingsButton.tap()

    // Admin Dashboard should not be visible
    let adminDashboard = app.buttons["Admin Dashboard"]
    XCTAssertFalse(adminDashboard.exists, "Non-admin should not see Admin Dashboard")
  }

  // MARK: - Promote/Demote Admin Tests

  func testPromoteDemoteAdminUpdatesUI() throws {
    navigateToMLSConversation()

    // Open member list
    let membersButton = app.buttons["conversation.members"]
    XCTAssertTrue(membersButton.waitForExistence(timeout: 5))
    membersButton.tap()

    // Find regular member
    let memberCell = app.cells["member.did:plc:member456"]
    XCTAssertTrue(memberCell.waitForExistence(timeout: 3))

    // Verify no admin badge initially
    let adminBadge = memberCell.images["admin.badge"]
    XCTAssertFalse(adminBadge.exists)

    // Long press to show admin options
    memberCell.press(forDuration: 1.0)

    // Tap "Promote to Admin"
    let promoteButton = app.buttons["Promote to Admin"]
    XCTAssertTrue(promoteButton.waitForExistence(timeout: 2))
    promoteButton.tap()

    // Confirm promotion
    let confirmAlert = app.alerts["Promote to Admin"]
    XCTAssertTrue(confirmAlert.waitForExistence(timeout: 2))
    confirmAlert.buttons["Promote"].tap()

    // Wait for UI update
    sleep(1)

    // Verify admin badge now appears
    XCTAssertTrue(adminBadge.waitForExistence(timeout: 3), "Admin badge should appear after promotion")

    // Test demotion
    memberCell.press(forDuration: 1.0)

    let demoteButton = app.buttons["Remove Admin"]
    XCTAssertTrue(demoteButton.waitForExistence(timeout: 2))
    demoteButton.tap()

    // Confirm demotion
    let demoteAlert = app.alerts["Remove Admin Status"]
    XCTAssertTrue(demoteAlert.waitForExistence(timeout: 2))
    demoteAlert.buttons["Remove"].tap()

    // Wait for UI update
    sleep(1)

    // Verify admin badge is removed
    XCTAssertFalse(adminBadge.exists, "Admin badge should be removed after demotion")
  }

  // MARK: - Pending Reports View Tests

  func testAdminCanViewPendingReports() throws {
    navigateToMLSConversation()

    // Open conversation settings
    let settingsButton = app.buttons["conversation.settings"]
    XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
    settingsButton.tap()

    // Navigate to Pending Reports
    let reportsButton = app.buttons["Pending Reports"]
    XCTAssertTrue(reportsButton.waitForExistence(timeout: 3))

    // Check badge showing count (use staticTexts to find badge label)
    let reportBadge = reportsButton.staticTexts.element(boundBy: 1)
    if reportBadge.exists {
      let badgeValue = reportBadge.label
      XCTAssertFalse(badgeValue.isEmpty, "Badge should show report count")
    }

    reportsButton.tap()

    // Verify reports list
    let reportsList = app.tables["reports.list"]
    XCTAssertTrue(reportsList.waitForExistence(timeout: 3))

    // Find first report
    let firstReport = reportsList.cells.firstMatch
    if firstReport.exists {
      // Tap to view details
      firstReport.tap()

      // Verify report details shown
      XCTAssertTrue(app.staticTexts["Reported User"].exists)
      XCTAssertTrue(app.staticTexts["Category"].exists)
      XCTAssertTrue(app.staticTexts["Submitted At"].exists)

      // Test resolution actions
      let resolveButton = app.buttons["Resolve Report"]
      XCTAssertTrue(resolveButton.exists)

      resolveButton.tap()

      // Select resolution action
      let removeAction = app.buttons["action.remove_member"]
      XCTAssertTrue(removeAction.waitForExistence(timeout: 2))
      removeAction.tap()

      // Add notes
      let notesField = app.textViews["resolution.notes"]
      if notesField.exists {
        notesField.tap()
        notesField.typeText("Removed member for community guidelines violation")
      }

      // Confirm resolution
      let confirmButton = app.buttons["Confirm"]
      confirmButton.tap()

      // Verify report marked as resolved
      let resolvedBadge = app.staticTexts["Resolved"]
      XCTAssertTrue(resolvedBadge.waitForExistence(timeout: 3))
    }
  }

  // MARK: - Block Detection Tests

  func testBlockConflictWarning() throws {
    navigateToMLSConversation()

    // Attempt to add member who has blocks with existing members
    let addMemberButton = app.buttons["Add Member"]
    XCTAssertTrue(addMemberButton.waitForExistence(timeout: 5))
    addMemberButton.tap()

    // Search for user
    let searchField = app.searchFields["Search Users"]
    XCTAssertTrue(searchField.waitForExistence(timeout: 3))
    searchField.tap()
    searchField.typeText("blocked.user")

    // Select user from results
    let userResult = app.cells.containing(NSPredicate(format: "label CONTAINS 'blocked.user'")).firstMatch
    XCTAssertTrue(userResult.waitForExistence(timeout: 3))
    userResult.tap()

    // Tap Add button
    let addButton = app.buttons["Add to Conversation"]
    addButton.tap()

    // Verify block conflict warning
    let blockWarningAlert = app.alerts.containing(NSPredicate(format: "label CONTAINS 'block'")).firstMatch
    XCTAssertTrue(blockWarningAlert.waitForExistence(timeout: 3))

    // Warning should explain the conflict
    let warningMessage = blockWarningAlert.staticTexts.element(boundBy: 1)
    XCTAssertTrue(warningMessage.label.contains("has blocked") || warningMessage.label.contains("block relationship"))

    // Cancel add operation
    blockWarningAlert.buttons["Cancel"].tap()
  }

  // MARK: - Helper Methods

  private func navigateToMLSConversation() {
    // Navigate to MLS chat tab
    let chatTab = app.tabBars.buttons["MLS Chat"]
    XCTAssertTrue(chatTab.waitForExistence(timeout: 10))
    chatTab.tap()

    // Wait for conversation list
    let conversationList = app.tables["mls.conversations.list"]
    XCTAssertTrue(conversationList.waitForExistence(timeout: 5))

    // Tap first conversation
    let firstConversation = conversationList.cells.firstMatch
    XCTAssertTrue(firstConversation.waitForExistence(timeout: 3))
    firstConversation.tap()

    // Wait for conversation view to load
    let conversationView = app.otherElements["mls.conversation.view"]
    XCTAssertTrue(conversationView.waitForExistence(timeout: 5))
  }

  private func waitForElementToDisappear(_ element: XCUIElement, timeout: TimeInterval = 5) {
    let predicate = NSPredicate(format: "exists == false")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
    XCTAssertEqual(result, .completed)
  }

  // MARK: - Performance Tests

  func testAdminDashboardLoadPerformance() throws {
    measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
      navigateToMLSConversation()

      let settingsButton = app.buttons["conversation.settings"]
      settingsButton.tap()

      let adminDashboard = app.buttons["Admin Dashboard"]
      adminDashboard.tap()

      // Wait for stats to load
      let statsView = app.otherElements["admin.stats.view"]
      _ = statsView.waitForExistence(timeout: 5)

      // Go back
      app.navigationBars.buttons.element(boundBy: 0).tap()
      app.navigationBars.buttons.element(boundBy: 0).tap()
    }
  }

  func testReportListScrollPerformance() throws {
    // Only run if there are reports to scroll
    navigateToMLSConversation()

    let settingsButton = app.buttons["conversation.settings"]
    settingsButton.tap()

    let reportsButton = app.buttons["Pending Reports"]
    guard reportsButton.exists else {
      throw XCTSkip("No reports available for performance test")
    }

    reportsButton.tap()

    measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric]) {
      let reportsList = app.tables["reports.list"]

      // Scroll through reports
      if reportsList.cells.count > 5 {
        let firstCell = reportsList.cells.firstMatch
        let lastCell = reportsList.cells.element(boundBy: reportsList.cells.count - 1)

        firstCell.swipeUp(velocity: .fast)
        sleep(1)
        lastCell.swipeDown(velocity: .fast)
      }
    }
  }
}
