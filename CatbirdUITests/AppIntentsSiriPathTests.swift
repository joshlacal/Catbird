//
//  AppIntentsSiriPathTests.swift
//  CatbirdUITests
//
//  Out-of-process App Intents verification via AppIntentsTesting (iOS 27).
//  These tests exercise the SAME infrastructure Siri uses — onscreen entity
//  annotation collection ('View AppIntents Payload') and intent execution —
//  so a failure here reproduces "I can't like posts in Catbird" in a
//  debuggable harness instead of a black-box Siri refusal.
//
//  Run on a PHYSICAL iOS 27 device with a signed-in account for a faithful
//  reproduction (simulator lacks the full Siri/AppIntents daemons).
//
//  ⚠️ testLikePostIntentRunsThroughSystemInfrastructure performs a REAL like
//  on whatever post is first in the visible feed, on the signed-in account.
//  Unlike it afterward if that matters.
//

import XCTest

#if !targetEnvironment(simulator)
// AppIntentsTesting links support frameworks absent from older simulator runtimes;
// keep this physical-device-only suite out of simulator test bundles.
import AppIntentsTesting

final class AppIntentsSiriPathTests: XCTestCase {

  /// Probe 1: does the system see any onscreen PostEntity annotations?
  /// This is precisely the payload request that logs
  /// "timed out ... 'View AppIntents Payload'" when Siri asks.
  @available(iOS 27.0, *)
  func testOnscreenPostAnnotationsAreCollectable() async throws {
    let app = await XCUIApplication()
    await app.launch()
    // Let the feed render — posts annotate and seed the entity stores on render.
    try await Task.sleep(for: .seconds(40))

    let definitions = IntentDefinitions(bundleIdentifier: "blue.catbird")
    let annotations = try await definitions.entities["PostEntity"].viewAnnotations()

    XCTAssertFalse(
      annotations.isEmpty,
      "The system collected zero onscreen PostEntity annotations — the payload "
        + "path is broken before Siri's language layer is even involved.")
  }

  /// Probe 2: can the system execute LikePostIntent end-to-end with an
  /// onscreen entity — resolution, hydration, perform() — the way Siri would?
  @available(iOS 27.0, *)
  func testLikePostIntentRunsThroughSystemInfrastructure() async throws {
    let app = await XCUIApplication()
    await app.launch()
    try await Task.sleep(for: .seconds(40))

    let definitions = IntentDefinitions(bundleIdentifier: "blue.catbird")
    let annotations = try await definitions.entities["PostEntity"].viewAnnotations()
    let onscreenPost = try XCTUnwrap(
      annotations.first,
      "Need at least one onscreen post — run with the feed visible.")

    var intent = definitions.intents["LikePostIntent"].makeIntent()
    intent.post = onscreenPost.entity
    _ = try await intent.run()
    // Reaching this point means the system resolved the onscreen entity and
    // executed perform() through the real App Intents pipeline. If Siri still
    // refuses verbally while this passes, the gap is in Siri's language-layer
    // routing, not in the app — that's the Feedback case.
  }
}
#endif
