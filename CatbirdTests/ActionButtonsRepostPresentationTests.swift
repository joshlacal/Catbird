//
//  ActionButtonsRepostPresentationTests.swift
//  CatbirdTests
//

import Foundation
import Testing

@Suite("Action buttons repost presentation")
struct ActionButtonsRepostPresentationTests {
  @Test("Repost actions use a Menu pre-iOS 27, and a confirmation dialog on iOS 27+")
  func repostActionsUseMenuPresentation() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent(
        "Catbird/Features/Feed/Views/Components/ActionButtons/ActionButtonsView.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(source.contains("Menu {"), "Repost actions should still be rendered in a SwiftUI Menu pre-iOS 27.")
    #expect(!source.contains("showRepostOptions"), "The repost options sheet state should be removed.")
    #expect(source.contains("showingRepostOptions"), "iOS 27 needs the confirmation-dialog presentation state.")
    #expect(
      source.contains("repostDialogButton"),
      "iOS 27 beta ghosts stale SF Symbol layers from Menu labels (docs/feedback/repost-ghost-overlay/FEEDBACK.md); keep the confirmation-dialog workaround."
    )
    #expect(source.contains("if #available(iOS 27.0, *)"), "iOS 27+ should route repost through the confirmation-dialog workaround.")
    #expect(source.contains(".confirmationDialog("), "iOS 27's repost workaround should use confirmationDialog.")
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
