import Foundation
import Testing
@testable import Catbird

@MainActor
@Suite("URL handling outcome")
struct URLHandlerOutcomeTests {
  @Test("Hashtags are handled in app")
  func hashtagHandled() {
    let handler = URLHandler()
    handler.navigateAction = { _, _ in }
    #expect(handler.outcome(for: URL(string: "tag://swift")!) == .handled)
  }

  @Test("Web links open in the system browser when the in-app browser is off")
  func webLinkOpensInSystem() {
    let handler = URLHandler()
    handler.useInAppBrowser = false
    #expect(handler.outcome(for: URL(string: "https://example.com/a")!) == .openInSystem)
  }

  @Test("Unsupported schemes are discarded")
  func unsupportedDiscarded() {
    let handler = URLHandler()
    #expect(handler.outcome(for: URL(string: "javascript:alert(1)")!) == .discarded)
  }
}
