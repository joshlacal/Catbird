import Foundation
import Testing

@testable import Catbird

/// The Follow button flips on tap. After the write, a header reload can still carry the old
/// relationship if the AppView has not indexed it; the button must hold what the user chose for
/// a few seconds, and must never accept a second write while one is in flight, or a second tap
/// could create a duplicate follow record.
@Suite("Profile follow writes")
@MainActor
struct ProfileFollowWritesTests {
  private let start = Date(timeIntervalSince1970: 1_760_000_000)

  @Test("A second write is refused while one is in flight")
  func refusesConcurrentWrites() {
    let writes = ProfileFollowWrites()

    #expect(writes.begin(following: true, now: start))
    #expect(!writes.begin(following: false, now: start))
    #expect(writes.isWriteInFlight)

    writes.end(success: true, now: start)
    #expect(!writes.isWriteInFlight)
    #expect(writes.begin(following: false, now: start))
  }

  @Test("While the write is in flight the button shows the chosen state")
  func inFlightShowsIntent() {
    let writes = ProfileFollowWrites()
    _ = writes.begin(following: true, now: start)

    #expect(writes.isFollowing(serverSays: false, now: start.addingTimeInterval(30)))
  }

  @Test("A stale reload inside the hold window does not flip the button back")
  func staleReloadIsHeld() {
    let writes = ProfileFollowWrites()
    _ = writes.begin(following: true, now: start)
    writes.end(success: true, now: start.addingTimeInterval(1))

    #expect(writes.isFollowing(serverSays: false, now: start.addingTimeInterval(1.5)))
    #expect(writes.isFollowing(serverSays: false, now: start.addingTimeInterval(5.9)))
  }

  @Test("After the hold window the profile's state wins")
  func holdExpires() {
    let writes = ProfileFollowWrites()
    _ = writes.begin(following: true, now: start)
    writes.end(success: true, now: start)

    #expect(!writes.isFollowing(serverSays: false, now: start.addingTimeInterval(ProfileFollowWrites.holdDuration + 0.1)))
    // The hold is gone for good, not just for that read.
    #expect(!writes.isFollowing(serverSays: false, now: start.addingTimeInterval(1)))
  }

  @Test("Once the profile agrees, the hold is dropped")
  func agreementDropsHold() {
    let writes = ProfileFollowWrites()
    _ = writes.begin(following: false, now: start)
    writes.end(success: true, now: start)

    #expect(!writes.isFollowing(serverSays: false, now: start.addingTimeInterval(0.5)))
    // A later reload, e.g. a follow made on another device, is shown as it is.
    #expect(writes.isFollowing(serverSays: true, now: start.addingTimeInterval(1)))
  }

  @Test("A failed write holds nothing, and ending it bumps the revision")
  func failureDropsIntent() {
    let writes = ProfileFollowWrites()
    let revision = writes.revision
    _ = writes.begin(following: true, now: start)
    writes.end(success: false, now: start)

    #expect(!writes.isFollowing(serverSays: false, now: start))
    #expect(writes.revision != revision)
  }

  @Test("A newer write cancels a header reload still waiting, and a scheduled reload runs once")
  func newerWriteCancelsWaitingReload() async throws {
    let writes = ProfileFollowWrites()
    let reloads = ReloadCounter()

    writes.scheduleRefresh { reloads.count += 1 }
    #expect(writes.begin(following: true))
    try await Task.sleep(for: ProfileFollowWrites.refreshDelay * 3)
    #expect(reloads.count == 0)

    writes.end(success: true)
    writes.scheduleRefresh { reloads.count += 1 }
    let deadline = ContinuousClock.now + .seconds(5)
    while reloads.count == 0, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    try await Task.sleep(for: ProfileFollowWrites.refreshDelay)
    #expect(reloads.count == 1)
  }
}

@MainActor
private final class ReloadCounter {
  var count = 0
}
