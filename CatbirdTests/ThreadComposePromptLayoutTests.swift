import SwiftUI
import Testing
import UIKit
@testable import Catbird

@Suite("Thread compose prompt layout")
@MainActor
struct ThreadComposePromptLayoutTests {
  @Test("Quick reply host uses its intrinsic content height")
  func quickReplyHostUsesIntrinsicContentHeight() {
    let hostingController = ThreadViewController.makeComposePromptHostingController(
      rootView: AnyView(Text("Write your reply"))
    )

    #expect(hostingController.sizingOptions.contains(.intrinsicContentSize))
  }
}
