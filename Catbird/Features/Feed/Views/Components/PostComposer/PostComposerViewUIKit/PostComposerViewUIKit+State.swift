//
//  PostComposerViewUIKit+State.swift
//  Catbird
//

import SwiftUI
import Petrel
#if os(iOS)
import UIKit
#endif

extension PostComposerViewUIKit {
  enum DismissReason {
    case none, discard, submit
  }

  func presentLinkCreation(
    vm: PostComposerViewModel,
    suggestedRange: NSRange? = nil
  ) {
    #if os(iOS)
    let requestedRange = vm.activeRichTextView?.selectedRange ?? suggestedRange
    #else
    let requestedRange = suggestedRange
    #endif

    linkSelection = ComposerLinkEdit.selection(
      requestedRange: requestedRange,
      in: vm.richAttributedText
    )
    showingLinkCreation = true
  }
}
