//
//  PostComposerViewUIKit+MediaAttachments.swift
//  Catbird
//

import SwiftUI
import Petrel
import AVFoundation
import os

private let pcMediaLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Catbird", category: "PostComposerMedia")

extension PostComposerViewUIKit {
  
  @ViewBuilder
  func mediaAttachmentsSection(vm: PostComposerViewModel) -> some View {
    VStack(spacing: 12) {
      if let gif = vm.selectedGif {
        selectedGifView(gif, vm: vm)
      }
      
      if !vm.mediaItems.isEmpty {
        imageAttachmentsView(vm: vm)
      }
      
      if let videoItem = vm.videoItem {
        videoAttachmentView(videoItem: videoItem, vm: vm)
      }
    }
    .padding(.horizontal, 16)
    .onAppear {
        pcMediaLogger.debug("PostComposerMedia: Rendering media attachments - images: \(vm.mediaItems.count), video: \(vm.videoItem != nil), gif: \(vm.selectedGif != nil)")

    }
  }
  
  @ViewBuilder
  private func imageAttachmentsView(vm: PostComposerViewModel) -> some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
      ForEach(vm.mediaItems) { item in
        MediaItemView(
          item: item,
          onRemove: {
            pcMediaLogger.info("PostComposerMedia: Removing image \(item.id)")
            vm.removeMediaItem(withId: item.id)
          },
          onEditAlt: {
            pcMediaLogger.info("PostComposerMedia: Opening alt text editor for image \(item.id)")
            vm.beginEditingAltText(for: item.id)
          },
          onEditImage: {
            guard let index = vm.mediaItems.firstIndex(where: { $0.id == item.id }) else { return }
            pcMediaLogger.info("PostComposerMedia: Opening photo editor for image \(item.id) at index \(index)")
            vm.beginEditingImage(for: item.id, at: index)
          }
        )
      }
    }
  }
  
  @ViewBuilder
  private func videoAttachmentView(videoItem: PostComposerViewModel.MediaItem, vm: PostComposerViewModel) -> some View {
    PostComposerUIKitVideoAttachmentView(videoItem: videoItem, vm: vm)
  }
  
  @ViewBuilder
  func selectedGifView(_ gif: TenorGif, vm: PostComposerViewModel) -> some View {
    VStack(alignment: .trailing, spacing: 8) {
      ZStack(alignment: .topTrailing) {
        GifVideoView(gif: gif, onTap: {})
          .frame(maxHeight: 200)
          .clipShape(RoundedRectangle(cornerRadius: 12))
        
        Button(action: { 
          pcMediaLogger.info("PostComposerMedia: Removing GIF attachment")
          vm.removeSelectedGif()
        }) {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(.white)
            .background(Circle().fill(Color.black.opacity(0.5)))
        }
        .buttonStyle(PlainButtonStyle())
        .padding(8)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }
}

private struct PostComposerUIKitVideoAttachmentView: View {
  let videoItem: PostComposerViewModel.MediaItem
  let vm: PostComposerViewModel
  @State private var showingCaptionEditor = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      MediaItemView(
        item: videoItem,
        onRemove: {
          pcMediaLogger.info("PostComposerMedia: Removing video attachment")
          vm.removeMediaItem(withId: videoItem.id)
        },
        onEditAlt: {
          pcMediaLogger.info("PostComposerMedia: Opening alt text editor for video \(videoItem.id)")
          vm.beginEditingAltText(for: videoItem.id)
        },
        isVideo: true
      )

      // Captions control button
      HStack(spacing: 6) {
        if let caption = videoItem.caption {
          let langCode = caption.lang.lang.languageCode?.identifier ?? caption.lang.lang.minimalIdentifier
          let langName = Locale.current.localizedString(forLanguageCode: langCode) ?? caption.lang.lang.minimalIdentifier

          Button {
            showingCaptionEditor = true
          } label: {
            HStack(spacing: 4) {
              Image(systemName: "captions.bubble.fill")
                .font(.system(size: 11))
                .foregroundStyle(.tint)
              Text("\(langName) (\(caption.filename))")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(platformColor: .platformSystemGray6))
            .cornerRadius(6)
          }
          .buttonStyle(.plain)

          Button {
            vm.updateVideoCaption(nil)
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Remove caption")
        } else {
          Button {
            showingCaptionEditor = true
          } label: {
            HStack(spacing: 4) {
              Image(systemName: "captions.bubble")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
              Text("Captions (.vtt)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(platformColor: .platformSystemGray6))
            .cornerRadius(6)
          }
          .buttonStyle(.plain)
        }
      }
    }
    .sheet(isPresented: $showingCaptionEditor) {
      VideoCaptionEditorView(
        caption: videoItem.caption,
        onSave: { newCaption in
          vm.updateVideoCaption(newCaption)
        },
        onRemove: {
          vm.updateVideoCaption(nil)
        }
      )
    }
  }
}
