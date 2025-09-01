//
//  EnhancedRichTextEditor.swift
//  Catbird
//
//  Created by Josh LaCalamito on 12/18/23.
//

import SwiftUI
import Petrel
import os

#if os(iOS)
import UIKit

// MARK: - Custom UITextView with Link Menu Support

class LinkEditableTextView: UITextView {
    weak var linkCreationDelegate: LinkCreationDelegate?
    var requestFocusOnAttach: Bool = false
    
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        
        // Only add "Create Link" if there's selected text
        guard selectedRange.length > 0,
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.debug("📝 buildMenu: No valid text selected")
            return
        }
        
        logger.debug("📝 buildMenu: Adding Create Link action for selected text: '\(self.selectedText)'")
        
        let createLinkAction = UIAction(
            title: "Create Link",
            image: UIImage(systemName: "link"),
            identifier: UIAction.Identifier("createLink")
        ) { [weak self] _ in
            guard let self = self else { return }
            let capturedText = self.selectedText
            let capturedRange = self.selectedRange
            logger.debug("📝 Create Link action triggered with text: '\(capturedText)' range: \(capturedRange)")
            self.linkCreationDelegate?.requestLinkCreation(for: capturedText, in: capturedRange)
        }
        
        // Add our custom action to the standard edit menu
        let linkMenu = UIMenu(title: "", options: .displayInline, children: [createLinkAction])
        builder.insertSibling(linkMenu, afterMenu: .standardEdit)
    }
    
    private var selectedText: String {
        guard selectedRange.length > 0,
              let textRange = selectedTextRange else { return "" }
        return text(in: textRange) ?? ""
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if requestFocusOnAttach, window != nil {
            DispatchQueue.main.async { [weak self] in
                _ = self?.becomeFirstResponder()
            }
        }
    }
}

// MARK: - Link Creation Protocol

protocol LinkCreationDelegate: AnyObject {
    func requestLinkCreation(for text: String, in range: NSRange)
}

// MARK: - Enhanced Rich Text Editor with Link Support

struct EnhancedRichTextEditor: UIViewRepresentable {
  @Binding var attributedText: NSAttributedString
  @Binding var linkFacets: [RichTextFacetUtils.LinkFacet]
  
  let placeholder: String
  let onImagePasted: (UIImage) -> Void
  let onGenmojiDetected: ([String]) -> Void
  let onTextChanged: (NSAttributedString) -> Void
  let onLinkCreationRequested: (String, NSRange) -> Void
  var focusOnAppear: Bool = false
  // When this value changes, we explicitly request first responder again
  var focusActivationID: UUID? = nil
  
  
  func makeUIView(context: Context) -> UITextView {
    let textView = LinkEditableTextView()
    textView.delegate = context.coordinator
    textView.linkCreationDelegate = context.coordinator
    textView.requestFocusOnAttach = focusOnAppear
    textView.font = getAppropriateFont()
    // Ensure newly typed text uses the desired font
    if let font = textView.font {
      textView.typingAttributes[.font] = font
    }
    textView.backgroundColor = .clear
    textView.isScrollEnabled = true
    textView.isEditable = true
    textView.isUserInteractionEnabled = true
    textView.textContainer.lineFragmentPadding = 0
    textView.textContainerInset = .zero
    
    // Enable link detection and interaction
    textView.linkTextAttributes = [
      .foregroundColor: UIColor.systemBlue,
      .underlineStyle: NSUnderlineStyle.single.rawValue
    ]
    
    // Debug: Creation log removed to avoid noisy repeated logs during re-render cycles
    // Set focus request flag - the textView will handle this in didMoveToWindow
    textView.requestFocusOnAttach = focusOnAppear
    return textView
  }
  
  private func getAppropriateFont() -> UIFont {
    // Use the same approach as RichTextEditor for consistency
    return UIFont.preferredFont(forTextStyle: UIFont.TextStyle.body)
  }
  
  func updateUIView(_ uiView: UITextView, context: Context) {
    // Update font if needed
    let newFont = getAppropriateFont()
    if uiView.font != newFont {
      uiView.font = newFont
      uiView.typingAttributes[.font] = newFont
      context.coordinator.updateFontRelatedSettings(in: uiView)
    }
    
    if uiView.attributedText != attributedText {
      let previousSelectedRange = uiView.selectedRange
      // Ensure displayed text has a font attribute; UITextView.font is ignored
      // when setting attributedText, so we apply a default font to ranges missing it.
      let displayText = context.coordinator.applyingDefaultFontIfMissing(
        attributedText,
        defaultFont: newFont
      )
      uiView.attributedText = displayText
      
      // Restore selection if possible
      if previousSelectedRange.location <= uiView.text.count {
        uiView.selectedRange = previousSelectedRange
      }
    }
    
    // Update placeholder
    context.coordinator.updatePlaceholder(placeholder, in: uiView)

    // Handle explicit focus re-activation
    if context.coordinator.lastFocusID != focusActivationID, let _ = focusActivationID {
      context.coordinator.lastFocusID = focusActivationID
      DispatchQueue.main.async {
        _ = uiView.becomeFirstResponder()
      }
    }
  }
  
  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }
  
  
  class Coordinator: NSObject, UITextViewDelegate, LinkCreationDelegate {
    let parent: EnhancedRichTextEditor
    private var placeholderLabel: UILabel?
    private var isSanitizing = false
    private let rtLogger = Logger(subsystem: "blue.catbird", category: "RichText.Legacy")
    var lastFocusID: UUID? = nil
    
    init(_ parent: EnhancedRichTextEditor) {
      self.parent = parent
      super.init()
    }
    
    func textViewDidChange(_ textView: UITextView) {
      // Sanitize to keep only link attributes
      if !isSanitizing {
        let sanitized = textView.attributedText.ctb_keepOnlyLinkAttribute()
        if sanitized != textView.attributedText {
          // Prevent recursion
          isSanitizing = true
          let previousSelectedRange = textView.selectedRange
          // Ensure the displayed text maintains the default font
            let font = textView.font ?? UIFont.preferredFont(forTextStyle: UIFont.TextStyle.body)
          let withFont = applyingDefaultFontIfMissing(sanitized, defaultFont: font)
          textView.attributedText = withFont
          // Restore selection if possible
          if previousSelectedRange.location <= textView.text.count {
            textView.selectedRange = previousSelectedRange
          }
          isSanitizing = false
        }
      }

      // Debug summary
      let counts = summarizeNS(textView.attributedText)
      rtLogger.debug("Legacy change: len=\(textView.text.count), runs=\(counts.runs), linkRuns=\(counts.linkRuns)")

      // Update attributed text binding (already sanitized)
      parent.attributedText = textView.attributedText
      
      // Update link facets based on text changes
      updateLinkFacetsForTextChange(in: textView)
      
      // Call text changed callback
      parent.onTextChanged(textView.attributedText)
      
      // Update placeholder visibility
      updatePlaceholder(parent.placeholder, in: textView)
      
      // Detect genmoji
      detectGenmoji(in: textView.text)
    }
    
    // MARK: - LinkCreationDelegate
    
    func requestLinkCreation(for text: String, in range: NSRange) {
      logger.debug("📝 Coordinator: Link creation requested with text: '\(text)' range: \(range)")
      parent.onLinkCreationRequested(text, range)
    }
    
    func textView(_ textView: UITextView, shouldInteractWith textAttachment: NSTextAttachment, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
      if interaction == .invokeDefaultAction {
        // Handle image paste
        if let image = textAttachment.image {
          parent.onImagePasted(image)
          return false
        }
      }
      return true
    }
    
    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
      if interaction == .invokeDefaultAction {
        // Handle link taps - you might want to open URLs or show edit options
        rtLogger.debug("Legacy tap URL=\(URL.absoluteString) range=\(characterRange.debugDescription)")
        return false
      }
      return true
    }
    
    func textViewDidChangeSelection(_ textView: UITextView) {
      // Handle text selection changes
      let selectedRange = textView.selectedRange
      logger.debug("📝 Text selection changed: \(selectedRange)")
      
      // The UIEditMenuInteraction will handle showing the menu automatically
      // when appropriate (e.g., after a long press or double-tap selection)
      if selectedRange.length > 0 {
        logger.debug("📝 Text is selected, length: \(selectedRange.length)")
        // Text is selected - menu will appear on appropriate gesture
      } else {
        logger.debug("📝 No text selected")
      }
    }
    
    private func updateLinkFacetsForTextChange(in textView: UITextView) {
      // This would need more sophisticated logic to track text changes
      // and update link facet ranges accordingly
      // For now, we'll regenerate them from the attributed text
      
      let newFacets = extractLinkFacetsFromAttributedText(textView.attributedText)
      parent.linkFacets = newFacets
      rtLogger.debug("Legacy facets updated: count=\(newFacets.count)")
    }
    
    private func extractLinkFacetsFromAttributedText(_ attributedText: NSAttributedString) -> [RichTextFacetUtils.LinkFacet] {
      var facets: [RichTextFacetUtils.LinkFacet] = []
      
      attributedText.enumerateAttribute(.link, in: NSRange(location: 0, length: attributedText.length)) { value, range, _ in
        if let url = value as? URL {
          let displayText = attributedText.attributedSubstring(from: range).string
          let facet = RichTextFacetUtils.LinkFacet(
            range: range,
            url: url,
            displayText: displayText
          )
          facets.append(facet)
        }
      }
      
      return facets
    }
    
    func updatePlaceholder(_ placeholder: String, in textView: UITextView) {
      if placeholderLabel == nil {
        let label = UILabel()
        placeholderLabel = label
        // Match the typing font exactly (falls back to textView.font)
        let typingFont = (textView.typingAttributes[.font] as? UIFont) ?? textView.font
        label.font = typingFont
        label.textColor = .placeholderText
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        label.text = placeholder
        textView.addSubview(label)

        label.translatesAutoresizingMaskIntoConstraints = false

        // Align the placeholder to the actual text region.
        // Using textLayoutGuide ensures perfect alignment with the caret/text,
        // regardless of textContainerInset, contentInset, or padding.
          let guide = textView.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
          label.topAnchor.constraint(equalTo: guide.topAnchor),
          label.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
          label.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor)
        ])
      }

      // Keep font in sync with current typing attributes
      if let currentTypingFont = (textView.typingAttributes[.font] as? UIFont) ?? textView.font {
        placeholderLabel?.font = currentTypingFont
      }
      placeholderLabel?.isHidden = !textView.text.isEmpty
    }
    
    private func detectGenmoji(in text: String) {
      // Simple genmoji detection - look for :emoji_name: patterns
      let pattern = ":[a-zA-Z0-9_]+:"
      let regex = try? NSRegularExpression(pattern: pattern)
      let matches = regex?.matches(in: text, range: NSRange(location: 0, length: text.count)) ?? []
      
      let genmojis = matches.compactMap { match in
        (text as NSString).substring(with: match.range)
      }
      
      if !genmojis.isEmpty {
        parent.onGenmojiDetected(genmojis)
      }
    }
    
    func updateFontRelatedSettings(in textView: UITextView) {
      // Update placeholder font when textView font or typing attributes change
      let typingFont = (textView.typingAttributes[.font] as? UIFont) ?? textView.font
      placeholderLabel?.font = typingFont
      if let font = textView.font {
        textView.typingAttributes[.font] = font
      }
    }

    // Apply a default font to any ranges that lack an explicit font attribute.
    func applyingDefaultFontIfMissing(_ source: NSAttributedString, defaultFont: UIFont) -> NSAttributedString {
      let mutable = NSMutableAttributedString(attributedString: source)
      var location = 0
      while location < mutable.length {
        var range = NSRange(location: 0, length: 0)
        let attrs = mutable.attributes(at: location, effectiveRange: &range)
        if attrs[.font] == nil {
          var newAttrs = attrs
          newAttrs[.font] = defaultFont
          mutable.setAttributes(newAttrs, range: range)
        }
        location = range.location + range.length
      }
      return mutable
    }
  }
}


#else

// macOS stub for EnhancedRichTextEditor
struct EnhancedRichTextEditor: View {
  @Binding var attributedText: NSAttributedString
  @Binding var linkFacets: [RichTextFacetUtils.LinkFacet]
  
  let placeholder: String
  let onImagePasted: (NSImage) -> Void
  let onGenmojiDetected: ([String]) -> Void
  let onTextChanged: (NSAttributedString) -> Void
  let onLinkCreationRequested: (String, NSRange) -> Void
  
  var body: some View {
    Text("Rich text editing not available on macOS")
      .foregroundColor(.secondary)
  }
}

#endif

// MARK: - NSAttributedString Sanitizer (links-only)

private extension NSAttributedString {
  /// Returns a copy of the receiver where only the `.link` attribute is preserved
  /// for each attributed run. All other attributes are stripped.
  func ctb_keepOnlyLinkAttribute() -> NSAttributedString {
    let mutable = NSMutableAttributedString(attributedString: self)
    var location = 0
    while location < mutable.length {
      var range = NSRange(location: 0, length: 0)
      let attrs = mutable.attributes(at: location, effectiveRange: &range)
      if let link = attrs[.link] {
        mutable.setAttributes([.link: link], range: range)
      } else {
        mutable.setAttributes([:], range: range)
      }
      location = range.location + range.length
    }
    return mutable
  }
}

private func summarizeNS(_ ns: NSAttributedString) -> (runs: Int, linkRuns: Int) {
  var runs = 0
  var linkRuns = 0
  ns.enumerateAttributes(in: NSRange(location: 0, length: ns.length)) { attrs, _, _ in
    runs += 1
    if attrs[.link] != nil { linkRuns += 1 }
  }
  return (runs, linkRuns)
}
