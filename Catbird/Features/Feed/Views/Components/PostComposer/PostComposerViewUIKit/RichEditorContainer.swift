//
//  RichEditorContainer.swift
//  Catbird
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct RichEditorContainer: View {
  @Binding var attributedText: NSAttributedString
  @Binding var linkFacets: [RichTextFacetUtils.LinkFacet]
  @Binding var pendingSelectionRange: NSRange?

  let placeholder: String
  let onImagePasted: (PlatformImage) -> Void
  let onGenmojiDetected: ([String]) -> Void
  let onTextChanged: (NSAttributedString, Int) -> Void
  let onLinkCreationRequested: (String, NSRange) -> Void

  let focusOnAppear: Bool
  let focusActivationID: UUID

  let onPhotosAction: () -> Void
  let onVideoAction: () -> Void
  let onAudioAction: () -> Void
  let onGifAction: () -> Void
  let onLabelsAction: () -> Void
  let onThreadgateAction: () -> Void
  let onLanguageAction: () -> Void
  let onThreadAction: () -> Void
  let onLinkAction: () -> Void

  let allowTenor: Bool
  #if os(iOS)
  var onTextViewCreated: ((UITextView) -> Void)? = nil
  #else
  var onTextViewCreated: (() -> Void)? = nil
  #endif
  @State private var editorHeight: CGFloat = 140

  var body: some View {
    EnhancedRichTextEditor(
      attributedText: $attributedText,
      linkFacets: $linkFacets,
      pendingSelectionRange: $pendingSelectionRange,
      placeholder: placeholder,
      onImagePasted: onImagePasted,
      onGenmojiDetected: onGenmojiDetected,
      onTextChanged: onTextChanged,
      onLinkCreationRequested: onLinkCreationRequested,
      focusOnAppear: focusOnAppear,
      focusActivationID: focusActivationID,
      onPhotosAction: onPhotosAction,
      onVideoAction: onVideoAction,
      onAudioAction: onAudioAction,
      onGifAction: onGifAction,
      onLabelsAction: onLabelsAction,
      onThreadgateAction: onThreadgateAction,
      onLanguageAction: onLanguageAction,
      onThreadAction: onThreadAction,
      onLinkAction: onLinkAction,
      allowTenor: allowTenor,
      onTextViewCreated: { tv in
        #if os(iOS)
        onTextViewCreated?(tv)
        #else
        _ = onTextViewCreated?()
        #endif
      },
      onHeightChange: { newHeight in
        // Allow height to grow dynamically, with a reasonable minimum
        let clamped = max(newHeight, 140)
        if abs(clamped - editorHeight) > 1 {
          editorHeight = clamped
        }
      }
    )
    .frame(minHeight: editorHeight)
  }
}
