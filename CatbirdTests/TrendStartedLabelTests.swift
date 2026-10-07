import Foundation
import Testing
@testable import Catbird

@Suite("Trend started label")
struct TrendStartedLabelTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func label(ago seconds: TimeInterval) -> String {
    TrendStartedLabel.text(since: now.addingTimeInterval(-seconds), now: now)
  }

  @Test("Minutes and hours read as before")
  func minutesAndHours() {
    #expect(label(ago: 20) == "just now")
    #expect(label(ago: 60) == "1 min ago")
    #expect(label(ago: 45 * 60) == "45 mins ago")
    #expect(label(ago: 3_600) == "1 hour ago")
    #expect(label(ago: 23 * 3_600 + 59 * 60) == "23 hours ago")
  }

  @Test("A day or more rolls over to days instead of hundreds of hours")
  func days() {
    #expect(label(ago: 24 * 3_600) == "1 day ago")
    #expect(label(ago: 264 * 3_600) == "11 days ago")
  }

  @Test("A start time in the future reads as just now")
  func futureStart() {
    #expect(label(ago: -300) == "just now")
  }
}
