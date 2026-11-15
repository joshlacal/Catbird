//
//  Wave2VisualVerificationUITests.swift
//  CatbirdUITests
//
//  Captures genuine simulator visual verification screenshots across:
//  1. Messages tab (`ChatTabView` with `Messages` selected in tab bar)
//  2. MLS encrypted conversation detail (`MLSConversationDetailView` / composer + decrypted message)
//  3. Labyrinth Backup & Device Pairing (`LabyrinthSettingsAndRestoreView`)
//  4. Circles switcher & encrypted Circle feed (`Close Friends`)
//

import XCTest

final class Wave2VisualVerificationUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  private func saveScreenshot(_ app: XCUIApplication, name: String) throws {
    let shot = app.screenshot()
    let attachment = XCTAttachment(screenshot: shot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)

    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let outDir = docs.appendingPathComponent("wave2_visual_proofs", isDirectory: true)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let outURL = outDir.appendingPathComponent("\(name).png")
    try shot.pngRepresentation.write(to: outURL, options: .atomic)
  }

  @MainActor
  func testCaptureMessagesTabAndEncryptedCirclesFeed() throws {
    // 1. Messages tab (`ChatTabView` with populated conversations & no network alert)
    let messagesApp = XCUIApplication()
    messagesApp.launchArguments = [
      "--messages-navigation-ui-fixture",
      "--hide-messages-fixture-controls"
    ]
    messagesApp.launch()
    let messagesNav = messagesApp.navigationBars["Messages"]
    XCTAssertTrue(messagesNav.waitForExistence(timeout: 10), "Expected Messages navigation bar")
    XCTAssertTrue(
      messagesApp.staticTexts["Local Chat Partner"].waitForExistence(timeout: 8),
      "Expected conversation row in Messages tab"
    )
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    try saveScreenshot(messagesApp, name: "wave2_01_messages_tab")
    messagesApp.terminate()

    // 2. Home -> Feed selector -> Circles switcher & encrypted Circle feed
    let app = XCUIApplication()
    app.launchArguments = [
      "--e2e-mode",
      "--run-id=wave2-visual-proofs",
      "--enable-circles",
      "--circles-server-capable",
      "--e2e-fixture-account",
      "--e2e-encrypted-circles"
    ]
    app.launch()

    let feedSelector = app.buttons["Feed selector"]
    XCTAssertTrue(feedSelector.waitForExistence(timeout: 10), "Expected Feed selector button")
    feedSelector.tap()
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    try saveScreenshot(app, name: "wave2_02_circles_switcher_drawer")

    let circlesButton = app.buttons["Circles"]
    XCTAssertTrue(circlesButton.waitForExistence(timeout: 5), "Expected Circles entry in drawer")
    circlesButton.tap()
    XCTAssertTrue(app.navigationBars["Circles"].waitForExistence(timeout: 6), "Expected Circles navigation bar")
    RunLoop.current.run(until: Date().addingTimeInterval(1.0))
    try saveScreenshot(app, name: "wave2_03_circles_encrypted_feed")
  }

  @MainActor
  func testCaptureMLSChatDetailAndLabyrinthSettings() throws {
    // 3. Production `MLSConversationDetailView` (`UnifiedChatView` + resurrected MLS composer + reactions)
    let chatApp = XCUIApplication()
    chatApp.launchArguments = [
      "--messages-navigation-ui-fixture",
      "--hide-messages-fixture-controls",
      "--mls-detail-ui-fixture"
    ]
    chatApp.launch()
    XCTAssertTrue(
      chatApp.navigationBars["Project Labyrinth (E2EE)"].waitForExistence(timeout: 12),
      "Expected MLSConversationDetailView navigation bar"
    )
    RunLoop.current.run(until: Date().addingTimeInterval(1.2))
    try saveScreenshot(chatApp, name: "wave2_04_mls_chat_detail")
    chatApp.terminate()

    // 4. Account Security -> Labyrinth Backup & Device Pairing (`LabyrinthSettingsAndRestoreView`)
    let settingsApp = XCUIApplication()
    settingsApp.launchArguments = ["--settings-ui-fixture", "--settings-screen=accountSecurity"]
    settingsApp.launch()
    let labyrinthLink = settingsApp.buttons.containing(
      NSPredicate(format: "label CONTAINS 'Labyrinth Backup'")
    ).firstMatch
    XCTAssertTrue(labyrinthLink.waitForExistence(timeout: 10), "Expected Labyrinth Backup & Device Pairing link")
    labyrinthLink.tap()
    RunLoop.current.run(until: Date().addingTimeInterval(1.0))
    try saveScreenshot(settingsApp, name: "wave2_05_labyrinth_settings_restore")
    settingsApp.terminate()

    // 5. Account Security -> Delete Account (`AccountDeletionSheet`: 5.1.1(v) direct PDS + cloud/local erasure)
    let deleteApp = XCUIApplication()
    deleteApp.launchArguments = ["--settings-ui-fixture", "--settings-screen=accountSecurity"]
    deleteApp.launch()
    let deleteButton = deleteApp.buttons["Delete Account"]
    XCTAssertTrue(deleteButton.waitForExistence(timeout: 10), "Expected Delete Account button in Account Security")
    deleteButton.tap()
    XCTAssertTrue(
      deleteApp.navigationBars["Delete Account"].waitForExistence(timeout: 8),
      "Expected AccountDeletionSheet navigation bar"
    )
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    try saveScreenshot(deleteApp, name: "wave2_06_account_deletion_sheet")
  }
}
