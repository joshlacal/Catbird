//
//  ActionButtonsRepostPresentationTests.swift
//  CatbirdTests
//

import Foundation
import Testing

@Suite("Action buttons repost presentation")
struct ActionButtonsRepostPresentationTests {
  @Test("Repost actions are presented as a menu on every supported OS")
  func repostActionsUseMenuPresentation() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent(
        "Catbird/Features/Feed/Views/Components/ActionButtons/ActionButtonsView.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(source.contains("Menu {"), "Repost actions should be rendered in a SwiftUI Menu.")
    #expect(!source.contains("showRepostOptions"), "The repost options sheet state should be removed.")
    // The iOS 27 Menu ghost-overlay compositor bug was fixed in beta 3, so the
    // Button+confirmationDialog workaround was reverted — the plain Menu is used
    // on every supported OS again (see docs/feedback/repost-ghost-overlay/FEEDBACK.md).
    #expect(!source.contains("showingRepostOptions"), "The repost options dialog state should be removed.")
    #expect(!source.contains("repostDialogButton"), "The iOS 27 confirmation-dialog workaround should be removed.")
    #expect(!source.contains("if #available(iOS 27.0, *)"), "iOS 27 should use the same Menu path again.")
    #expect(!source.contains(".confirmationDialog("), "Repost options should not use confirmationDialog.")
    #expect(!source.contains("RepostOptionsView(post: post, viewModel: viewModel)"))

    guard let repostMenuRange = source.range(of: "private var repostMenu: some View"),
      let repostActionTitleRange = source.range(of: "private var repostActionTitle")
    else {
      Issue.record("ActionButtonsView should keep repost menu helpers readable for regression checks.")
      return
    }

    let repostMenuSource = String(source[repostMenuRange.lowerBound..<repostActionTitleRange.lowerBound])
    #expect(
      repostMenuSource.contains("Image(systemName: \"arrow.2.squarepath\")"),
      "The repost menu trigger should be a stable SF Symbol label, matching PostView's ellipsis menu pattern."
    )
    #expect(
      repostMenuSource.contains(".contentShape(Rectangle())"),
      "The repost menu label should own its tappable shape like PostView's ellipsis menu."
    )
    #expect(
      !repostMenuSource.contains("InteractionButtonLabel"),
      "Avoid nesting the animated interaction label inside Menu; iOS 27 beta can cache that Menu label across tabs."
    )
    #expect(
      !repostMenuSource.contains("accessibleScaleEffect"),
      "Avoid animating/scaling the Menu container itself; keep animation outside the Menu presentation bridge."
    )
  }
}
