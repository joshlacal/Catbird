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
        if requestFocusOnAttach, window != nil, !isFirstResponder {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.isFirstResponder else { return }
                _ = self.becomeFirstResponder()
                // Only request focus once on attach; avoid repeated "relaunch" effects
                self.requestFocusOnAttach = false
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
  // Optional: when set, the editor will move the caret to this range, then clear it.
  @Binding var pendingSelectionRange: NSRange?
  
  let placeholder: String
  let onImagePasted: (UIImage) -> Void
  let onGenmojiDetected: ([String]) -> Void
  let onTextChanged: (NSAttributedString, Int) -> Void
  let onLinkCreationRequested: (String, NSRange) -> Void
  var focusOnAppear: Bool = false
  // When this value changes, we explicitly request first responder again
  var focusActivationID: UUID? = nil
  
  // Keyboard toolbar actions
  var onPhotosAction: (() -> Void)?
  var onVideoAction: (() -> Void)?
  var onAudioAction: (() -> Void)?
  var onGifAction: (() -> Void)?
  var onLabelsAction: (() -> Void)?
  var onThreadgateAction: (() -> Void)?
  var onLanguageAction: (() -> Void)?
  var onThreadAction: (() -> Void)?
  var onLinkAction: (() -> Void)?
  var allowTenor: Bool = false

  // Optional callback to receive the created UITextView
  // Used to wire up activeRichTextView reference in PostComposerViewModel
  var onTextViewCreated: ((UITextView) -> Void)?
  
  // Public method to sanitize text (call before submission)
  static func sanitizeTextView(_ textView: UITextView) {
    let sanitized = textView.attributedText.ctb_keepOnlyLinkAttribute()
    if sanitized != textView.attributedText {
      let previousSelectedRange = textView.selectedRange
      let font = textView.font ?? UIFont.preferredFont(forTextStyle: UIFont.TextStyle.body)
      let withFont = applyDefaultFontIfMissing(sanitized, defaultFont: font)
      textView.attributedText = withFont
      if previousSelectedRange.location <= textView.text.count {
        textView.selectedRange = previousSelectedRange
      }
    }
  }
  
  private static func applyDefaultFontIfMissing(_ source: NSAttributedString, defaultFont: UIFont) -> NSAttributedString {
    let mutable = NSMutableAttributedString(attributedString: source)
    var location = 0
    while location < mutable.length {
      var range = NSRange(location: 0, length: 0)
      let attrs = mutable.attributes(at: location, effectiveRange: &range)
      var needsUpdate = false
      var newAttrs = attrs
      
      if attrs[.font] == nil {
        newAttrs[.font] = defaultFont
        needsUpdate = true
      }
      
      if attrs[.foregroundColor] == nil {
        newAttrs[.foregroundColor] = UIColor.label
        needsUpdate = true
      }
      
      if needsUpdate {
        mutable.setAttributes(newAttrs, range: range)
      }
      
      location = range.location + range.length
    }
    return mutable
  }


  func makeUIView(context: Context) -> UITextView {
    let textView = LinkEditableTextView()
    textView.delegate = context.coordinator
    textView.linkCreationDelegate = context.coordinator
    textView.requestFocusOnAttach = focusOnAppear
    textView.font = getAppropriateFont()
    // Ensure newly typed text uses the desired font and text color
    if let font = textView.font {
      textView.typingAttributes[.font] = font
      textView.typingAttributes[.foregroundColor] = UIColor.label
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
    
    // iOS text input configuration for better UX
    textView.autocorrectionType = .yes
    textView.spellCheckingType = .yes
    textView.smartQuotesType = .yes
    textView.smartDashesType = .yes
    textView.smartInsertDeleteType = .yes
    textView.keyboardType = .default
    textView.returnKeyType = .default
    textView.textContentType = nil  // No specific content type for social posts
    
    // iOS 18+: Enable Writing Tools for AI-powered text editing
    if #available(iOS 18.0, *) {
      textView.writingToolsBehavior = .complete
      textView.allowedWritingToolsResultOptions = [
        .plainText, // Plain text formatting
        .richText,  // Rich text with links (important for Bluesky posts!)
        .list       // Bullet/numbered lists
      ]
      
      // Enable Genmoji support
      textView.supportsAdaptiveImageGlyph = true
      
      // Configure paste behavior for social media posts
      let pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [
        "public.plain-text",
        "public.html",
        "public.url",
        "public.image",
        "com.apple.adaptive-image-glyph"
      ])
      textView.pasteConfiguration = pasteConfiguration
      textView.pasteDelegate = context.coordinator
    }
    
    // Set up custom keyboard accessory view with Liquid Glass toolbar
    #if targetEnvironment(macCatalyst)
    // On Mac Catalyst, anchor the toolbar at the bottom of the sheet/content instead of inputAccessoryView
    DispatchQueue.main.async { [weak coord = context.coordinator, weak tv = textView] in
      guard let coord, let tv else { return }
      coord.installCatalystBottomToolbar(for: tv)
    }
    #else
    textView.inputAccessoryView = context.coordinator.createKeyboardAccessoryView()
    #endif
    
    // Debug: Creation log removed to avoid noisy repeated logs during re-render cycles
    // Set focus request flag - the textView will handle this in didMoveToWindow
    textView.requestFocusOnAttach = focusOnAppear

    // Notify the callback that the text view was created
    onTextViewCreated?(textView)

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
      context.coordinator.updateFontRelatedSettings(in: uiView)
    }
    
    // CRITICAL: Skip ALL updates during IME composition (markedTextRange != nil)
    // IME is used by Chinese, Japanese, Korean, and other input methods that require
    // multi-keystroke character composition. Modifying attributedText during composition
    // forces premature character confirmation and breaks the input experience.
    // iOS 18+ best practice: Always check markedTextRange before text modifications.
    if uiView.markedTextRange != nil {
      return
    }
    
    // Only update if text actually changed
    let textChanged = uiView.attributedText.string != attributedText.string
    let needsFullUpdate = textChanged || context.coordinator.needsAttributeSync
    
    // Update text view when content changes, even if it's the first responder
    // This ensures draft restoration works correctly
    if needsFullUpdate {
      let previousSelectedRange = uiView.selectedRange
      let displayText = context.coordinator.applyingDefaultFontIfMissing(
        attributedText,
        defaultFont: newFont
      )
      
      // Only update attributed text if not currently editing to avoid disrupting typing
      // Exception: Always update if text content differs (e.g., draft restoration)
      if !uiView.isFirstResponder || textChanged {
        uiView.attributedText = displayText
        
        // Restore selection only if no pending selection
        if pendingSelectionRange == nil {
          if previousSelectedRange.location <= (uiView.text as NSString).length {
            uiView.selectedRange = previousSelectedRange
          }
        }
      }
      context.coordinator.needsAttributeSync = false
    }

    // Update placeholder
    context.coordinator.updatePlaceholder(placeholder, in: uiView)

    // While typing (first responder), avoid wholesale text replacement to
    // keep IME + cursor stable, but do copy visual attributes (links, colors)
    // from the source attributed text when strings match.
    // This restores facet-based highlighting (mentions, hashtags, links)
    // without resetting selection.
    if uiView.isFirstResponder,
       uiView.markedTextRange == nil,
       uiView.text == attributedText.string {
      context.coordinator.applyVisualAttributes(from: attributedText, to: uiView)
    }

    // Handle explicit focus re-activation
    if context.coordinator.lastFocusID != focusActivationID, let _ = focusActivationID {
      context.coordinator.lastFocusID = focusActivationID
      if !uiView.isFirstResponder {
        DispatchQueue.main.async {
          _ = uiView.becomeFirstResponder()
        }
      }
    }

    // Apply any requested selection change (e.g., after inserting a link or mention)
    if let requested = pendingSelectionRange {
      // IME Guard: Prevent selection changes during multi-keystroke character composition
      guard uiView.markedTextRange == nil else { return }
      let total = (uiView.text as NSString).length
      let safeLoc = max(0, min(requested.location, total))
      let safeLen = max(0, min(requested.length, total - safeLoc))
      uiView.selectedRange = NSRange(location: safeLoc, length: safeLen)
      // Ensure typing attributes are reset to standard (non-link) after moving the caret
      let font = uiView.font ?? getAppropriateFont()
      uiView.typingAttributes = [
        .font: font,
        .foregroundColor: UIColor.label
      ]
      // Clear the request so it only applies once
      DispatchQueue.main.async {
        self.pendingSelectionRange = nil
      }
    }
  }
  
  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }
  
  
  class Coordinator: NSObject, UITextViewDelegate, LinkCreationDelegate, UITextPasteDelegate {
    let parent: EnhancedRichTextEditor
  #if targetEnvironment(macCatalyst)
  // Stored on coordinator to keep UIKit ownership semantics
  private weak var catalystToolbarContainer: UIView?
  #endif

    private var placeholderLabel: UILabel?
    var needsAttributeSync = false
    var lastTextSnapshot: String = ""
    
  #if targetEnvironment(macCatalyst)
  fileprivate func installCatalystBottomToolbar(for textView: UITextView) {
    if catalystToolbarContainer != nil { return }
    guard let accessory = makeCatalystAccessoryView() else { return }

    // Prefer attaching to the window to avoid adding subviews to UIHostingController.view
    guard let hostWindow = textView.window else { return }

    accessory.translatesAutoresizingMaskIntoConstraints = false
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.backgroundColor = .clear
    hostWindow.addSubview(container)
    container.addSubview(accessory)

    // Size using fitting height
    let targetSize = accessory.systemLayoutSizeFitting(
      CGSize(width: hostWindow.bounds.width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )
    let heightConstraint = container.heightAnchor.constraint(equalToConstant: max(44, targetSize.height))
    heightConstraint.priority = .required

    NSLayoutConstraint.activate([
      container.leadingAnchor.constraint(equalTo: hostWindow.safeAreaLayoutGuide.leadingAnchor),
      container.trailingAnchor.constraint(equalTo: hostWindow.safeAreaLayoutGuide.trailingAnchor),
      container.bottomAnchor.constraint(equalTo: hostWindow.safeAreaLayoutGuide.bottomAnchor),
      heightConstraint,
      accessory.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      accessory.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      accessory.topAnchor.constraint(equalTo: container.topAnchor),
      accessory.bottomAnchor.constraint(equalTo: container.bottomAnchor)
    ])

    catalystToolbarContainer = container
  }

  private func makeCatalystAccessoryView() -> UIView? {
    createKeyboardAccessoryView()
  }
  #endif

    private var isSanitizing = false
    private let rtLogger = Logger(subsystem: "blue.catbird", category: "RichText.Legacy")
    var lastFocusID: UUID? = nil
    
    init(_ parent: EnhancedRichTextEditor) {
      self.parent = parent
      super.init()
    }
    
    func createKeyboardAccessoryView() -> UIView? {
      let toolbarView = KeyboardToolbarView(
        onPhotos: parent.onPhotosAction,
        onVideo: parent.onVideoAction,
        onAudio: parent.onAudioAction,
        onGif: parent.onGifAction,
        onLabels: parent.onLabelsAction,
        onThreadgate: parent.onThreadgateAction,
        onLanguage: parent.onLanguageAction,
        onThread: parent.onThreadAction,
        onLink: parent.onLinkAction,
        allowTenor: parent.allowTenor
      )
      
      let hostingController = UIHostingController(rootView: toolbarView)
      hostingController.view.backgroundColor = .clear
      
      // Set intrinsic content size for the accessory view
      let targetSize = hostingController.view.systemLayoutSizeFitting(
        CGSize(width: UIScreen.main.bounds.width, height: UIView.layoutFittingCompressedSize.height),
        withHorizontalFittingPriority: .required,
        verticalFittingPriority: .defaultLow
    
      )
      
      hostingController.view.frame = CGRect(origin: .zero, size: targetSize)
      return hostingController.view
    }
    
    func textViewDidChange(_ textView: UITextView) {
      // CRITICAL: Skip ALL modifications during IME composition (markedTextRange != nil)
      // This is essential for proper Chinese/Japanese/Korean/etc. input method support.
      // Modifying attributedText during composition forces premature character confirmation.
      if textView.markedTextRange != nil {
        rtLogger.debug("IME active - skipping all updates to preserve composition")
        updatePlaceholder(parent.placeholder, in: textView)
        return
      }
      
      // Store current state without modifying textView
      let previousSelectedRange = textView.selectedRange
      guard let currentText = textView.attributedText else { return }
      
      // Debug summary
      let counts = summarizeNS(currentText)
      rtLogger.debug("Legacy change: len=\(textView.text.count), runs=\(counts.runs), linkRuns=\(counts.linkRuns)")

      // Update parent binding WITHOUT modifying textView
      parent.attributedText = currentText
      
      // Update link facets based on text changes
      updateLinkFacetsForTextChange(in: textView)
      
      // Call text changed callback with cursor position
      parent.onTextChanged(currentText, previousSelectedRange.location)
      
      // Update placeholder visibility
      updatePlaceholder(parent.placeholder, in: textView)
      
      // Detect Genmoji (adaptive image glyphs) and traditional emoji patterns
      if !textView.isFirstResponder {
        detectAdaptiveImageGlyphs(in: currentText)
      }
      
      // Reset typing attributes if needed (doesn't modify content)
      resetTypingAttributesIfNeeded(textView, at: previousSelectedRange.location)
    }
    
    private func resetTypingAttributesIfNeeded(_ textView: UITextView, at cursorPosition: Int) {
      guard cursorPosition >= 0 && cursorPosition <= textView.attributedText.length else { return }
      
      let defaultTyping: [NSAttributedString.Key: Any] = [
        .font: textView.font ?? UIFont.preferredFont(forTextStyle: UIFont.TextStyle.body),
        .foregroundColor: UIColor.label
      ]
      
      // Check if we're at a link boundary
      if cursorPosition > 0 {
        let prevIndex = cursorPosition - 1
        var effectiveRange = NSRange(location: 0, length: 0)
        let attrs = textView.attributedText.attributes(at: prevIndex, effectiveRange: &effectiveRange)
        
        if attrs[.link] != nil {
          // At end of link run?
          if cursorPosition == effectiveRange.location + effectiveRange.length {
            textView.typingAttributes = defaultTyping
          }
        } else {
          textView.typingAttributes = defaultTyping
        }
      } else {
        textView.typingAttributes = defaultTyping
      }
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
    
    func textViewDidEndEditing(_ textView: UITextView) {
      // Safe to sanitize when user is done editing
      sanitizeTextViewIfNeeded(textView)
    }
    
    private func sanitizeTextViewIfNeeded(_ textView: UITextView) {
      guard !isSanitizing else { return }
      
      let sanitized = textView.attributedText.ctb_keepOnlyLinkAttribute()
      if sanitized != textView.attributedText {
        isSanitizing = true
        let previousSelectedRange = textView.selectedRange
        let font = textView.font ?? UIFont.preferredFont(forTextStyle: UIFont.TextStyle.body)
        let withFont = applyingDefaultFontIfMissing(sanitized, defaultFont: font)
        textView.attributedText = withFont
        if previousSelectedRange.location <= textView.text.count {
          textView.selectedRange = previousSelectedRange
        }
        // Update the binding after sanitization
        parent.attributedText = textView.attributedText
        updateLinkFacetsForTextChange(in: textView)
        isSanitizing = false
        rtLogger.debug("Sanitized text after editing ended")
      }
    }
    
    // MARK: - UITextPasteDelegate (iOS 18+)
    
    @available(iOS 18.0, *)
    func textPasteConfigurationSupporting(
      _ textPasteConfigurationSupporting: UITextPasteConfigurationSupporting,
      transform item: UITextPasteItem
    ) {
      // Allow default handling for most paste operations
      // This includes proper NSAdaptiveImageGlyph (Genmoji) support
      item.setDefaultResult()
    }
    
    // MARK: - Genmoji Detection
    
    private func detectAdaptiveImageGlyphs(in attributedText: NSAttributedString) {
      guard #available(iOS 18.0, *) else {
        // Fallback to legacy string-based detection
        detectGenmoji(in: attributedText.string)
        return
      }
      
      var glyphs: [String] = []
      
      attributedText.enumerateAttribute(
        .adaptiveImageGlyph,
        in: NSRange(location: 0, length: attributedText.length)
      ) { value, range, stop in
        if let glyph = value as? NSAdaptiveImageGlyph {
          // Use content description for accessibility and logging
          glyphs.append(glyph.contentDescription)
        }
      }
      
      if !glyphs.isEmpty {
        parent.onGenmojiDetected(glyphs)
        rtLogger.debug("Detected \(glyphs.count) adaptive image glyphs: \(glyphs)")
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
      let ns = text as NSString
      let full = NSRange(location: 0, length: ns.length)
      let matches = regex?.matches(in: text, range: full) ?? []
      let genmojis = matches.map { ns.substring(with: $0.range) }
      
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
        textView.typingAttributes[.foregroundColor] = UIColor.label
      }
    }

    // Apply visual attributes (links, colors, underline) from a source
    // NSAttributedString to the current UITextView without changing characters.
    // This preserves IME/composition and prevents cursor jumps while restoring
    // facet-driven highlighting for mentions, hashtags, and links.
    func applyVisualAttributes(from source: NSAttributedString, to textView: UITextView) {
      // If strings differ, a full replace will (and should) occur elsewhere.
      guard textView.text == source.string else { return }
      guard textView.markedTextRange == nil else { return }

      let storage = textView.textStorage
      let nsLen = storage.length
      let full = NSRange(location: 0, length: nsLen)

      storage.beginEditing()
      // Reset attributes we manage; keep font as-is to avoid font churn.
      storage.removeAttribute(.link, range: full)
      storage.removeAttribute(.underlineStyle, range: full)
      storage.removeAttribute(.foregroundColor, range: full)
      storage.addAttribute(.foregroundColor, value: UIColor.label, range: full)

      // Copy selected attributes from the source attributed text.
      source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attrs, range, _ in
        guard range.location >= 0, range.location + range.length <= nsLen else { return }

        var newAttrs: [NSAttributedString.Key: Any] = [:]
        if let url = attrs[.link] as? URL {
          newAttrs[.link] = url
          newAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
          newAttrs[.foregroundColor] = UIColor.systemBlue
        } else if let fg = attrs[.foregroundColor] {
          // Mentions/hashtags are colored in the Petrel-generated styled text;
          // mirror that here for visual parity while editing.
          newAttrs[.foregroundColor] = fg
        }
        if !newAttrs.isEmpty {
          storage.addAttributes(newAttrs, range: range)
        }
      }
      storage.endEditing()

      // Keep caret and typing attributes stable (default typing outside links)
      let cursor = textView.selectedRange.location
      if cursor > 0 && cursor <= nsLen {
        let idx = min(max(cursor - 1, 0), nsLen - 1)
        let attrs = storage.attributes(at: idx, effectiveRange: nil)
        if attrs[.link] == nil {
          textView.typingAttributes = [
            .font: textView.font ?? UIFont.preferredFont(forTextStyle: UIFont.TextStyle.body),
            .foregroundColor: UIColor.label
          ]
        }
      }
    }

    // Apply a default font and text color to any ranges that lack these attributes.
    func applyingDefaultFontIfMissing(_ source: NSAttributedString, defaultFont: UIFont) -> NSAttributedString {
      let mutable = NSMutableAttributedString(attributedString: source)
      var location = 0
      while location < mutable.length {
        var range = NSRange(location: 0, length: 0)
        let attrs = mutable.attributes(at: location, effectiveRange: &range)
        var needsUpdate = false
        var newAttrs = attrs
        
        if attrs[.font] == nil {
          newAttrs[.font] = defaultFont
          needsUpdate = true
        }
        
        // Always ensure we have a foreground color for dark mode support
        // Only skip if it's a link (which has its own color)
        if attrs[.foregroundColor] == nil && attrs[.link] == nil {
          newAttrs[.foregroundColor] = UIColor.label
          needsUpdate = true
        }
        
        if needsUpdate {
          mutable.setAttributes(newAttrs, range: range)
        }
        
        location = range.location + range.length
      }
      return mutable
    }
  }
}


// MARK: - Keyboard Toolbar View with Liquid Glass

struct KeyboardToolbarView: View {
  let onPhotos: (() -> Void)?
  let onVideo: (() -> Void)?
  let onAudio: (() -> Void)?
  let onGif: (() -> Void)?
  let onLabels: (() -> Void)?
  let onThreadgate: (() -> Void)?
  let onLanguage: (() -> Void)?
  let onThread: (() -> Void)?
  let onLink: (() -> Void)?
  let allowTenor: Bool

  @Namespace private var glassNamespace

  var body: some View {
    if #available(iOS 26.0, *) {
      GlassEffectContainer(spacing: 6) {
        HStack(spacing: 6) {
          // Left side: Individual media buttons
          HStack(spacing: 6) {
            Button(action: { onPhotos?() }) {
              Image(systemName: "photo")
                .font(.system(size: 18))
                .frame(width: 36, height: 36)
            }
            .padding(6)
            .glassEffect(.regular.interactive())
            .glassEffectUnion(id: "mediaActions", namespace: glassNamespace)
            .catalystPlainButtons()
              
            Button(action: { onVideo?() }) {
              Image(systemName: "video")
                .font(.system(size: 18))
                .frame(width: 36, height: 36)
            }
            .padding(6)
            .glassEffect(.regular.interactive())
            .glassEffectUnion(id: "mediaActions", namespace: glassNamespace)
            .catalystPlainButtons()

            if allowTenor {
              Button(action: { onGif?() }) {
                Text("GIF")
                  .font(.system(size: 12, weight: .semibold, design: .monospaced))
                  .frame(width: 36, height: 20)
                  .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 1.0)
                  )
              }
              .padding(6)
              .glassEffect(.regular.interactive())
              .glassEffectUnion(id: "mediaActions", namespace: glassNamespace)
              .catalystPlainButtons()

            }

            Button(action: { onAudio?() }) {
              Image(systemName: "mic")
                .font(.system(size: 18))
                .frame(width: 36, height: 36)
            }
            .padding(6)
            .glassEffect(.regular.interactive())
            .glassEffectUnion(id: "mediaActions", namespace: glassNamespace)
            .catalystPlainButtons()

          }
          .padding(6)

          Spacer()

          // Right side: Settings menu, Thread, and Link
          HStack(spacing: 12) {
            Menu {
              Button(action: { onLabels?() }) {
                Label("Labels", systemImage: "tag")
              }

              Button(action: { onThreadgate?() }) {
                Label("Who can reply", systemImage: "lock")
              }

              Button(action: { onLanguage?() }) {
                Label("Languages", systemImage: "globe")
              }
            } label: {
              Image(systemName: "ellipsis")
                .font(.system(size: 18))
                .frame(width: 36, height: 36)
            }
            .padding(6)
            .glassEffect(.regular.interactive())
            .glassEffectUnion(id: "controlActions", namespace: glassNamespace)

            Button(action: { onThread?() }) {
              Image(systemName: "plus")
                .font(.system(size: 18))
                .frame(width: 36, height: 36)
            }
            .padding(6)
            .glassEffect(.regular.interactive())
            .glassEffectUnion(id: "controlActions", namespace: glassNamespace)
            .catalystPlainButtons()


            Button(action: { onLink?() }) {
              Image(systemName: "link")
                .font(.system(size: 18))
                .frame(width: 36, height: 36)
            }
            .padding(6)
            .glassEffect(.regular.interactive())
            .glassEffectUnion(id: "controlActions", namespace: glassNamespace)
            .catalystPlainButtons()

          }
          .padding(6)

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
      }
    } else {
      HStack(spacing: 8) {
        // Left side: Individual media buttons (legacy)
        HStack(spacing: 6) {
          Button(action: { onPhotos?() }) {
            Image(systemName: "photo")
              .font(.system(size: 18))
              .foregroundStyle(Color.accentColor)
              .frame(width: 36, height: 36)
          }

          Button(action: { onVideo?() }) {
            Image(systemName: "video")
              .font(.system(size: 18))
              .foregroundStyle(Color.accentColor)
              .frame(width: 36, height: 36)
          }

              if allowTenor {
                Button(action: { onGif?() }) {
                  Text("GIF")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .overlay(
                      RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.2), lineWidth: 0.5)
                    )
                }
              }

          Button(action: { onAudio?() }) {
            Image(systemName: "mic")
              .font(.system(size: 18))
              .foregroundStyle(Color.accentColor)
              .frame(width: 36, height: 36)
          }
        }

        Spacer()

        // Right side: Settings menu, Thread, and Link (legacy)
        HStack(spacing: 6) {
          Menu {
            Button(action: { onLabels?() }) {
              Label("Labels", systemImage: "tag")
            }

            Button(action: { onThreadgate?() }) {
              Label("Who can reply", systemImage: "lock")
            }

            Button(action: { onLanguage?() }) {
              Label("Languages", systemImage: "globe")
            }
          } label: {
            Image(systemName: "ellipsis")
              .font(.system(size: 18))
              .foregroundStyle(Color.accentColor)
              .frame(width: 36, height: 36)
          }

          Button(action: { onThread?() }) {
            Image(systemName: "plus")
              .font(.system(size: 18))
              .foregroundStyle(Color.accentColor)
              .frame(width: 36, height: 36)
          }

          Button(action: { onLink?() }) {
            Image(systemName: "link")
              .font(.system(size: 18))
              .foregroundStyle(Color.accentColor)
              .frame(width: 36, height: 36)
          }
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
  }
}

#else

// macOS stub for EnhancedRichTextEditor
struct EnhancedRichTextEditor: View {
  @Binding var attributedText: NSAttributedString
  @Binding var linkFacets: [RichTextFacetUtils.LinkFacet]
  @Binding var pendingSelectionRange: NSRange?
  
  let placeholder: String
  let onImagePasted: (NSImage) -> Void
  let onGenmojiDetected: ([String]) -> Void
  let onTextChanged: (NSAttributedString, Int) -> Void
  let onLinkCreationRequested: (String, NSRange) -> Void
  
  var body: some View {
    Text("Rich text editing not available on macOS")
      .foregroundColor(.secondary)
  }
}

#endif

// MARK: - NSAttributedString Sanitizer (links-only)

private extension NSAttributedString {
  /// Returns a copy of the receiver where only essential attributes are preserved:
  /// `.link`, `.font`, and `.foregroundColor`. All other attributes are stripped.
  func ctb_keepOnlyLinkAttribute() -> NSAttributedString {
    let mutable = NSMutableAttributedString(attributedString: self)
    var location = 0
    while location < mutable.length {
      var range = NSRange(location: 0, length: 0)
      let attrs = mutable.attributes(at: location, effectiveRange: &range)
      var preservedAttrs: [NSAttributedString.Key: Any] = [:]
      
      // Preserve link attribute
      let hasLink = attrs[.link] != nil
      if let link = attrs[.link] {
        preservedAttrs[.link] = link
      }
      
      // Preserve font attribute
      if let font = attrs[.font] {
        preservedAttrs[.font] = font
      }
      
      // Always preserve foreground color to maintain dark mode compatibility
      // For links, this will be the blue link color; for regular text, it's UIColor.label
      if let color = attrs[.foregroundColor] {
        preservedAttrs[.foregroundColor] = color
      } else if !hasLink {
        // If no color is set and it's not a link, ensure we use the dynamic label color
        preservedAttrs[.foregroundColor] = UIColor.label
      }
      
      mutable.setAttributes(preservedAttrs, range: range)
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
