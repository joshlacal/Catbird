//
//  ComposeURLCardView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 12/18/23.
//

import SwiftUI
import Petrel

// Extension to convert URLCardResponse to ViewExternal
extension URLCardResponse {
  func toViewExternal() -> AppBskyEmbedExternal.ViewExternal {
    // Create a URI from the URL string
    let uri = URI(self.resolvedURL)

    return AppBskyEmbedExternal.ViewExternal(
      uri: uri ?? URI(""),
      title: self.title,
      description: self.description,
      thumb: URI(self.image)
    )
  }
}

// Replace URLCardView with this adapter for ExternalEmbedView
struct ComposeURLCardView: View {
  let card: URLCardResponse
  let onRemove: () -> Void
  let willBeUsedAsEmbed: Bool
  var onRemoveURLFromText: (() -> Void)?

  var body: some View {
    ZStack(alignment: .topTrailing) {
      ExternalEmbedView(
        external: card.toViewExternal(),
        shouldBlur: false,
        postID: card.id
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .stroke(
            willBeUsedAsEmbed ? Color.accentColor.opacity(0.5) : Color.gray.opacity(0.3),
            lineWidth: willBeUsedAsEmbed ? 2 : 1)
      )

      VStack(alignment: .trailing, spacing: 4) {
        // Add featured badge if this will be used as embed
        if willBeUsedAsEmbed {
          Text("Featured")
            .appFont(AppTextRole.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.2))
            .foregroundColor(.accentColor)
            .cornerRadius(4)
        }

        // Button to remove URL from text but keep card
//        if let removeURLAction = onRemoveURLFromText, willBeUsedAsEmbed {
//          Button(action: removeURLAction) {
//            Label("Remove link from text", systemImage: "text.badge.minus")
//              .labelStyle(.iconOnly)
//              .appFont(AppTextRole.body)
//              .foregroundStyle(.white)
//              .padding(6)
//              .background(
//                Circle()
//                  .fill(Color.accentColor)
//              )
//          }
//          .help("Remove URL from text but keep embed card")
//        }

        Button(action: onRemove) {
          Image(systemName: "xmark.circle.fill")
            .appFont(AppTextRole.title3)
            .foregroundStyle(.white, Color(platformColor: PlatformColor.platformSystemGray3))
            .background(
              Circle()
                .fill(Color.black.opacity(0.3))
            )
        }
        .padding(8)
      }
      .padding(4)
    }
  }
}
