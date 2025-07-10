//
//  EnhancedRichTextEditor.swift
//  Catbird
//
//  Created by Josh LaCalamito on 12/18/23.
//

import SwiftUI
import UIKit
import Petrel

// MARK: - Enhanced Rich Text Editor with Link Support

struct EnhancedRichTextEditor: UIViewRepresentable {
  @Binding var attributedText: NSAttributedString
  @Binding var linkFacets: [RichTextFacetUtils.LinkFacet]
  
  let placeholder: String
  let onImagePasted: (UIImage) -> Void
  let onGenmojiDetected: ([String]) -> Void
  let onTextChanged: (NSAttributedString) -> Void
  let onLinkCreationRequested: (String, NSRange) -> Void
  
  func makeUIView(context: Context) -> UITextView {
    let textView = UITextView()
    textView.delegate = context.coordinator
    textView.font = UIFont.systemFont(ofSize: 17)
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
    
    // Set up custom menu for link creation
    setupCustomMenu(for: textView)
    
    // Add edit menu interaction for iOS 16+
    if #available(iOS 16.0, *), let editMenuInteraction = context.coordinator.editMenuInteraction {
      textView.addInteraction(editMenuInteraction)
    }
    
    return textView
  }
  
  func updateUIView(_ uiView: UITextView, context: Context) {
    if uiView.attributedText != attributedText {
      let previousSelectedRange = uiView.selectedRange
      uiView.attributedText = attributedText
      
      // Restore selection if possible
      if previousSelectedRange.location <= uiView.text.count {
        uiView.selectedRange = previousSelectedRange
      }
    }
    
    // Update placeholder
    context.coordinator.updatePlaceholder(placeholder, in: uiView)
  }
  
  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }
  
  private func setupCustomMenu(for textView: UITextView) {
    // For iOS 16+, we'll use UIEditMenuInteraction through the coordinator
    // The actual menu setup is handled in the coordinator's textViewDidChangeSelection
    // This ensures the menu appears when text is selected
    
    // Enable text selection highlighting
    textView.isSelectable = true
    textView.isEditable = true
  }
  
  class Coordinator: NSObject, UITextViewDelegate {
    let parent: EnhancedRichTextEditor
    private var placeholderLabel: UILabel?
    var editMenuInteraction: UIEditMenuInteraction?
    
    init(_ parent: EnhancedRichTextEditor) {
      self.parent = parent
      super.init()
      
      // Set up edit menu interaction for iOS 16+
      if #available(iOS 16.0, *) {
        editMenuInteraction = UIEditMenuInteraction(delegate: self)
      }
    }
    
    func textViewDidChange(_ textView: UITextView) {
      // Update attributed text binding
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
        return false
      }
      return true
    }
    
    func textViewDidChangeSelection(_ textView: UITextView) {
      // Could be used to show link creation options when text is selected
      let selectedRange = textView.selectedRange
      if selectedRange.length > 0 {
        // Text is selected - could show link creation UI
      }
    }
    
    private func updateLinkFacetsForTextChange(in textView: UITextView) {
      // This would need more sophisticated logic to track text changes
      // and update link facet ranges accordingly
      // For now, we'll regenerate them from the attributed text
      
      let newFacets = extractLinkFacetsFromAttributedText(textView.attributedText)
      parent.linkFacets = newFacets
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
        placeholderLabel = UILabel()
        placeholderLabel?.font = textView.font
        placeholderLabel?.textColor = .placeholderText
        placeholderLabel?.numberOfLines = 0
        textView.addSubview(placeholderLabel!)
        
        placeholderLabel?.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
          placeholderLabel!.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8),
          placeholderLabel!.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 5),
          placeholderLabel!.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor, constant: -5)
        ])
      }
      
      placeholderLabel?.text = placeholder
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
  }
}

// MARK: - Link Creation Integration

extension EnhancedRichTextEditor {
  /// Add a link facet to the current text
  func addLinkFacet(url: URL, range: NSRange, in text: String) -> NSAttributedString {
    let mutableAttributedText = NSMutableAttributedString(attributedString: attributedText)
    
    // Add link attributes
    mutableAttributedText.addAttributes([
      .link: url,
      .foregroundColor: UIColor.systemBlue,
      .underlineStyle: NSUnderlineStyle.single.rawValue
    ], range: range)
    
    return mutableAttributedText
  }
}

// MARK: - UIEditMenuInteractionDelegate

@available(iOS 16.0, *)
extension EnhancedRichTextEditor.Coordinator: UIEditMenuInteractionDelegate {
  
  func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
    
    // Only add our custom menu if there's selected text
    guard let textView = interaction.view as? UITextView,
          textView.selectedRange.length > 0 else {
      return UIMenu(children: suggestedActions)
    }
    
    let selectedText = (textView.text as NSString).substring(with: textView.selectedRange)
    
    // Only show "Create Link" if there's non-empty selected text
    guard !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return UIMenu(children: suggestedActions)
    }
    
    // Create the "Create Link" action
    let createLinkAction = UIAction(
      title: "Create Link",
      image: UIImage(systemName: "link")
    ) { [weak self] _ in
      self?.parent.onLinkCreationRequested(selectedText, textView.selectedRange)
    }
    
    // Combine our custom action with the suggested actions
    var allActions = suggestedActions
    allActions.insert(createLinkAction, at: 0)
    
    return UIMenu(children: allActions)
  }
}