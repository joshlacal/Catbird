import Testing
@testable import Catbird

@Suite("FAB Quick Action Tests")
struct FABQuickActionTests {
  @Test("Compose menu exposes exactly the four recovered actions in order")
  func recoveredActions() {
    #expect(FABQuickAction.allCases == [.newPost, .browseDrafts, .takePhoto, .recordVideo])
    #expect(FABQuickAction.allCases.map(\.title) == [
      "New Post",
      "Browse Drafts",
      "Take Photo",
      "Record Video",
    ])
    #expect(FABQuickAction.productionMenuActions == FABQuickAction.allCases)
  }

  @Test("Camera capture modes have stable distinct identities")
  func cameraModeIdentity() {
    #expect(CameraCaptureMode.photo.id != CameraCaptureMode.video.id)
  }
}
