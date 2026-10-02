//
//  NotificationPreferencesV2Tests.swift
//  CatbirdTests
//

import XCTest
import Petrel
@testable import Catbird

final class NotificationPreferencesV2Tests: XCTestCase {

  func testServerSnapshotRoundTripsAllChannelsAndFilters() {
    let serverSnapshot = AppBskyNotificationDefs.Preferences(
      chat: .init(include: "all", push: false),
      follow: .init(include: "follows", list: true, push: false),
      like: .init(include: "all", list: false, push: true),
      likeViaRepost: .init(include: "follows", list: true, push: true),
      mention: .init(include: "all", list: true, push: false),
      quote: .init(include: "follows", list: false, push: false),
      reply: .init(include: "all", list: true, push: true),
      repost: .init(include: "follows", list: true, push: false),
      repostViaRepost: .init(include: "all", list: false, push: true),
      starterpackJoined: .init(list: true, push: false),
      subscribedPost: .init(list: false, push: true),
      unverified: .init(list: true, push: true),
      verified: .init(list: false, push: false)
    )

    let localPreferences = NotificationPreferences(serverPreferences: serverSnapshot)
    let rebuiltServerPreferences = localPreferences.toServerPreferences()
    let putInput = localPreferences.toPutPreferencesInput()

    // Assert Chat
    XCTAssertEqual(rebuiltServerPreferences.chat.include, "all")
    XCTAssertEqual(rebuiltServerPreferences.chat.push, false)
    XCTAssertEqual(putInput.chat?.include, "all")
    XCTAssertEqual(putInput.chat?.push, false)

    // Assert Filterable Preferences
    XCTAssertEqual(rebuiltServerPreferences.follow.include, "follows")
    XCTAssertEqual(rebuiltServerPreferences.follow.list, true)
    XCTAssertEqual(rebuiltServerPreferences.follow.push, false)

    XCTAssertEqual(rebuiltServerPreferences.like.include, "all")
    XCTAssertEqual(rebuiltServerPreferences.like.list, false)
    XCTAssertEqual(rebuiltServerPreferences.like.push, true)

    XCTAssertEqual(rebuiltServerPreferences.likeViaRepost.include, "follows")
    XCTAssertEqual(rebuiltServerPreferences.likeViaRepost.list, true)
    XCTAssertEqual(rebuiltServerPreferences.likeViaRepost.push, true)

    XCTAssertEqual(rebuiltServerPreferences.mention.include, "all")
    XCTAssertEqual(rebuiltServerPreferences.mention.list, true)
    XCTAssertEqual(rebuiltServerPreferences.mention.push, false)

    XCTAssertEqual(rebuiltServerPreferences.quote.include, "follows")
    XCTAssertEqual(rebuiltServerPreferences.quote.list, false)
    XCTAssertEqual(rebuiltServerPreferences.quote.push, false)

    XCTAssertEqual(rebuiltServerPreferences.reply.include, "all")
    XCTAssertEqual(rebuiltServerPreferences.reply.list, true)
    XCTAssertEqual(rebuiltServerPreferences.reply.push, true)

    XCTAssertEqual(rebuiltServerPreferences.repost.include, "follows")
    XCTAssertEqual(rebuiltServerPreferences.repost.list, true)
    XCTAssertEqual(rebuiltServerPreferences.repost.push, false)

    XCTAssertEqual(rebuiltServerPreferences.repostViaRepost.include, "all")
    XCTAssertEqual(rebuiltServerPreferences.repostViaRepost.list, false)
    XCTAssertEqual(rebuiltServerPreferences.repostViaRepost.push, true)

    // Assert Plain Preferences
    XCTAssertEqual(rebuiltServerPreferences.starterpackJoined.list, true)
    XCTAssertEqual(rebuiltServerPreferences.starterpackJoined.push, false)

    XCTAssertEqual(rebuiltServerPreferences.subscribedPost.list, false)
    XCTAssertEqual(rebuiltServerPreferences.subscribedPost.push, true)

    XCTAssertEqual(rebuiltServerPreferences.unverified.list, true)
    XCTAssertEqual(rebuiltServerPreferences.unverified.push, true)

    XCTAssertEqual(rebuiltServerPreferences.verified.list, false)
    XCTAssertEqual(rebuiltServerPreferences.verified.push, false)
  }

  func testChangingOnePreferencePreservesAllSiblingFields() {
    let serverSnapshot = AppBskyNotificationDefs.Preferences(
      chat: .init(include: "all", push: true),
      follow: .init(include: "follows", list: true, push: false),
      like: .init(include: "all", list: false, push: true),
      likeViaRepost: .init(include: "follows", list: true, push: true),
      mention: .init(include: "all", list: true, push: false),
      quote: .init(include: "follows", list: false, push: false),
      reply: .init(include: "all", list: true, push: true),
      repost: .init(include: "follows", list: true, push: false),
      repostViaRepost: .init(include: "all", list: false, push: true),
      starterpackJoined: .init(list: true, push: false),
      subscribedPost: .init(list: false, push: true),
      unverified: .init(list: true, push: true),
      verified: .init(list: false, push: false)
    )

    var preferences = NotificationPreferences(serverPreferences: serverSnapshot)

    // Modify only likes
    preferences.like = .init(include: "follows", list: true, push: false)

    let input = preferences.toPutPreferencesInput()

    // Assert modified field
    XCTAssertEqual(input.like?.include, "follows")
    XCTAssertEqual(input.like?.list, true)
    XCTAssertEqual(input.like?.push, false)

    // Assert all 12 sibling fields are exactly preserved
    XCTAssertEqual(input.chat?.include, serverSnapshot.chat.include)
    XCTAssertEqual(input.chat?.push, serverSnapshot.chat.push)

    XCTAssertEqual(input.follow?.include, serverSnapshot.follow.include)
    XCTAssertEqual(input.follow?.list, serverSnapshot.follow.list)
    XCTAssertEqual(input.follow?.push, serverSnapshot.follow.push)

    XCTAssertEqual(input.likeViaRepost?.include, serverSnapshot.likeViaRepost.include)
    XCTAssertEqual(input.likeViaRepost?.list, serverSnapshot.likeViaRepost.list)
    XCTAssertEqual(input.likeViaRepost?.push, serverSnapshot.likeViaRepost.push)

    XCTAssertEqual(input.mention?.include, serverSnapshot.mention.include)
    XCTAssertEqual(input.mention?.list, serverSnapshot.mention.list)
    XCTAssertEqual(input.mention?.push, serverSnapshot.mention.push)

    XCTAssertEqual(input.quote?.include, serverSnapshot.quote.include)
    XCTAssertEqual(input.quote?.list, serverSnapshot.quote.list)
    XCTAssertEqual(input.quote?.push, serverSnapshot.quote.push)

    XCTAssertEqual(input.reply?.include, serverSnapshot.reply.include)
    XCTAssertEqual(input.reply?.list, serverSnapshot.reply.list)
    XCTAssertEqual(input.reply?.push, serverSnapshot.reply.push)

    XCTAssertEqual(input.repost?.include, serverSnapshot.repost.include)
    XCTAssertEqual(input.repost?.list, serverSnapshot.repost.list)
    XCTAssertEqual(input.repost?.push, serverSnapshot.repost.push)

    XCTAssertEqual(input.repostViaRepost?.include, serverSnapshot.repostViaRepost.include)
    XCTAssertEqual(input.repostViaRepost?.list, serverSnapshot.repostViaRepost.list)
    XCTAssertEqual(input.repostViaRepost?.push, serverSnapshot.repostViaRepost.push)

    XCTAssertEqual(input.starterpackJoined?.list, serverSnapshot.starterpackJoined.list)
    XCTAssertEqual(input.starterpackJoined?.push, serverSnapshot.starterpackJoined.push)

    XCTAssertEqual(input.subscribedPost?.list, serverSnapshot.subscribedPost.list)
    XCTAssertEqual(input.subscribedPost?.push, serverSnapshot.subscribedPost.push)

    XCTAssertEqual(input.unverified?.list, serverSnapshot.unverified.list)
    XCTAssertEqual(input.unverified?.push, serverSnapshot.unverified.push)

    XCTAssertEqual(input.verified?.list, serverSnapshot.verified.list)
    XCTAssertEqual(input.verified?.push, serverSnapshot.verified.push)
  }

  func testPreferenceSummaryDescriptions() {
    let bothOnEveryone = AppBskyNotificationDefs.FilterablePreference(include: "all", list: true, push: true)
    XCTAssertEqual(bothOnEveryone.summaryDescription, "In-App, Push, Everyone")

    let pushOnlyFollows = AppBskyNotificationDefs.FilterablePreference(include: "follows", list: false, push: true)
    XCTAssertEqual(pushOnlyFollows.summaryDescription, "Push, People I follow")

    let inAppOnlyEveryone = AppBskyNotificationDefs.FilterablePreference(include: "all", list: true, push: false)
    XCTAssertEqual(inAppOnlyEveryone.summaryDescription, "In-App, Everyone")

    let allOff = AppBskyNotificationDefs.FilterablePreference(include: "follows", list: false, push: false)
    XCTAssertEqual(allOff.summaryDescription, "Off")

    let plainBothOn = AppBskyNotificationDefs.Preference(list: true, push: true)
    XCTAssertEqual(plainBothOn.summaryDescription, "In-App, Push")

    let plainInApp = AppBskyNotificationDefs.Preference(list: true, push: false)
    XCTAssertEqual(plainInApp.summaryDescription, "In-App")

    let plainPush = AppBskyNotificationDefs.Preference(list: false, push: true)
    XCTAssertEqual(plainPush.summaryDescription, "Push")

    let plainOff = AppBskyNotificationDefs.Preference(list: false, push: false)
    XCTAssertEqual(plainOff.summaryDescription, "Off")
  }
}
