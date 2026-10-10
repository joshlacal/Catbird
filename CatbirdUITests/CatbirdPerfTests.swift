//
//  CatbirdPerfTests.swift
//  CatbirdUITests
//
//  Automated UI performance tests for Catbird core journeys:
//  - Cold launch to first feed content
//  - Home feed scrolling and deceleration
//  - Thread navigation
//  - Profile view entry
//  - Notifications tab transition
//
//  These tests operate in offline E2E fixture mode and never post or follow.
//

import XCTest

final class CatbirdPerfTests: XCTestCase {

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  // MARK: - Launch Performance

  /// Measures cold launch time until the app is responsive and displays the initial feed.
  @MainActor
  func testColdLaunchToFirstFeed() throws {
    let metrics: [XCTMetric] = [
      XCTApplicationLaunchMetric(waitUntilResponsive: true)
    ]
    let options = XCTMeasureOptions()
    options.iterationCount = 5

    measure(metrics: metrics, options: options) {
      let app = XCUIApplication()
      app.launchArguments = [
        "--e2e-mode",
        "--e2e-fixture-account",
        "--run-id=perf-launch",
        "-AppleLanguages", "(en)",
        "-AppleLocale", "en_US"
      ]
      app.launch()

      let homeTab = app.buttons["tab_home"].firstMatch
      let fallbackHome = app.tabBars.buttons["Home"].firstMatch
      let home = homeTab.exists ? homeTab : fallbackHome
      _ = home.waitForExistence(timeout: 10)
    }
  }

  // MARK: - Home Feed Scroll Performance

  /// Measures scrolling and deceleration hitches across the home feed.
  @MainActor
  func testHomeFeedScroll() throws {
    let app = launchApp(runId: "perf-feed-scroll")
    waitForHomeFeed(in: app)

    let metrics: [XCTMetric] = [
      XCTOSSignpostMetric.scrollingAndDecelerationMetric
    ]
    let options = XCTMeasureOptions()
    options.iterationCount = 5

    measure(metrics: metrics, options: options) {
      for _ in 0..<6 {
        app.swipeUp(velocity: .fast)
      }
    }
  }

  // MARK: - Thread Open Performance

  /// Measures time and CPU to navigate into a post thread and return to feed.
  @MainActor
  func testThreadOpen() throws {
    let app = launchApp(runId: "perf-thread-open")
    waitForHomeFeed(in: app)

    let metrics: [XCTMetric] = [
      XCTClockMetric(),
      XCTCPUMetric(application: app)
    ]
    let options = XCTMeasureOptions()
    options.iterationCount = 5

    measure(metrics: metrics, options: options) {
      let cell = app.cells.firstMatch
      if cell.waitForExistence(timeout: 5) && cell.isHittable {
        cell.tap()
      } else {
        app.swipeUp()
        let fallbackCell = app.cells.firstMatch
        if fallbackCell.waitForExistence(timeout: 5) && fallbackCell.isHittable {
          fallbackCell.tap()
        }
      }

      // Wait for thread view to appear
      let backButton = app.navigationBars.buttons.firstMatch
      _ = backButton.waitForExistence(timeout: 5)

      // Pop back to feed
      if backButton.exists && backButton.isHittable {
        backButton.tap()
      }
    }
  }

  // MARK: - Profile Open Performance

  /// Measures time and CPU to navigate into a user profile.
  @MainActor
  func testProfileOpen() throws {
    let app = launchApp(runId: "perf-profile-open")
    waitForHomeFeed(in: app)

    let metrics: [XCTMetric] = [
      XCTClockMetric(),
      XCTCPUMetric(application: app)
    ]
    let options = XCTMeasureOptions()
    options.iterationCount = 5

    measure(metrics: metrics, options: options) {
      let profileTab = app.buttons["tab_profile"].firstMatch
      let fallbackProfileTab = app.tabBars.buttons["Profile"].firstMatch
      let hasProfileTab = profileTab.exists || fallbackProfileTab.exists

      if hasProfileTab {
        tapTab("profile", fallbackLabel: "Profile", in: app)
      } else {
        // Compact width route: open side drawer via feed selector, then tap Profile
        let feedSelector = app.buttons["Feed selector"].firstMatch
        XCTAssertTrue(feedSelector.waitForExistence(timeout: 5), "Feed selector button should exist on compact width")
        feedSelector.tap()

        let drawerProfile = app.buttons["Profile"].firstMatch
        let myProfile = app.buttons["My Profile"].firstMatch
        let profileButton = drawerProfile.waitForExistence(timeout: 5) ? drawerProfile : myProfile
        XCTAssertTrue(profileButton.waitForExistence(timeout: 5), "Profile button in drawer should exist")
        profileButton.tap()
      }

      // Wait for a profile-specific element (Edit Profile button or handle text)
      let editProfileButton = app.buttons["Edit Profile"].firstMatch
      let handleText = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '@'")).firstMatch
      let profileElement = editProfileButton.waitForExistence(timeout: 5) ? editProfileButton : handleText
      XCTAssertTrue(
        profileElement.waitForExistence(timeout: 5),
        "Profile-specific element (Edit Profile button or @handle) should appear"
      )

      // Return to home feed
      if hasProfileTab {
        tapTab("home", fallbackLabel: "Home", in: app)
      } else {
        let backButton = app.navigationBars.buttons.firstMatch
        if backButton.waitForExistence(timeout: 5) && backButton.isHittable {
          backButton.tap()
        }
        let feedSelector = app.buttons["Feed selector"].firstMatch
        _ = feedSelector.waitForExistence(timeout: 5)
      }
    }
  }

  // MARK: - Notifications Tab Entry Performance

  /// Measures time and CPU to switch to the Notifications tab.
  @MainActor
  func testNotificationsTabEntry() throws {
    let app = launchApp(runId: "perf-notifications-open")
    waitForHomeFeed(in: app)

    let metrics: [XCTMetric] = [
      XCTClockMetric(),
      XCTCPUMetric(application: app)
    ]
    let options = XCTMeasureOptions()
    options.iterationCount = 5

    measure(metrics: metrics, options: options) {
      tapTab("notifications", fallbackLabel: "Notifications", in: app)
      _ = app.navigationBars["Notifications"].waitForExistence(timeout: 5)

      // Return to home tab
      tapTab("home", fallbackLabel: "Home", in: app)
    }
  }

  // MARK: - Helpers

  @MainActor
  private func launchApp(runId: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "--e2e-mode",
      "--e2e-fixture-account",
      "--run-id=\(runId)",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_US"
    ]
    app.launch()
    return app
  }

  @MainActor
  private func waitForHomeFeed(in app: XCUIApplication) {
    let homeTab = app.buttons["tab_home"].firstMatch
    let fallbackHome = app.tabBars.buttons["Home"].firstMatch
    let home = homeTab.exists ? homeTab : fallbackHome
    XCTAssertTrue(home.waitForExistence(timeout: 10), "Home tab should be visible at launch")
  }

  @MainActor
  private func tapTab(_ name: String, fallbackLabel: String, in app: XCUIApplication) {
    let identified = app.buttons["tab_\(name)"].firstMatch
    let labeled = app.tabBars.buttons[fallbackLabel].firstMatch
    let button = identified.exists ? identified : labeled
    XCTAssertTrue(
      button.waitForExistence(timeout: 5),
      "Tab button '\(name)' (fallback '\(fallbackLabel)') should exist"
    )
    XCTAssertTrue(
      button.isHittable,
      "Tab button '\(name)' (fallback '\(fallbackLabel)') should be hittable"
    )
    button.tap()
  }
}
