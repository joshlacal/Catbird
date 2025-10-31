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
      if !vm.mediaItems.isEmpty {
        imageAttachmentsView(vm: vm)
      }
      
      if let videoItem = vm.videoItem {
        videoAttachmentView(videoItem: videoItem, vm: vm)
      }
    }
    .padding(.horizontal, 16)
    .onAppear {
        pcMediaLogger.debug("PostComposerMedia: Rendering media attachments - images: \(vm.mediaItems.count), video: \(vm.videoItem != nil)")

    }
  }
  
  @ViewBuilder
  private func imageAttachmentsView(vm: PostComposerViewModel) -> some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
      ForEach(Array(vm.mediaItems.enumerated()), id: \.offset) { index, item in
        MediaItemView(
          item: item,
          onRemove: {
            pcMediaLogger.info("PostComposerMedia: Removing image at index \(index)")
            vm.mediaItems.remove(at: index)
          },
          onEditAlt: {
            pcMediaLogger.info("PostComposerMedia: Opening alt text editor for image \(item.id)")
            vm.beginEditingAltText(for: item.id)
          },
          onEditImage: {
            pcMediaLogger.info("PostComposerMedia: Opening photo editor for image \(item.id) at index \(index)")
            vm.beginEditingImage(for: item.id, at: index)
          }
        )
      }
    }
  }
  
  @ViewBuilder
  private func videoAttachmentView(videoItem: PostComposerViewModel.MediaItem, vm: PostComposerViewModel) -> some View {
    MediaItemView(
      item: videoItem,
      onRemove: {
        pcMediaLogger.info("PostComposerMedia: Removing video attachment")
        vm.videoItem = nil
      },
      onEditAlt: {
        pcMediaLogger.info("PostComposerMedia: Opening alt text editor for video \(videoItem.id)")
        vm.beginEditingAltText(for: videoItem.id)
      },
      isVideo: true
    )
  }
  
  @ViewBuilder
  func selectedGifView(_ gif: TenorGif) -> some View {
    VStack(alignment: .trailing, spacing: 8) {
      ZStack(alignment: .topTrailing) {
        GifVideoView(gif: gif, onTap: {})
          .frame(maxHeight: 200)
          .clipShape(RoundedRectangle(cornerRadius: 12))
        
        Button(action: { 
          pcMediaLogger.info("PostComposerMedia: Removing GIF attachment")
          viewModel?.selectedGif = nil 
        }) {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(.white)
            .background(Circle().fill(Color.black.opacity(0.5)))
        }
        .buttonStyle(PlainButtonStyle())
        .padding(8)
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
  }
}
