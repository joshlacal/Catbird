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

  /// Measures time, CPU and the app's ThreadOpen signpost to navigate into a post thread
  /// and return to feed. Set `TEST_RUNNER_CATBIRD_PERF_ITERATIONS=1` for a smoke run.
  @MainActor
  func testThreadOpen() throws {
    let app = launchApp(runId: "perf-thread-open")
    waitForHomeFeed(in: app)

    let metrics: [XCTMetric] = [
      XCTClockMetric(),
      XCTCPUMetric(application: app),
      // From view load to the positioned thread (teardown L4); see UIKitThreadView.
      XCTOSSignpostMetric(subsystem: "blue.catbird.performance", category: "Intervals", name: "ThreadOpen")
    ]
    let options = XCTMeasureOptions()
    options.iterationCount = Self.iterationCount

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

      // Wait until the thread is shown, not just pushed, so the ThreadOpen interval
      // ends ("outcome: visible") before the pop rather than being cancelled by it.
      XCTAssertTrue(waitForThreadReveal(in: app, timeout: 10), "The thread should be shown before popping")

      // Pop back to feed
      let backButton = app.navigationBars.buttons.firstMatch
      if backButton.waitForExistence(timeout: 5) && backButton.isHittable {
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

  /// Iterations per measure block; `TEST_RUNNER_CATBIRD_PERF_ITERATIONS` overrides the default 5.
  private static var iterationCount: Int {
    Int(ProcessInfo.processInfo.environment["CATBIRD_PERF_ITERATIONS"] ?? "").map { max(1, $0) } ?? 5
  }

  /// Whether the thread screen finished opening: ThreadViewController.revealContent() has
  /// marked the list "revealed", or the screen says the post can't be loaded. A hittable cell
  /// is not enough: a post tapped in a feed shows as the anchor while the thread still loads.
  @MainActor
  private func waitForThreadReveal(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
    let thread = app.collectionViews["thread.collectionView"]
    let unavailable = app.staticTexts.matching(
      NSPredicate(format: "label IN %@", ["Couldn’t Load Post", "Post Not Found", "Post Unavailable"])
    ).firstMatch
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if thread.exists, (thread.value as? String) == "revealed" { return true }
      if unavailable.exists { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    return false
  }

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
