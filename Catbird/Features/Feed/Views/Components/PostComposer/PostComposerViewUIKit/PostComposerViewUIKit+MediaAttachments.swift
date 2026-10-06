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
    VStack(alignment: .leading, spacing: 12) {
      pendingAudioAttachmentSection(vm: vm)
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
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
    .onAppear {
        pcMediaLogger.debug("PostComposerMedia: Rendering media attachments - images: \(vm.mediaItems.count), video: \(vm.videoItem != nil), gif: \(vm.selectedGif != nil)")

    }
  }

  @ViewBuilder
  func pendingAudioAttachmentSection(vm: PostComposerViewModel) -> some View {
    if vm.pendingAudioURL != nil {
      HStack {
        Button {
          showingAudioVisualizerPreview = true
        } label: {
          Label("Finish Audio Attachment", systemImage: "waveform")
            .multilineTextAlignment(.leading)
        }
        .accessibilityHint("Opens your saved recording to create a video attachment.")
        Spacer(minLength: 8)
        Button {
          vm.removePendingAudio()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Remove Audio Attachment")
      }
      .disabled(vm.isPreparingPendingAudio)
    }
  }
  
  @ViewBuilder
  private func imageAttachmentsView(vm: PostComposerViewModel) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
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
            },
            onRetry: { Task { await vm.retryMediaLoading(withId: item.id) } }
          )
        }
      }
    }
    .scrollClipDisabled()
  }
  
  @ViewBuilder
  func videoAttachmentView(videoItem: PostComposerViewModel.MediaItem, vm: PostComposerViewModel) -> some View {
    PostComposerUIKitVideoAttachmentView(videoItem: videoItem, vm: vm)
  }
  
  @ViewBuilder
  func selectedGifView(_ gif: TenorGif, vm: PostComposerViewModel) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ZStack(alignment: .topTrailing) {
        GifVideoView(gif: gif, onTap: {})
          .frame(maxHeight: 200)
          .clipShape(RoundedRectangle(cornerRadius: 12))

        Button(action: {
          pcMediaLogger.info("PostComposerMedia: Removing GIF attachment")
          vm.removeSelectedGif()
        }) {
          ComposerAttachmentRemoveLabel()
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Remove GIF")
      }
    }
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
        isVideo: true,
        onRetry: { Task { await vm.retryMediaLoading(withId: videoItem.id) } }
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
                .foregroundStyle(.tint)
              Text(langName)
                .fontWeight(.medium)
                .lineLimit(1)
            }
            .appFont(AppTextRole.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(platformColor: .platformSystemGray6), in: Capsule())
          }
          .buttonStyle(.plain)

          Button {
            vm.updateVideoCaption(nil)
          } label: {
            Image(systemName: "xmark.circle.fill")
              .appFont(AppTextRole.caption2)
              .foregroundStyle(.secondary)
              .frame(minWidth: 44, minHeight: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Remove Captions")
        } else {
          Button {
            showingCaptionEditor = true
          } label: {
            HStack(spacing: 4) {
              Image(systemName: "captions.bubble")
                .foregroundStyle(.secondary)
              Text("Add Captions")
                .foregroundColor(.secondary)
            }
            .appFont(AppTextRole.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(platformColor: .platformSystemGray6), in: Capsule())
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
