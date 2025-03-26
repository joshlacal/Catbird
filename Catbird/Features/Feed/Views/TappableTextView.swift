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

 
    
  private var textDesign: Font.Design
  private var textWeight: Font.Weight
  private var lineSpacing: CGFloat
  private var letterSpacing: CGFloat
  private var textStyle: Font.TextStyle
  private var textSize: CGFloat?
  private var fontWidth: Int?
  @State private var animateText = false

  // Public initializer
  public init(attributedString: AttributedString) {
    self.attributedString = attributedString
    self.textSize = nil
    self.textStyle = .body
    self.textDesign = .default
    self.textWeight = .regular
    self.fontWidth = nil
    self.lineSpacing = 1.2
    self.letterSpacing = 0.2
  }
    
    public init(
        attributedString: AttributedString,
        textSize: CGFloat? = nil,
        textStyle: Font.TextStyle = .body,
        textDesign: Font.Design = .default,
        textWeight: Font.Weight = .regular,
        fontWidth: Int? = nil,
        lineSpacing: CGFloat = 1.2,
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
    Text(attributedString)
          .customScaledFont(
            size: textSize,
            weight: textWeight,
            width: fontWidth,
            relativeTo: textStyle,
            design: textDesign
          )
      // Essential layout properties
      .fixedSize(horizontal: false, vertical: true)
      .multilineTextAlignment(.leading)

      // Advanced SF Pro typography
//      .fontWeight(textWeight)
      .tracking(letterSpacing)
      .lineSpacing(lineSpacing)

      // Modern text styling
//      .textScale(.secondary)
      .lineLimit(nil)
      .allowsTightening(true)
      .minimumScaleFactor(0.9)
      .textSelectionAffinity(.automatic)
      .textSelection(.enabled)
      // Optional text effects
      // .shadow(color: .primary.opacity(0.08), radius: 0.5, x: 0.5, y: 0.5)
      .animation(.spring(duration: 0.3), value: dynamicTypeSize)

      // Advanced styling for links
      .environment(
        \.openURL,
        OpenURLAction { url in
            return appState.urlHandler.handle(url)
        })

    // High legibility contrast if needed
    //            .environment(\.legibilityWeight, colorScheme == .dark ? .regular : .bold)
  }
}

// Extension to allow custom typography configuration
// extension TappableTextView {
//   /// Configures the text with custom typography settings
//   func typography(
//     design: Font.Design = .default,
//     weight: Font.Weight = .regular,
//     lineSpacing: CGFloat = 1.2,
//     letterSpacing: CGFloat = 0.2
//   ) -> Self {
//     var view = self
//     view.textDesign = design
//     view.textWeight = weight
//     view.lineSpacing = lineSpacing
//     view.letterSpacing = letterSpacing
//     return view
//   }
// }

// #Preview {
//   var attributedString = AttributedString(
//     "This is a sample post with #hashtags and @mentions and https://links.com")

//   // Add sample attributes to simulate actual use
//   if let range = attributedString.range(of: "#hashtags") {
//     attributedString[range].foregroundColor = .blue
//     attributedString[range].link = URL(string: "catbird://hashtag/hashtags")
//   }

//   if let range = attributedString.range(of: "@mentions") {
//     attributedString[range].foregroundColor = .blue
//     attributedString[range].link = URL(string: "catbird://user/mentions")
//   }

//   if let range = attributedString.range(of: "https://links.com") {
//     attributedString[range].foregroundColor = .blue
//     attributedString[range].link = URL(string: "https://links.com")
//   }

//   return ExtractedView(attributedString: attributedString)
//     .environment(\.urlHandler, URLHandler())
//     .environment(\.colorScheme, .light)
//     .environment(\.dynamicTypeSize, .accessibility3)
// }

// struct ExtractedView: View {
//   let attributedString: AttributedString

//   var body: some View {
//     VStack(spacing: 20) {
//       TappableTextView(attributedString: attributedString)
//         .padding()
//         .background(Color(.systemBackground))
//         .cornerRadius(8)

//       TappableTextView(attributedString: attributedString)
//         .typography(design: .serif, weight: .medium, lineSpacing: 1.5, letterSpacing: 0.2)
//         .padding()
//         .background(Color(.systemBackground))
//         .cornerRadius(8)
//     }
//     .padding()
//     .background(Color(.systemGroupedBackground))
//   }
// }
