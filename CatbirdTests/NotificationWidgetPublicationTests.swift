//
//  NotificationWidgetPublicationTests.swift
//  CatbirdTests
//

import Foundation
import Testing
@testable import Catbird

@Suite("Notification widget publication")
struct NotificationWidgetPublicationTests {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("The first count is always published")
  func firstCountPublishes() {
    let publication = NotificationWidgetPublication()
    #expect(publication.shouldPublish(0, now: start))
  }

  @Test("An unchanged count inside the refresh interval is skipped")
  func unchangedCountSkipped() {
    let publication = NotificationWidgetPublication()
    #expect(publication.shouldPublish(3, now: start))
    #expect(!publication.shouldPublish(3, now: start.addingTimeInterval(1)))
    #expect(!publication.shouldPublish(
      3, now: start.addingTimeInterval(NotificationWidgetPublication.refreshInterval - 1)))
  }

  @Test("A changed count is published immediately")
  func changedCountPublishes() {
    let publication = NotificationWidgetPublication()
    #expect(publication.shouldPublish(3, now: start))
    #expect(publication.shouldPublish(0, now: start.addingTimeInterval(1)))
    #expect(publication.shouldPublish(3, now: start.addingTimeInterval(2)))
  }

  @Test("An unchanged count is republished once the refresh interval passes")
  func staleCountRepublishes() {
    let publication = NotificationWidgetPublication()
    #expect(publication.shouldPublish(3, now: start))
    let later = start.addingTimeInterval(NotificationWidgetPublication.refreshInterval)
    #expect(publication.shouldPublish(3, now: later))
    #expect(!publication.shouldPublish(3, now: later.addingTimeInterval(1)))
  }

  @Test("Reset forces the next count to publish")
  func resetForcesPublish() {
    let publication = NotificationWidgetPublication()
    #expect(publication.shouldPublish(0, now: start))
    publication.reset()
    #expect(publication.shouldPublish(0, now: start.addingTimeInterval(1)))
  }
}
