//
//  TappableTextView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/24/24.
//

import Foundation
import SwiftUI
import UIKit

// Custom UITextView that properly sizes itself
class SelfSizingTextView: UITextView {
  override var intrinsicContentSize: CGSize {
    // Use a reasonable width constraint for text wrapping
    let maxWidth = superview?.bounds.width ?? UIScreen.main.bounds.width - 32
    let constrainedSize = CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude)
    
    // Calculate the size needed for the current attributed text
    let size = sizeThatFits(constrainedSize)
    return CGSize(width: UIView.noIntrinsicMetric, height: ceil(size.height))
  }
  
  private var lastKnownWidth: CGFloat = 0
  
  override func layoutSubviews() {
    super.layoutSubviews()
    
    // Only invalidate if the width has changed significantly to avoid unnecessary layout passes
    let currentWidth = bounds.width
    if abs(currentWidth - lastKnownWidth) > 1 {
      lastKnownWidth = currentWidth
      invalidateIntrinsicContentSize()
    }
  }
}

struct TappableTextView: UIViewRepresentable {
  let attributedString: AttributedString
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.fontManager) private var fontManager

  // State to track if the string contains only emojis
  @State private var containsOnlyEmojis: Bool = false
    
  private var textDesign: Font.Design
  private var textWeight: Font.Weight
  private var lineSpacing: CGFloat
  private var letterSpacing: CGFloat
  private var textStyle: Font.TextStyle
  private var textSize: CGFloat?
  private var fontWidth: CGFloat?

  // Public initializer
  public init(attributedString: AttributedString) {
    self.attributedString = attributedString
    self.textSize = nil
    self.textStyle = .body
    self.textDesign = .default
    self.textWeight = .regular
    self.fontWidth = nil
    self.lineSpacing = 1.6
    self.letterSpacing = 0.2
  }
    
  public init(
      attributedString: AttributedString,
      textSize: CGFloat? = nil,
      textStyle: Font.TextStyle = .body,
      textDesign: Font.Design = .default,
      textWeight: Font.Weight = .regular,
      fontWidth: CGFloat? = nil,
      lineSpacing: CGFloat = 1.6,
      letterSpacing: CGFloat = 0.2
  ) {
      self.attributedString = attributedString
      self.textSize = textSize
      self.textStyle = textStyle
      self.textDesign = textDesign
      self.textWeight = textWeight
      self.fontWidth = fontWidth
      self.lineSpacing = lineSpacing
      self.letterSpacing = letterSpacing
  }

  func makeUIView(context: Context) -> SelfSizingTextView {
    let textView = SelfSizingTextView()
    
    // Configure basic properties
    textView.isEditable = false
    textView.isSelectable = false
    textView.isScrollEnabled = false
    textView.backgroundColor = .clear
    textView.textContainer.lineFragmentPadding = 0
    textView.textContainerInset = .zero
    textView.delegate = context.coordinator
    
    // Enable data detectors for URLs
    textView.dataDetectorTypes = [.link]
    
    // Configure for proper text wrapping and sizing
    textView.textContainer.lineBreakMode = .byWordWrapping
    textView.textContainer.maximumNumberOfLines = 0
    textView.textContainer.widthTracksTextView = true
    textView.textContainer.heightTracksTextView = false
    
    // Set content compression and hugging priorities
    textView.setContentCompressionResistancePriority(.required, for: .vertical)
    textView.setContentHuggingPriority(.required, for: .vertical)
    textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    
    // Accessibility configuration
    textView.isAccessibilityElement = true
    textView.accessibilityTraits = [.staticText]
    textView.adjustsFontForContentSizeCategory = true
    
    // Text selection configuration
    textView.textDragInteraction?.isEnabled = false
    
    return textView
  }
  
  func updateUIView(_ uiView: SelfSizingTextView, context: Context) {
    // Check for emoji-only content
    let plainText = extractPlainText(from: attributedString)
    let isEmojiOnly = plainText.containsOnlyEmojis
    
    // Create NSAttributedString with proper font attributes
    let nsAttributedString = createNSAttributedString(from: attributedString, isEmojiOnly: isEmojiOnly)
    
    if uiView.attributedText != nsAttributedString {
      uiView.attributedText = nsAttributedString
      // Trigger immediate layout update after content changes
      uiView.invalidateIntrinsicContentSize()
      uiView.setNeedsLayout()
    }
    
    // Apply theme colors
    let effectiveColorScheme = appState.themeManager.effectiveColorScheme(for: colorScheme)
    uiView.textColor = UIColor(Color.dynamicText(appState.themeManager, style: .primary, currentScheme: effectiveColorScheme))
    uiView.tintColor = UIColor(.accentColor)
    
    // Update coordinator with current environment values
    context.coordinator.appState = appState
  }
  
  func makeCoordinator() -> Coordinator {
    Coordinator()
  }
  
  class Coordinator: NSObject, UITextViewDelegate {
    var appState: AppState?
    
    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange) -> Bool {
      guard let appState = appState else { return true }
      
      // Handle URL through the app's URL handler on the main thread
      DispatchQueue.main.async {
        _ = appState.urlHandler.handle(URL)
      }
      
      // Return false to prevent default system handling since we're handling it ourselves
      return false
    }
  }
  
  // MARK: - Helper Functions
  
  private func extractPlainText(from attributedString: AttributedString) -> String {
    return String(attributedString.characters.reduce("") { result, char in
      result + String(char)
    })
  }
  
  private func createNSAttributedString(from attributedString: AttributedString, isEmojiOnly: Bool) -> NSAttributedString {
    let nsAttributedString = NSMutableAttributedString(attributedString)
    
    // Calculate effective font size
    let baseSize = textSize ?? Typography.Size.body
    let effectiveSize = isEmojiOnly ? baseSize * 3 : baseSize
    let scaledSize = fontManager.scaledSize(effectiveSize)
    
    // Create default font with FontManager integration
    let defaultFont = createUIFont(size: scaledSize, weight: textWeight, design: textDesign)
    
    // Enumerate existing attributes and preserve formatting while updating font sizes
    nsAttributedString.enumerateAttributes(in: NSRange(location: 0, length: nsAttributedString.length), options: []) { attributes, range, _ in
      var newAttributes = attributes
      
      // Update font while preserving weight/traits if they exist
      if let existingFont = attributes[.font] as? UIFont {
        // Preserve existing font traits (bold, italic, etc.) but update size
        let newFont = existingFont.withSize(scaledSize)
        newAttributes[.font] = newFont
      } else {
        // No existing font, use default
        newAttributes[.font] = defaultFont
      }
      
      nsAttributedString.setAttributes(newAttributes, range: range)
    }
    
    // Apply line spacing and paragraph style
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = fontManager.getLineSpacing(for: scaledSize) * lineSpacing
    paragraphStyle.lineBreakMode = .byWordWrapping
    paragraphStyle.alignment = .left
    
    // Apply letter spacing and paragraph style to entire string
    let letterSpacingValue = fontManager.letterSpacingValue * letterSpacing
    nsAttributedString.addAttribute(.kern, value: letterSpacingValue, range: NSRange(location: 0, length: nsAttributedString.length))
    nsAttributedString.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: nsAttributedString.length))
    
    return nsAttributedString
  }
  
  private func createUIFont(size: CGFloat, weight: Font.Weight, design: Font.Design) -> UIFont {
    let fontWeight: UIFont.Weight
    switch weight {
    case .ultraLight: fontWeight = .ultraLight
    case .thin: fontWeight = .thin  
    case .light: fontWeight = .light
    case .regular: fontWeight = .regular
    case .medium: fontWeight = .medium
    case .semibold: fontWeight = .semibold
    case .bold: fontWeight = .bold
    case .heavy: fontWeight = .heavy
    case .black: fontWeight = .black
    default: fontWeight = .regular
    }
    
    let fontDesign: UIFontDescriptor.SystemDesign
    switch design {
    case .default: fontDesign = .default
    case .serif: fontDesign = .serif
    case .monospaced: fontDesign = .monospaced
    case .rounded: fontDesign = .rounded
    default: fontDesign = .default
    }
    
    if let descriptor = UIFont.systemFont(ofSize: size, weight: fontWeight).fontDescriptor.withDesign(fontDesign) {
      return UIFont(descriptor: descriptor, size: size)
    }
    
    return UIFont.systemFont(ofSize: size, weight: fontWeight)
  }
}

// Extension to check if a string contains only emoji characters
extension String {
    var containsOnlyEmojis: Bool {
        if isEmpty { return false }
        
        // Filter out zero-width joiners and variation selectors which are used in emoji sequences
        let emojiString = self.unicodeScalars.filter { 
            !($0.value == 0x200D ||      // Zero-width joiner
              (0xFE00...0xFE0F).contains($0.value) ||  // Variation selectors
              (0xE0020...0xE007F).contains($0.value))  // Tags
        }
        
        // If after filtering, we have nothing left, it wasn't an emoji string
        if emojiString.isEmpty { return false }
        
        // Now check if all remaining characters are emoji
        return emojiString.allSatisfy { isEmoji($0) }
    }
    
    // Improved emoji detection with support for extended emoji and skin tones
    private func isEmoji(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x1F600...0x1F64F, // Emoticons
             0x1F300...0x1F5FF, // Misc Symbols and Pictographs
             0x1F680...0x1F6FF, // Transport and Map
             0x1F700...0x1F77F, // Alchemical Symbols
             0x1F780...0x1F7FF, // Geometric Shapes
             0x1F800...0x1F8FF, // Supplemental Arrows-C
             0x1F900...0x1F9FF, // Supplemental Symbols and Pictographs
             0x1FA00...0x1FA6F, // Chess Symbols
             0x1FA70...0x1FAFF, // Symbols and Pictographs Extended-A
             0x2600...0x26FF,   // Miscellaneous Symbols
             0x2700...0x27BF,   // Dingbats
             0x1F000...0x1F02F, // Mahjong Tiles
             0x1F0A0...0x1F0FF, // Playing Cards
             0x1F100...0x1F1FF, // Enclosed Alphanumeric Supplement
             0x1F200...0x1F2FF, // Enclosed Ideographic Supplement
             0x1F300...0x1F5FF, // Miscellaneous Symbols and Pictographs
             0x1F600...0x1F64F, // Emoticons
             0x1F680...0x1F6FF, // Transport and Map Symbols
             0x1F700...0x1F77F, // Alchemical Symbols
             0x1F3FB...0x1F3FF, // Emoji Modifier Fitzpatrick (skin tones)
             0x261D, 0x26F9,    // Various hand symbols
             0x270A...0x270D,   // Hand symbols
             0x1F1E6...0x1F1FF, // Regional indicator symbols (flags)
             0x1F926...0x1F9FF: // Additional symbols
            return true
        default:
            return scalar.properties.isEmoji && 
                   (scalar.properties.isEmojiPresentation || 
                    scalar.properties.generalCategory == .otherSymbol)
        }
    }
}
