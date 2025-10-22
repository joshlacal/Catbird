//
//  PostComposerViewUIKit+Metadata.swift
//  Catbird
//

import SwiftUI
import Petrel
import os

private let pcMetadataLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Catbird", category: "PostComposerMetadata")

extension PostComposerViewUIKit {
  
  @ViewBuilder
  func metadataSection(vm: PostComposerViewModel) -> some View {
    VStack(spacing: 12) {
      if let parent = vm.parentPost {
        replyContextView(parent: parent)
      }
      
      if let quoted = vm.quotedPost {
        quotedPostView(quoted: quoted, vm: vm)
      }
      
      if let embedURL = vm.selectedEmbedURL,
         let card = vm.urlCards[embedURL] {
        ComposeURLCardView(
          card: card,
          onRemove: {
            pcMetadataLogger.info("PostComposerMetadata: Removing URL card for: \(embedURL)")
            vm.removeURLCard(for: embedURL)
          },
          willBeUsedAsEmbed: vm.willBeUsedAsEmbed(for: embedURL),
          onRemoveURLFromText: {
            pcMetadataLogger.info("PostComposerMetadata: Removing URL from text: \(embedURL)")
            vm.removeURLFromText(for: embedURL)
          }
        )
        .onAppear {
            pcMetadataLogger.debug("PostComposerMetadata: Displaying URL card for: \(embedURL)")

        }
      }

      // Outline hashtags (compact UI like legacy UIKit composer)
      if !vm.outlineTags.isEmpty || true { // keep visible to allow adding tags
        OutlineTagsView(tags: Binding(
          get: { vm.outlineTags },
          set: { vm.outlineTags = $0 }
        ), compact: true)
      }
      
      if !vm.selectedLanguages.isEmpty {
        languageChipsView(vm: vm)
      }
    }
    .padding(.horizontal, 16)
    .onAppear {
        
        pcMetadataLogger.debug("PostComposerMetadata: Rendering metadata - parent: \(vm.parentPost != nil), quoted: \(vm.quotedPost != nil), embedURL: \(vm.selectedEmbedURL != nil)")
        
    }
  }
  
  @ViewBuilder
  private func replyContextView(parent: AppBskyFeedDefs.PostView) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "arrowshape.turn.up.left")
        .foregroundColor(.secondary)
        .font(.system(size: 14))
      
      Text("Replying to")
        .appFont(AppTextRole.caption)
        .foregroundColor(.secondary)
      
      Text("@\(parent.author.handle.description)")
        .appFont(AppTextRole.caption)
        .fontWeight(.semibold)
        .foregroundColor(.accentColor)
      
      Spacer()
    }
  }
  
  @ViewBuilder
  private func languageChipsView(vm: PostComposerViewModel) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "globe")
        .foregroundColor(.secondary)
        .font(.system(size: 14))
      
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(vm.selectedLanguages, id: \.self) { lang in
            HStack(spacing: 4) {
                Text(lang.lang.minimalIdentifier.uppercased())
                .appFont(AppTextRole.caption)
                .fontWeight(.medium)
              
              Button(action: {
                vm.selectedLanguages.removeAll { $0 == lang }
              }) {
                Image(systemName: "xmark.circle.fill")
                  .font(.system(size: 14))
              }
              .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.systemGray5)
            .cornerRadius(12)
          }
        }
      }
      
      Spacer()
    }
  }
  
  @ViewBuilder
  private func quotedPostView(quoted: AppBskyFeedDefs.PostView, vm: PostComposerViewModel) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: "quote.bubble")
          .foregroundColor(.secondary)
        Text("Quoting post")
          .appFont(AppTextRole.caption)
          .foregroundColor(.secondary)
        Spacer()
        Button(action: {
          pcMetadataLogger.info("PostComposerMetadata: Removing quoted post")
          vm.quotedPost = nil
        }) {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(.secondary)
        }
        .buttonStyle(PlainButtonStyle())
      }
      
      VStack(alignment: .leading, spacing: 4) {
        Text("@\(quoted.author.handle.description)")
          .appFont(AppTextRole.caption)
          .fontWeight(.semibold)
        
        if case .knownType(let record) = quoted.record,
           let post = record as? AppBskyFeedPost {
          Text(post.text)
            .appFont(AppTextRole.body)
            .lineLimit(3)
            .foregroundColor(.primary)
        }
      }
    }
    .padding(12)
    .background(Color.systemGray6)
    .cornerRadius(12)
  }
  // Note: legacy inline link card view replaced by ComposeURLCardView.
}
