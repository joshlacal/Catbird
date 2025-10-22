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
        ZStack(alignment: .topTrailing) {
          if let img = item.image {
            img
              .resizable()
              .aspectRatio(contentMode: .fill)
              .frame(width: 100, height: 100)
              .clipped()
              .cornerRadius(8)
          } else {
            Rectangle()
              .fill(Color.systemGray5)
              .frame(width: 100, height: 100)
              .cornerRadius(8)
              .overlay(ProgressView().progressViewStyle(.circular))
          }
          
          Button(action: { 
            pcMediaLogger.info("PostComposerMedia: Removing image at index \(index)")
            vm.mediaItems.remove(at: index)
          }) {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(.white)
              .background(Circle().fill(Color.black.opacity(0.5)))
          }
          .buttonStyle(PlainButtonStyle())
          .padding(4)
        }
      }
    }
  }
  
  @ViewBuilder
  private func videoAttachmentView(videoItem: PostComposerViewModel.MediaItem, vm: PostComposerViewModel) -> some View {
    if let image = videoItem.image {
      ZStack(alignment: .topTrailing) {
        image
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(height: 200)
          .cornerRadius(12)
          .overlay(
            Image(systemName: "play.circle.fill")
              .font(.system(size: 48))
              .foregroundColor(.white)
              .shadow(radius: 4)
          )
        
        Button(action: { 
          pcMediaLogger.info("PostComposerMedia: Removing video attachment")
          vm.videoItem = nil 
        }) {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(.white)
            .background(Circle().fill(Color.black.opacity(0.5)))
        }
        .buttonStyle(PlainButtonStyle())
        .padding(8)
      }
    }
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
