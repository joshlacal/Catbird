import Testing

@testable import Catbird

/// The AppView reports `viewer.muted` as true for a direct mute or for a mute that comes from
/// a subscribed mute list. Only a direct mute can be undone with Unmute, so a list-muted
/// profile asks the graph whether it is also muted directly; every other profile answers from
/// its viewer state and must not trigger a mute-list scan.
@Suite("Profile mute menu state")
@MainActor
struct ProfileMuteStateTests {
  @Test("A directly muted profile says Unmute without a lookup")
  func directMuteNeedsNoLookup() async {
    var lookups = 0
    let state = await UnifiedProfileView.directMuteState(muted: true, isListMuted: false) {
      lookups += 1
      return false
    }
    #expect(state)
    #expect(lookups == 0)
  }

  @Test("A profile with no mute says Mute without a lookup")
  func unmutedNeedsNoLookup() async {
    var lookups = 0
    let state = await UnifiedProfileView.directMuteState(muted: nil, isListMuted: false) {
      lookups += 1
      return true
    }
    #expect(!state)
    #expect(lookups == 0)
  }

  @Test("A list-muted profile follows the direct-mute lookup, asked once")
  func listMuteAsksTheGraph() async {
    for direct in [true, false] {
      var lookups = 0
      let state = await UnifiedProfileView.directMuteState(muted: true, isListMuted: true) {
        lookups += 1
        return direct
      }
      #expect(state == direct)
      #expect(lookups == 1)
    }
  }
}
