//
//  TappableTextView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/24/24.
//

import Foundation
import SwiftUI

struct TappableTextView: View {
  @Environment(SceneNavigationContext.self) private var sceneContext
  let attributedString: AttributedString
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.fontManager) private var fontManager

  // Pre-computed flag for emoji-only text scaling
  private let containsOnlyEmojis: Bool
    
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
    self.containsOnlyEmojis = Self.determineIfOnlyEmojis(attributedString)
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
      self.containsOnlyEmojis = Self.determineIfOnlyEmojis(attributedString)
  }
    // Unlimited lines at their ideal height never need to shrink, so the text carries no
    // `minimumScaleFactor`/`allowsTightening`: either one sends every measurement through
    // SwiftUI's slower scale-to-fit path.
    var body: some View {
        Group {
            if containsOnlyEmojis {
                // If the string contains only emojis, use a larger font size with accessibility support
                if let effectiveSize = effectiveTextSize {
                    PostAttributedText(attributedString, textColor: themedTextColor)
                        .appFont(size: effectiveSize, weight: textWeight, relativeTo: textStyle)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .tracking(fontManager.letterSpacingValue)
                        .lineSpacing(fontManager.getLineSpacing(for: effectiveSize))
                        .lineLimit(nil)
                } else {
                    PostAttributedText(attributedString, textColor: themedTextColor)
                        .appFont(textStyle)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .tracking(fontManager.letterSpacingValue)
                        .lineLimit(nil)
                }
            } else {
                // Regular text handling with FontManager integration
                if let effectiveSize = effectiveTextSize {
                    PostAttributedText(attributedString, textColor: themedTextColor)
                        .appFont(size: effectiveSize, weight: textWeight, relativeTo: textStyle)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .tracking(fontManager.letterSpacingValue)
                        .lineSpacing(fontManager.getLineSpacing(for: effectiveSize))
                        .lineLimit(nil)
                        .textSelection(.disabled)
                        // Disable animations to prevent any fly-in or size-change animations
                        .transaction { $0.animation = nil }
                        .environment(
                            \.openURL,
                             OpenURLAction { url in
                                 return sceneContext.urlHandler.handle(url)
                             })
                } else {
                    PostAttributedText(attributedString, textColor: themedTextColor)
                        .appFont(textStyle)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .tracking(fontManager.letterSpacingValue)
                        .lineLimit(nil)
                        .textSelection(.disabled)
                        // Disable animations to prevent any fly-in or size-change animations
                        .transaction { $0.animation = nil }
                        .environment(
                            \.openURL,
                             OpenURLAction { url in
                                 return sceneContext.urlHandler.handle(url)
                             })
                }
            }
        }
        .themedText(appState.themeManager, style: .primary, appSettings: appState.appSettings)
    }
    
    private var themedTextColor: Color {
        Color.dynamicText(
            appState.themeManager, style: .primary, currentScheme: colorScheme,
            increaseContrast: colorSchemeContrast == .increased || appState.appSettings.effectiveIncreaseContrast)
    }

    // Helper function to convert Font.TextStyle to AppTextRole
    private func textStyleToRole(_ textStyle: Font.TextStyle) -> AppTextRole {
        switch textStyle {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption
        case .caption2: return .caption2
        @unknown default: return .body
        }
    }
    
  // Computed property for text size that increases size for emoji-only strings
  private var effectiveTextSize: CGFloat? {
      if containsOnlyEmojis {
          // For emoji-only, scale up if explicit size provided, otherwise return nil to use role-based
          return textSize != nil ? textSize! * 3 : nil
      }
      return textSize
  }
  
  private static func determineIfOnlyEmojis(_ attributedString: AttributedString) -> Bool {
      var hasEmoji = false
      var scalarCount = 0
      for scalar in attributedString.unicodeScalars {
          scalarCount += 1
          if scalarCount > 120 { return false }
          let v = scalar.value
          if v == 0x200D || (0xFE00...0xFE0F).contains(v) || (0xE0020...0xE007F).contains(v) {
              continue
          }
          guard scalar.isEmojiScalar else { return false }
          hasEmoji = true
      }
      guard hasEmoji else { return false }
      return attributedString.characters.prefix(16).count <= 15
  }
}

// Extension to check if a string contains only emoji characters
extension UnicodeScalar {
    fileprivate var isEmojiScalar: Bool {
        switch value {
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
             0x1F3FB...0x1F3FF, // Emoji Modifier Fitzpatrick (skin tones)
             0x261D, 0x26F9,    // Various hand symbols
             0x270A...0x270D,   // Hand symbols
             0x1F1E6...0x1F1FF, // Regional indicator symbols (flags)
             0x1F926...0x1F9FF: // Additional symbols
            return true
        default:
            return properties.isEmoji &&
                   (properties.isEmojiPresentation ||
                    properties.generalCategory == .otherSymbol)
        }
    }
}

extension String {
    var containsOnlyEmojis: Bool {
        if isEmpty { return false }
        var hasEmoji = false
        for scalar in unicodeScalars {
            let v = scalar.value
            if v == 0x200D || (0xFE00...0xFE0F).contains(v) || (0xE0020...0xE007F).contains(v) {
                continue
            }
            guard scalar.isEmojiScalar else { return false }
            hasEmoji = true
        }
        return hasEmoji
    }
}

#Preview("Tappable Text") {
  VStack(spacing: 16) {
    TappableTextView(attributedString: AttributedString("Hello world! This is a sample post with some text content."))
    TappableTextView(attributedString: AttributedString("🎉🎊��"))
  }
  .padding()
  .previewWithAuthenticatedState()
}
