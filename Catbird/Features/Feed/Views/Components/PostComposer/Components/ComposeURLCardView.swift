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
    let enhanced = self.externalView?.external
    let enhancedTitle = enhanced?.title ?? ""
    let enhancedDescription = enhanced?.description ?? ""
    let fallbackTitle = self.title.isEmpty ? self.resolvedURL : self.title

    return AppBskyEmbedExternal.ViewExternal(
      uri: uri ?? URI(""),
      title: enhancedTitle.isEmpty ? fallbackTitle : enhancedTitle,
      description: enhancedDescription.isEmpty ? self.description : enhancedDescription,
      thumb: self.image.isEmpty ? enhanced?.thumb : (URI(self.image) ?? enhanced?.thumb),
      createdAt: enhanced?.createdAt,
      updatedAt: enhanced?.updatedAt,
      readingTime: enhanced?.readingTime,
      labels: enhanced?.labels,
      source: enhanced?.source,
      associatedRefs: enhanced?.associatedRefs ?? self.associatedRefs,
      associatedProfiles: enhanced?.associatedProfiles
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
    VStack(alignment: .leading, spacing: 6) {
      cardPreview

      if !willBeUsedAsEmbed {
        Text("Link previews aren’t posted with photos, videos or GIFs.")
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var cardPreview: some View {
    let external = card.toViewExternal()

    return ZStack(alignment: .topTrailing) {
      ExternalEmbedView(
        external: external,
        shouldBlur: false,
        postID: card.id
      )
      .allowsHitTesting(false)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Link preview")
      .opacity(willBeUsedAsEmbed ? 1 : 0.5)

      VStack(alignment: .trailing, spacing: 4) {
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
        .accessibilityLabel("Remove Link Preview")
      }
      .padding(4)
    }
  }
}
