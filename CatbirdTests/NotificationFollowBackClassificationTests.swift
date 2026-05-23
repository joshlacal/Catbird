//
//  NotificationFollowBackClassificationTests.swift
//  CatbirdTests
//

import XCTest
import Foundation
@testable import Catbird

final class NotificationFollowBackClassificationTests: XCTestCase {

  func testFollowBackRequiresViewerFollowBeforeInboundFollow() {
    let inboundFollowDate = Date(timeIntervalSince1970: 2_000)
    let earlierViewerFollowDate = Date(timeIntervalSince1970: 1_000)
    let laterViewerFollowDate = Date(timeIntervalSince1970: 3_000)

    XCTAssertEqual(NotificationsViewModel.classifyFollowNotification(
      inboundFollowCreatedAt: inboundFollowDate,
      viewerFollowCreatedAt: earlierViewerFollowDate
    ), .followBack)

    XCTAssertEqual(NotificationsViewModel.classifyFollowNotification(
      inboundFollowCreatedAt: inboundFollowDate,
      viewerFollowCreatedAt: laterViewerFollowDate
    ), .follow)
  }

  func testFollowWithoutComparableTimestampsIsPlainFollow() {
    XCTAssertEqual(NotificationsViewModel.classifyFollowNotification(
      inboundFollowCreatedAt: Date(timeIntervalSince1970: 2_000),
      viewerFollowCreatedAt: nil
    ), .follow)

    XCTAssertEqual(NotificationsViewModel.classifyFollowNotification(
      inboundFollowCreatedAt: nil,
      viewerFollowCreatedAt: Date(timeIntervalSince1970: 1_000)
    ), .follow)
  }
}
