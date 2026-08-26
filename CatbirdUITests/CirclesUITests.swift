//
//  CirclesUITests.swift
//  CatbirdUITests
//
//  UI tests for Catbird Circles end-to-end user flows and rollout gates.
//

import XCTest

final class CirclesUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  override func tearDownWithError() throws {
    app = nil
  }

  // MARK: - Launch Helpers

  private func launchWithCircles(extraArgs: [String] = []) {
    app = XCUIApplication()
    app.launchArguments = [
      "--e2e-mode",
      "--run-id=circles-ui-e2e",
      "--enable-circles",
      "--circles-server-capable",
      "--e2e-fixture-account"
    ] + extraArgs
    app.launch()
  }

  private func launchWithUnsupportedCircles() {
    app = XCUIApplication()
    app.launchArguments = [
      "--e2e-mode",
      "--run-id=circles-ui-unsupported",
      "--enable-circles",
      "--circles-unsupported-pds",
      "--e2e-fixture-account"
    ]
    app.launch()
  }

  // MARK: - Navigation & Action Helpers

  private func openDrawer() {
    let feedSelector = app.buttons["Feed selector"]
    if feedSelector.waitForExistence(timeout: 3) {
      feedSelector.tap()
    } else {
      let feedsButton = app.buttons["Feeds"]
      if feedsButton.waitForExistence(timeout: 3) {
        feedsButton.tap()
      }
    }
  }

  private func openCirclesFeed() {
    if app.navigationBars["Circles"].exists {
      let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
      let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
      top.press(forDuration: 0.1, thenDragTo: bottom)
      return
    }
    openDrawer()
    let circlesButton = app.buttons["Circles"]
    XCTAssertTrue(circlesButton.waitForExistence(timeout: 5), "Expected Circles feed entry in drawer or navigation")
    circlesButton.tap()
  }

  private func postContainer(for uri: String) -> XCUIElement {
    let el = app.otherElements["post.\(uri)"]
    if el.exists {
      return el
    }
    return app
  }

  // MARK: - Required Tests

  /// 1. Unsupported PDS: Circles disabled with explanation.
  func testUnsupportedCapabilityShowsExplanation() throws {
    launchWithUnsupportedCircles()

    openDrawer()

    let explanation = app.staticTexts["Circles requires a PDS that supports ATProto Spaces"]
    XCTAssertTrue(explanation.waitForExistence(timeout: 5), "Expected unsupported capability explanation text")

    let unsupportedEntry = app.buttons["Circles, unsupported"]
    XCTAssertTrue(unsupportedEntry.waitForExistence(timeout: 5), "Expected disabled Circles entry")
    XCTAssertFalse(unsupportedEntry.isEnabled, "Unsupported Circles entry must be disabled")
  }

  /// 2. Approved end-to-end scenario: Create Circle, post, verify badge, remove member, verify removal disclosure
  func testCreatePostReplyLikeRemoveMember() throws {
    launchWithCircles()

    // 1. Open Circles feed and create "UI Family" circle
    openCirclesFeed()
    let createButton = app.buttons["Create Circle"]
    XCTAssertTrue(createButton.waitForExistence(timeout: 5), "Expected Create Circle button")
    createButton.tap()

    let nameField = app.textFields["Circle name"]
    XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Expected Circle name text field")
    nameField.tap()
    nameField.typeText("UI Family")

    let submitCreate = app.navigationBars["New Circle"].buttons["Create Circle"]
    XCTAssertTrue(submitCreate.waitForExistence(timeout: 5), "Expected submit Create Circle button")
    submitCreate.tap()

    let createdLabel = app.staticTexts["Circle Created Successfully"]
    XCTAssertTrue(createdLabel.waitForExistence(timeout: 5), "Expected Circle Created Successfully label")

    let cancelButton = app.buttons["Cancel creating circle"]
    XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "Expected cancel/dismiss button")
    cancelButton.tap()

    // Pop back to Home
    if app.navigationBars["Circles"].exists {
      app.navigationBars.buttons.firstMatch.tap()
    }
    let homeTab = app.buttons["tab_home"]
    if homeTab.waitForExistence(timeout: 3) {
      homeTab.tap()
    }
    let composeButton = app.buttons["compose.fab"]
    XCTAssertTrue(composeButton.waitForExistence(timeout: 5), "Expected compose FAB")
    composeButton.tap()
    let audiencePicker = app.buttons["composer.audiencePicker"]
    XCTAssertTrue(audiencePicker.waitForExistence(timeout: 5), "Expected audience picker in composer")
    XCTAssertTrue(audiencePicker.label.contains("Public"), "Default composer destination must be Public")

    audiencePicker.tap()
    let familyOption = app.buttons["UI Family"]
    XCTAssertTrue(familyOption.waitForExistence(timeout: 3), "Expected UI Family option in audience picker")
    familyOption.tap()
    XCTAssertTrue(audiencePicker.label.contains("UI Family"), "Audience should update to UI Family")

    // 3. Type post text and submit
    let editor = app.textViews.firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 5), "Expected post text editor")
    editor.tap()
    editor.typeText("private family update for all members")

    let postButton = app.buttons["Post"]
    XCTAssertTrue(postButton.waitForExistence(timeout: 5), "Expected Post button")
    postButton.tap()
    // 4. Open Circles feed and verify Circle badge and post container
    openCirclesFeed()
    let postText = app.staticTexts["private family update for all members"]
    XCTAssertTrue(postText.waitForExistence(timeout: 5), "Expected post text in Circles feed")
    let circleBadge = app.staticTexts["Circle: UI Family"]
    XCTAssertTrue(circleBadge.waitForExistence(timeout: 5), "Expected UI Family circle badge on post")

    // 5. Verify reply and like actions inside this post container
    let targetContainer = postContainer(for: "at://did:plc:alicee2efixture/space/blue.catbird.circle/e2e-circle-1/did:plc:alicee2efixture/app.bsky.feed.post/e2e-post-1")
    let replyButton = targetContainer.buttons["replyButton"].firstMatch
    XCTAssertTrue(replyButton.waitForExistence(timeout: 5), "Expected replyButton on Circle post")
    replyButton.tap()

    let replyAudiencePicker = app.buttons["composer.audiencePicker"]
    XCTAssertTrue(replyAudiencePicker.waitForExistence(timeout: 5), "Expected audience picker on reply")
    XCTAssertFalse(replyAudiencePicker.isEnabled, "Reply audience must be locked")
    XCTAssertTrue(replyAudiencePicker.label.contains("UI Family"), "Reply audience must be UI Family")

    let replyEditor = app.textViews.firstMatch
    XCTAssertTrue(replyEditor.waitForExistence(timeout: 5), "Expected reply text editor")
    replyEditor.tap()
    replyEditor.typeText("reply stays private")

    let replyPostButton = app.buttons["Post"]
    replyPostButton.tap()

    // Refresh Circles feed and check reply count
    openCirclesFeed()
    let updatedTarget = postContainer(for: "at://did:plc:alicee2efixture/space/blue.catbird.circle/e2e-circle-1/did:plc:alicee2efixture/app.bsky.feed.post/e2e-post-1")
    let updatedReplyButton = updatedTarget.buttons["replyButton"].firstMatch
    XCTAssertTrue(updatedReplyButton.waitForExistence(timeout: 5), "Expected reply button on updated post")
    XCTAssertTrue(updatedReplyButton.label.contains("1"), "Reply count should be 1, got \(updatedReplyButton.label)")

    let likeButton = updatedTarget.buttons["likeButton"].firstMatch
    XCTAssertTrue(likeButton.waitForExistence(timeout: 5), "Expected likeButton on Circle post")
    likeButton.tap()
    XCTAssertTrue(likeButton.label.contains("Unlike") || likeButton.label.contains("1"), "Like button label should reflect liked state: \(likeButton.label)")

    // 6. Open Notifications, tap create-invite row, open settings, add & remove Bob
    let notificationsTab = app.buttons["tab_notifications"]
    XCTAssertTrue(notificationsTab.waitForExistence(timeout: 5), "Expected notifications tab")
    notificationsTab.tap()

    let inviteRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'circle.notification.'")).firstMatch
    XCTAssertTrue(inviteRow.waitForExistence(timeout: 5), "Expected create invite notification row")
    inviteRow.tap()

    let settingsButton = app.buttons["Circle settings and members"]
    XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Expected Circle settings button in detail view")
    settingsButton.tap()

    let addMemberButton = app.buttons["Add Member"]
    XCTAssertTrue(addMemberButton.waitForExistence(timeout: 5), "Expected Add Member button")
    addMemberButton.tap()

    let memberField = app.textFields["Member DID to add"]
    XCTAssertTrue(memberField.waitForExistence(timeout: 5), "Expected Member DID text field")
    memberField.tap()
    memberField.typeText("did:plc:bobe2efixture")

    let confirmAdd = app.buttons["Confirm add member"]
    XCTAssertTrue(confirmAdd.waitForExistence(timeout: 5), "Expected Confirm add member button")
    confirmAdd.tap()

    let bobDIDText = app.staticTexts["did:plc:bobe2efixture"]
    XCTAssertTrue(bobDIDText.waitForExistence(timeout: 5), "Expected Bob DID in member list")

    let removeBobButton = app.buttons["Remove member did:plc:bobe2efixture"]
    XCTAssertTrue(removeBobButton.waitForExistence(timeout: 5), "Expected Remove member button for Bob")
    removeBobButton.tap()

    let confirmRemove = app.buttons["Remove Member"]
    XCTAssertTrue(confirmRemove.waitForExistence(timeout: 5), "Expected Remove Member confirmation button")
    confirmRemove.tap()

    XCTAssertFalse(app.staticTexts["did:plc:bobe2efixture"].exists, "Bob DID should no longer be present in member list")

    let removeDisclosure = app.staticTexts["Circle privacy and membership disclosures"]
    XCTAssertTrue(removeDisclosure.waitForExistence(timeout: 5), "Expected removal disclosure in Circle settings")
  }

  /// 3. Destination lock during image upload: destination remains visible and non-interactive through upload
  func testDestinationLockedDuringImageUpload() throws {
    launchWithCircles()

    let composeButton = app.buttons["compose.fab"]
    XCTAssertTrue(composeButton.waitForExistence(timeout: 5), "Expected compose FAB")
    composeButton.tap()

    let audiencePicker = app.buttons["composer.audiencePicker"]
    XCTAssertTrue(audiencePicker.waitForExistence(timeout: 5), "Audience picker must be present in composer")
    XCTAssertTrue(audiencePicker.label.contains("Public"), "Default composer destination must be Public")

    // Switch to Family destination
    audiencePicker.tap()
    let familyOption = app.buttons["Family"]
    XCTAssertTrue(familyOption.waitForExistence(timeout: 3), "Expected Family option in audience picker")
    familyOption.tap()
    XCTAssertTrue(audiencePicker.label.contains("Family"), "Audience should be Family")

    let editor = app.textViews.firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 5), "Expected text editor")
    editor.tap()
    editor.typeText("image destination lock")

    // Attach image via accessory bar
    let attachmentMenu = app.buttons["Add attachment or post settings"]
    if attachmentMenu.exists {
      attachmentMenu.tap()
    }
    let photosButton = app.buttons["Photos"]
    XCTAssertTrue(photosButton.waitForExistence(timeout: 5), "Expected Photos button")
    photosButton.tap()

    let postButton = app.buttons["Post"]
    XCTAssertTrue(postButton.waitForExistence(timeout: 5), "Expected Post button")
    postButton.tap()

    // During the 2-second upload, verify audience picker remains visible, label is Family, and is disabled
    XCTAssertTrue(audiencePicker.exists, "Audience picker must remain visible during upload")
    XCTAssertTrue(audiencePicker.label.contains("Family"), "Audience picker must retain Family destination")
    XCTAssertFalse(audiencePicker.isEnabled, "Audience picker must be locked (disabled) during image upload")

    // Verify after post completes and feed displays rendered image
    openCirclesFeed()
    let uploadedPost = app.staticTexts["image destination lock"]
    XCTAssertTrue(uploadedPost.waitForExistence(timeout: 10), "Expected posted image text to appear in Circles feed")

    let renderedImage = app.images["Circle image"]
    XCTAssertTrue(renderedImage.waitForExistence(timeout: 5), "Expected rendered Circle image in post")
  }

  /// 4. Feed: Circle badge visible; no repost/quote/share actions. Baseline: public post has them.
  func testRedistributionControlsAbsentForCircleAndPresentForPublic() throws {
    launchWithCircles()

    openCirclesFeed()

    // First prove a Circle post and badge exists
    let postTarget = postContainer(for: "at://did:plc:alicee2efixture/space/blue.catbird.circle/family123/did:plc:alicee2efixture/app.bsky.feed.post/post1")

    let circlePostText = postTarget.staticTexts["Welcome to Family Circle"]
    XCTAssertTrue(circlePostText.waitForExistence(timeout: 5), "Seeded Family post text must exist")

    let circleBadge = postTarget.staticTexts["Circle: Family"]
    XCTAssertTrue(circleBadge.waitForExistence(timeout: 5), "Circle post with Family badge must exist")

    // For this Circle post container, repost and share buttons must NOT exist
    let circleRepostButton = postTarget.buttons["repostButton"]
    let circleShareButton = postTarget.buttons["shareButton"]

    XCTAssertFalse(circleRepostButton.exists, "Repost action must be absent for Circle posts")
    XCTAssertFalse(circleShareButton.exists, "Public share action must be absent for Circle posts")

    // Verify reply and like remain present for Circle post
    let replyButton = postTarget.buttons["replyButton"]
    let likeButton = postTarget.buttons["likeButton"]
    XCTAssertTrue(replyButton.waitForExistence(timeout: 5), "Reply button must remain available for Circle post")
    XCTAssertTrue(likeButton.waitForExistence(timeout: 5), "Like button must remain available for Circle post")

    // Pop back to Home
    if app.navigationBars["Circles"].exists {
      app.navigationBars.buttons.firstMatch.tap()
    }

    let publicTarget = postContainer(for: "at://did:plc:alicee2efixture/app.bsky.feed.post/publicpost1")

    let publicPostText = publicTarget.staticTexts["Hello public world from Alice"]
    XCTAssertTrue(publicPostText.waitForExistence(timeout: 5), "Public post text must exist")

    // Public posts have repost and share actions
    let publicRepostButton = publicTarget.buttons["repostButton"].firstMatch
    let publicShareButton = publicTarget.buttons["shareButton"].firstMatch
    XCTAssertTrue(publicRepostButton.waitForExistence(timeout: 5), "Public post must display repostButton")
    XCTAssertTrue(publicShareButton.waitForExistence(timeout: 5), "Public post must display shareButton")
  }

  /// 5. Thread: private reply remains locked in Family Circle.
  func testPrivateReplyRemainsInCircle() throws {
    launchWithCircles()

    openCirclesFeed()

    let target = postContainer(for: "at://did:plc:alicee2efixture/space/blue.catbird.circle/family123/did:plc:alicee2efixture/app.bsky.feed.post/post1")

    let replyButton = target.buttons["replyButton"].firstMatch
    XCTAssertTrue(replyButton.waitForExistence(timeout: 5), "Expected replyButton on Circle post")
    replyButton.tap()

    let audiencePicker = app.buttons["composer.audiencePicker"]
    XCTAssertTrue(audiencePicker.waitForExistence(timeout: 5), "Expected audience picker on reply composer")
    XCTAssertFalse(audiencePicker.isEnabled, "Reply audience must be locked to the parent Circle")
    XCTAssertTrue(audiencePicker.label.contains("Family"), "Reply audience must be Family")

    let editor = app.textViews.firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 5), "Expected text editor")
    editor.tap()
    editor.typeText("locked circle reply")

    let postButton = app.buttons["Post"]
    postButton.tap()

    let updatedTarget = postContainer(for: "at://did:plc:alicee2efixture/space/blue.catbird.circle/family123/did:plc:alicee2efixture/app.bsky.feed.post/post1")
    let updatedReply = updatedTarget.buttons["replyButton"].firstMatch
    XCTAssertTrue(updatedReply.waitForExistence(timeout: 5), "Expected reply button")
    XCTAssertTrue(updatedReply.label.contains("1"), "Parent post reply count should be 1")
  }

  /// 6. Notifications: generic push causes authenticated Circle refresh.
  func testGenericNotificationRefresh() throws {
    launchWithCircles()

    let notificationsTab = app.buttons["tab_notifications"]
    XCTAssertTrue(notificationsTab.waitForExistence(timeout: 5), "Expected notifications tab")
    notificationsTab.tap()
    let initialNotif = app.buttons["circle.notification.notif-1"]
    XCTAssertTrue(initialNotif.waitForExistence(timeout: 10), "Expected initial seeded Circle notification row")

    let pushTrigger = app.buttons["e2e.circleActivityPush"]
    XCTAssertTrue(pushTrigger.waitForExistence(timeout: 5), "Expected e2e circle activity push trigger")
    pushTrigger.tap()

    let pushedNotif = app.buttons["circle.notification.push-1"]
    XCTAssertTrue(pushedNotif.waitForExistence(timeout: 10), "Expected push-refreshed Circle notification row")
  }

  /// 7. Account switch/removal: prior Circle content disappears.
  func testAccountSwitchPurgesPriorCircleContentAndSwitchBackReloads() throws {
    launchWithCircles()

    openCirclesFeed()
    let alicePost = app.staticTexts["Alice secret notes"]
    XCTAssertTrue(alicePost.waitForExistence(timeout: 5), "Expected Alice secret notes post in Alice Circles feed")

    // Pop back to Home
    if app.navigationBars["Circles"].exists {
      app.navigationBars.buttons.firstMatch.tap()
    }
    let profileButton = app.buttons["Profile and settings"]
    XCTAssertTrue(profileButton.waitForExistence(timeout: 5), "Expected Profile and settings button")
    profileButton.press(forDuration: 1.5)

    let bobSwitch = app.buttons["account.switch.did:plc:bobe2efixture"]
    XCTAssertTrue(bobSwitch.waitForExistence(timeout: 5), "Expected Bob switch option in account menu")
    bobSwitch.tap()

    // Bob Circles feed: Family is present, Alice-only post is absent
    openCirclesFeed()
    let familyPost = app.staticTexts["Welcome to Family Circle"]
    XCTAssertTrue(familyPost.waitForExistence(timeout: 5), "Expected Family post in Bob Circles feed")
    XCTAssertFalse(app.staticTexts["Alice secret notes"].exists, "Alice-only post must not be visible in Bob Circles feed")

    // Pop back to Home
    if app.navigationBars["Circles"].exists {
      app.navigationBars.buttons.firstMatch.tap()
    }
    // Switch back to Alice
    let homeTab2 = app.buttons["tab_home"]
    homeTab2.tap()

    let profileButton2 = app.buttons["Profile and settings"]
    XCTAssertTrue(profileButton2.waitForExistence(timeout: 5), "Expected Profile and settings button")
    profileButton2.press(forDuration: 1.5)

    let aliceSwitch = app.buttons["account.switch.did:plc:alicee2efixture"]
    XCTAssertTrue(aliceSwitch.waitForExistence(timeout: 5), "Expected Alice switch option in account menu")
    aliceSwitch.tap()

    openCirclesFeed()
    let restoredAlicePost = app.staticTexts["Alice secret notes"]
    XCTAssertTrue(restoredAlicePost.waitForExistence(timeout: 5), "Expected Alice secret notes post to reload after switching back")
  }

  /// 8. Removal disclosure copy is displayed in Circle management
  func testMemberRemovalDisclosure() throws {
    launchWithCircles()

    let notificationsTab = app.buttons["tab_notifications"]
    XCTAssertTrue(notificationsTab.waitForExistence(timeout: 5), "Expected notifications tab")
    notificationsTab.tap()

    let inviteRow = app.buttons["circle.notification.notif-1"]
    XCTAssertTrue(inviteRow.waitForExistence(timeout: 5), "Expected invite notification row")
    inviteRow.tap()

    let settingsButton = app.buttons["Circle settings and members"]
    XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Expected Circle settings button in detail view")
    settingsButton.tap()

    let removeDisclosure = app.staticTexts["Circle privacy and membership disclosures"]
    XCTAssertTrue(removeDisclosure.waitForExistence(timeout: 5), "Expected Circle privacy and membership disclosures section")
  }
}
