import Testing
@testable import Catbird

/// The backup screen says "On" only when something exists on the server.
@Suite("Labyrinth Backup Status Label Tests")
struct LabyrinthBackupStatusLabelTests {
  @Test("A new account that has stored nothing yet is setting up, not on")
  func newAccountIsSettingUp() {
    #expect(LabyrinthSettingsAndRestoreView.backupStatusLabel(enabled: true, established: false) == "Setting Up")
  }

  @Test("An account whose archive exists on the server is on")
  func establishedAccountIsOn() {
    #expect(LabyrinthSettingsAndRestoreView.backupStatusLabel(enabled: true, established: true) == "On")
  }

  @Test("Disabled backup is off whatever exists")
  func disabledIsOff() {
    #expect(LabyrinthSettingsAndRestoreView.backupStatusLabel(enabled: false, established: true) == "Off")
    #expect(LabyrinthSettingsAndRestoreView.backupStatusLabel(enabled: false, established: false) == "Off")
  }
}
