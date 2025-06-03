//
//  TappableTextView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/24/24.
//

import Foundation
import SwiftUI

struct TappableTextView: View {
  let attributedString: AttributedString
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  // State to track if the string contains only emojis
  @State private var containsOnlyEmojis: Bool = false
    
  private var textDesign: Font.Design
  private var textWeight: Font.Weight
  private var lineSpacing: CGFloat
  private var letterSpacing: CGFloat
  private var textStyle: Font.TextStyle
  private var textSize: CGFloat?
  private var fontWidth: CGFloat?
  @State private var animateText = false

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

    var body: some View {
        Group {
            if containsOnlyEmojis {
                // If the string contains only emojis, use a larger font size
                Text(attributedString)
                    .appFont(size: effectiveTextSize ?? 24, weight: textWeight, relativeTo: textStyle)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .tracking(letterSpacing)
                    .lineSpacing(lineSpacing)
                    .lineLimit(nil)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.9)
            } else {
                // Regular text handling - use app font system properly
                Text(attributedString)
                    .customScaledFont(
                        size: effectiveTextSize,
                        weight: textWeight,
                        width: fontWidth,
                        relativeTo: textStyle,
                        design: textDesign
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .tracking(letterSpacing)
                    .lineSpacing(lineSpacing)
                    .lineLimit(nil)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.9)
                    .textSelectionAffinity(.automatic)
                    .textSelection(.enabled)
                    .animation(.spring(duration: 0.3), value: dynamicTypeSize)
                    .environment(
                        \.openURL,
                         OpenURLAction { url in
                             return appState.urlHandler.handle(url)
                         })
            }
        }
        .onAppear {
            checkIfOnlyEmojis()
        }

    }
  // Computed property for text size that increases size for emoji-only strings
  private var effectiveTextSize: CGFloat? {
      if containsOnlyEmojis {
          // Return a larger size for emoji-only strings
          return textSize != nil ? textSize! * 3 : 27
      }
      return textSize
  }
  
  // Function to check if the string contains only emojis
  private func checkIfOnlyEmojis() {
      // Safely extract a plain string and handle potential crashes
      let plainString: String
      do {
          plainString = String(attributedString.characters.reduce("") { result, char in
              result + String(char)
          })
      } catch {
          // If any error occurs during processing, assume it's not emoji-only
          containsOnlyEmojis = false
          return
      }
      
      // Skip empty strings
      guard !plainString.isEmpty else {
          containsOnlyEmojis = false
          return
      }
      
      // Check if the string contains only emoji characters
      containsOnlyEmojis = plainString.containsOnlyEmojis
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
