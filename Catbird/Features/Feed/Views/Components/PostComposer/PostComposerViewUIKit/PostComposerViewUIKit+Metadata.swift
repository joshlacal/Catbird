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

      // Outline hashtags, languages, and character counter in horizontal layout
      HStack(alignment: .top, spacing: 12) {
        // Leading: hashtags and languages stacked vertically
        VStack(alignment: .leading, spacing: 4) {
          compactOutlineTagsView(vm: vm)
          compactLanguageChipsView(vm: vm)
        }
        .layoutPriority(-1)  // Lower priority so character counter gets space
        
        Spacer(minLength: 8)
        
        // Trailing: character counter
        CharacterLimitIndicatorWrapper(currentCount: vm.postText.count)
          .layoutPriority(1)  // Higher priority to ensure visibility
          .zIndex(1)
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
  
  // MARK: - Compact Outline Tags View
  
  @ViewBuilder
  private func compactOutlineTagsView(vm: PostComposerViewModel) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "number")
        .font(.system(size: 12))
        .foregroundColor(.secondary)
      
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(vm.outlineTags, id: \.self) { tag in
            HStack(spacing: 4) {
              Text("#\(tag)")
                .font(.system(size: 11, weight: .medium))
              Button(action: { removeOutlineTag(tag, vm: vm) }) {
                Image(systemName: "xmark.circle.fill")
                  .font(.system(size: 10))
                  .foregroundColor(.secondary)
              }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .foregroundColor(.secondary)
            .cornerRadius(6)
          }
          
          if vm.outlineTags.count < 10 {
            Button(action: { showAddTagDialog(vm: vm) }) {
              Image(systemName: "plus.circle")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            }
          }
        }
        .padding(.horizontal, 1)
      }
    }
    .padding(.vertical, 4)
  }
  
  // MARK: - Compact Language Chips View
  
  @ViewBuilder
  private func compactLanguageChipsView(vm: PostComposerViewModel) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .center, spacing: 8) {
        Image(systemName: "globe")
          .font(.system(size: 12))
          .foregroundColor(.secondary)
        
        if vm.selectedLanguages.isEmpty {
          // Show add button when no language is set
          Text("No language set")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
          
          Spacer()
        } else {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
              ForEach(vm.selectedLanguages, id: \.self) { lang in
                HStack(spacing: 4) {
                  Text(Locale.current.localizedString(forLanguageCode: lang.lang.languageCode?.identifier ?? "") ?? lang.lang.minimalIdentifier)
                    .font(.system(size: 11, weight: .medium))
                  Button(action: { vm.toggleLanguage(lang) }) {
                    Image(systemName: "xmark.circle.fill")
                      .font(.system(size: 10))
                      .foregroundColor(.secondary)
                  }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .foregroundColor(.secondary)
                .cornerRadius(6)
              }
            }
            .padding(.horizontal, 1)
          }
        }
      }
      .padding(.vertical, 4)
      
      // Language detection suggestion
      if let suggested = vm.suggestedLanguage,
         !vm.selectedLanguages.contains(suggested),
         !vm.postText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        HStack {
          Button(action: {
            vm.applySuggestedLanguage()
          }) {
            HStack(spacing: 6) {
              Image(systemName: "wand.and.stars")
                .font(.system(size: 10))
              Text("Detected: \(Locale.current.localizedString(forLanguageCode: suggested.lang.languageCode?.identifier ?? "") ?? suggested.lang.minimalIdentifier)")
                .font(.system(size: 11, weight: .medium))
              Image(systemName: "chevron.right")
                .font(.system(size: 8))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.15))
            .foregroundColor(.accentColor)
            .cornerRadius(6)
          }
          .buttonStyle(.plain)
          
          Spacer()
        }
      }
    }
  }
  
  // MARK: - Helper Methods
  
  private func removeOutlineTag(_ tag: String, vm: PostComposerViewModel) {
    vm.outlineTags.removeAll { $0 == tag }
  }
  
  private func showAddTagDialog(vm: PostComposerViewModel) {
    pcMetadataLogger.info("PostComposerMetadata: Add tag button tapped")
    showingOutlineTagsEditor = true
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
