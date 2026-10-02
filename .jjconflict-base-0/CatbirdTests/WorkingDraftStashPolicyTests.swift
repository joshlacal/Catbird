import Testing
@testable import Catbird

@Suite("Working Draft Stash Policy Tests")
struct WorkingDraftStashPolicyTests {
  @MainActor
  @Test("Unavailable destination does not save or clear")
  func unavailableDestinationDoesNotMutateDraft() async {
    var events: [String] = []

    let result = await WorkingDraftStashPolicy.perform(
      hasWorkingDraft: true,
      destinationAvailable: false,
      save: {
        events.append("save")
        return true
      },
      clearAfterSave: { events.append("clear") }
    )

    #expect(result == .destinationUnavailable)
    #expect(events.isEmpty)
  }

  @MainActor
  @Test("Failed durable save leaves working draft intact")
  func failedSaveDoesNotClear() async {
    var events: [String] = []

    let result = await WorkingDraftStashPolicy.perform(
      hasWorkingDraft: true,
      destinationAvailable: true,
      save: {
        events.append("save")
        return false
      },
      clearAfterSave: { events.append("clear") }
    )

    #expect(result == .saveFailed)
    #expect(events == ["save"])
  }

  @MainActor
  @Test("Successful durable save clears only after completion")
  func successfulSaveClearsAfterSave() async {
    var events: [String] = []

    let result = await WorkingDraftStashPolicy.perform(
      hasWorkingDraft: true,
      destinationAvailable: true,
      save: {
        events.append("save")
        return true
      },
      clearAfterSave: { events.append("clear") }
    )

    #expect(result == .stashed)
    #expect(events == ["save", "clear"])
  }
}
