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
    #expect(hostingController.view.contentHuggingPriority(for: .vertical) == .required)
    #expect(hostingController.view.contentCompressionResistancePriority(for: .vertical) == .required)
  }
  @Test("Reply content resists a full-screen vertical proposal and still wraps")
  func promptKeepsNaturalHeight() {
    let host = ThreadViewController.makeComposePromptHostingController(
      rootView: AnyView(
        Text("Write your reply with enough text to wrap at a narrow width")
          .font(.body)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
      )
    )
    let wide = host.sizeThatFits(in: CGSize(width: 390, height: 800))
    let narrow = host.sizeThatFits(in: CGSize(width: 180, height: 800))
    #expect(wide.height < 200)
    #expect(narrow.height > wide.height)
    #expect(narrow.height < 400)
  }
}
