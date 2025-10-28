//
//  PostComposerViewUIKit+Thread.swift
//  Catbird
//

import SwiftUI
import Petrel
import os

private let pcThreadLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Catbird", category: "PostComposerThread")

extension PostComposerViewUIKit {
  
  @ViewBuilder
  func threadEntriesSection(vm: PostComposerViewModel) -> some View {
    if vm.isThreadMode && vm.threadEntries.count > 1 {
      LazyVStack(spacing: 0) {
        ForEach(Array(vm.threadEntries.enumerated()), id: \.offset) { index, entry in
          VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
              VStack(spacing: 4) {
                // Use UIKit avatar view for consistency
                Button(action: {
                  pcThreadLogger.info("PostComposerThread: Avatar tapped in thread entry - opening account switcher")
                  showingAccountSwitcher = true
                }) {
                  #if os(iOS)
                  UIKitAvatarView(
                    did: appState.currentUserDID,
                    client: appState.atProtoClient,
                    size: 60,
                    avatarURL: appState.currentUserProfile?.avatar?.url
                  )
                  .frame(width: 60, height: 60)
                  #else
                  if let profile = appState.currentUserProfile, let avatarURL = profile.avatar {
                    AsyncImage(url: URL(string: avatarURL.description)) { image in
                      image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                      Circle().fill(Color.systemGray5)
                    }
                    .frame(width: 60, height: 60)
                    .clipShape(Circle())
                  } else {
                    Circle()
                      .fill(Color.systemGray5)
                      .frame(width: 60, height: 60)
                  }
                  #endif
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Switch account")
                
                if index < vm.threadEntries.count - 1 {
                  Rectangle()
                    .fill(Color.systemGray4)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                }
              }
              
              if index == vm.currentThreadIndex {
                activeThreadEntry(vm: vm)
              } else {
                inactiveThreadEntry(entry: entry, vm: vm)
              }
              
              if vm.threadEntries.count > 1 {
                Button(action: { 
                  pcThreadLogger.info("PostComposerThread: Removing thread entry at index \(index)")
                  vm.removeThreadEntry(at: index) 
                }) {
                  Image(systemName: "xmark.circle.fill")
                    .appFont(size: 20)
                    .foregroundStyle(.white, Color.systemGray3)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
              }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .contentShape(Rectangle())
            .onTapGesture {
              pcThreadLogger.info("PostComposerThread: Switching to thread entry at index \(index)")
              withAnimation(.easeInOut(duration: 0.2)) {
                vm.updateCurrentThreadEntry()
                vm.currentThreadIndex = index
                vm.loadEntryState()
              }
            }
            
            if index == vm.currentThreadIndex {
              activeEntryMediaSection(vm: vm)
              activeEntryMetadataSection(vm: vm)
            } else {
              inactiveEntryMediaSection(entry: entry)
              inactiveEntryMetadataSection(entry: entry, vm: vm)
            }
            
            if index < vm.threadEntries.count - 1 {
              Divider()
                .padding(.leading, 88)
            }
          }
          .opacity(index == vm.currentThreadIndex ? 1.0 : 0.55)
        }
      }
      .onAppear {
          pcThreadLogger.debug("PostComposerThread: Rendering thread section with \(vm.threadEntries.count) entries, current index: \(vm.currentThreadIndex)")

      }
    }
  }
  
  @ViewBuilder
  private func activeThreadEntry(vm: PostComposerViewModel) -> some View {
    RichEditorContainer(
      attributedText: Binding(
        get: { vm.richAttributedText },
        set: { vm.richAttributedText = $0 }
      ),
      linkFacets: $linkFacets,
      pendingSelectionRange: $pendingSelectionRange,
      placeholder: "What's on your mind?",
      onImagePasted: { image in
        #if os(iOS)
        Task {
          await vm.handleMediaPaste([NSItemProvider(object: image)])
        }
        #endif
      },
      onGenmojiDetected: { emojis in 
        pcThreadLogger.info("PostComposerThread: Genmoji detected in thread entry: \(emojis)")
      },
      onTextChanged: { attrString, cursorPos in
        pcThreadLogger.debug("PostComposerThread: Active thread entry text changed - length: \(attrString.length), cursor: \(cursorPos)")
        vm.updateFromAttributedText(attrString, cursorPosition: cursorPos)
        vm.updateManualLinkFacets(from: linkFacets)
      },
      onLinkCreationRequested: { text, range in
        pcThreadLogger.info("PostComposerThread: Link creation requested in thread entry - text: '\(text)', range: \(range)")
        selectedTextForLink = text
        selectedRangeForLink = range
        showingLinkCreation = true
      },
      // Avoid auto-focus on every attach to prevent keyboard reloads.
      focusOnAppear: false,
      focusActivationID: activeEditorFocusID,
      onPhotosAction: { photoPickerVisible = true },
      onVideoAction: { videoPickerVisible = true },
      onAudioAction: { showingAudioRecorder = true },
      onGifAction: { vm.showingGifPicker = true },
      onLabelsAction: { vm.showLabelSelector = true },
      onThreadgateAction: { vm.showThreadgateOptions = true },
      onLanguageAction: { showingLanguagePicker = true },
      onThreadAction: {
        if vm.isThreadMode {
          pcThreadLogger.info("PostComposerThread: Adding new thread entry to existing thread")
          withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            vm.addNewThreadEntry()
            activeEditorFocusID = UUID()
          }
        } else {
          pcThreadLogger.info("PostComposerThread: Entering thread mode from active entry")
          withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            vm.enterThreadMode()
            vm.addNewThreadEntry()
            activeEditorFocusID = UUID()
          }
        }
      },
      onLinkAction: {
        selectedTextForLink = ""
        selectedRangeForLink = NSRange(location: vm.postText.count, length: 0)
        showingLinkCreation = true
      },
      allowTenor: appState.appSettings.allowTenor,
      onTextViewCreated: { textView in
        pcThreadLogger.debug("PostComposerThread: Text view created for active thread entry")
        #if os(iOS)
        vm.activeRichTextView = textView
        #endif
      }
    )
    .id(appState.currentUserDID ?? "composer-unknown-user")
    .frame(minHeight: 120)
    .frame(maxWidth: .infinity)
    .onAppear {
        pcThreadLogger.debug("PostComposerThread: Rendering active thread entry editor")

    }
  }
  
  @ViewBuilder
  private func inactiveThreadEntry(entry: ThreadEntry, vm: PostComposerViewModel) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if let profile = appState.currentUserProfile {
        Text(profile.displayName ?? profile.handle.description)
          .appFont(AppTextRole.subheadline)
          .fontWeight(.semibold)
      }
      
      Text(entry.text.isEmpty ? "Write post…" : entry.text)
        .appFont(AppTextRole.body)
        .foregroundColor(entry.text.isEmpty ? .secondary : .primary)
        .multilineTextAlignment(.leading)
        .lineLimit(6)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
    }
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
  
  @ViewBuilder
  private func activeEntryMediaSection(vm: PostComposerViewModel) -> some View {
    Group {
      if let gif = vm.selectedGif {
        selectedGifView(gif)
      } else if let videoItem = vm.videoItem, let image = videoItem.image {
        HStack(spacing: 12) {
          image
            .resizable()
            .scaledToFit()
            .frame(height: 120)
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.systemGray5, lineWidth: 1))
          Spacer()
          Button("Remove") { vm.videoItem = nil }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
      } else if !vm.mediaItems.isEmpty {
#if os(iOS)
        MediaGalleryView(
          mediaItems: Binding(
            get: { vm.mediaItems },
            set: { vm.mediaItems = $0 }
          ),
          currentEditingMediaId: Binding(
            get: { vm.currentEditingMediaId },
            set: { vm.currentEditingMediaId = $0 }
          ),
          isAltTextEditorPresented: Binding(
            get: { vm.isAltTextEditorPresented },
            set: { vm.isAltTextEditorPresented = $0 }
          ),
          maxImagesAllowed: vm.maxImagesAllowed,
          onAddMore: { photoPickerVisible = true },
          onMoveLeft: { id in vm.moveMediaItemLeft(id: id) },
          onMoveRight: { id in vm.moveMediaItemRight(id: id) },
          onCropSquare: { id in vm.cropMediaItemToSquare(id: id) },
          onPaste: nil,
          hasClipboardMedia: false,
          onReorder: { from, to in vm.moveMediaItem(from: from, to: to) },
          onExternalImageDrop: { datas in
            let providers: [NSItemProvider] = datas.compactMap { data in
#if os(iOS)
              if let image = UIImage(data: data) { return NSItemProvider(object: image) }
#endif
              return nil
            }
            if !providers.isEmpty { Task { await vm.handleMediaPaste(providers) } }
          }
        )
        .padding(.top, 8)
#else
        MediaGalleryView(
          mediaItems: Binding(
            get: { vm.mediaItems },
            set: { vm.mediaItems = $0 }
          ),
          currentEditingMediaId: Binding(
            get: { vm.currentEditingMediaId },
            set: { vm.currentEditingMediaId = $0 }
          ),
          isAltTextEditorPresented: Binding(
            get: { vm.isAltTextEditorPresented },
            set: { vm.isAltTextEditorPresented = $0 }
          ),
          maxImagesAllowed: vm.maxImagesAllowed,
          onAddMore: { photoPickerVisible = true },
          onMoveLeft: { id in vm.moveMediaItemLeft(id: id) },
          onMoveRight: { id in vm.moveMediaItemRight(id: id) },
          onCropSquare: { id in vm.cropMediaItemToSquare(id: id) },
          onPaste: nil,
          hasClipboardMedia: false,
          onReorder: { from, to in vm.moveMediaItem(from: from, to: to) }
        )
        .padding(.top, 8)
#endif
      }
    }
  }
  
  @ViewBuilder
  private func inactiveEntryMediaSection(entry: ThreadEntry) -> some View {
    Group {
      if let gif = entry.selectedGif {
        GifVideoView(gif: gif, onTap: {})
          .frame(maxHeight: 200)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .allowsHitTesting(false)
          .padding(.horizontal)
          .padding(.vertical, 8)
      } else if let videoItem = entry.videoItem, let image = videoItem.image {
        image
          .resizable()
          .scaledToFit()
          .frame(height: 120)
          .cornerRadius(10)
          .padding(.horizontal)
          .padding(.vertical, 8)
          .allowsHitTesting(false)
      } else if !entry.mediaItems.isEmpty {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6)], spacing: 6) {
          ForEach(entry.mediaItems.indices, id: \.self) { idx in
            if let image = entry.mediaItems[idx].image {
              image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 80, height: 80)
                .clipped()
                .cornerRadius(8)
            }
          }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
      }
    }
  }
  
  @ViewBuilder
  private func activeEntryMetadataSection(vm: PostComposerViewModel) -> some View {
    VStack(spacing: 8) {
      // Compact inline outline hashtags
      if !vm.outlineTags.isEmpty {
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
                  Button(action: { vm.outlineTags.removeAll { $0 == tag } }) {
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
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
      }
      
      // Compact inline language chips
      if !vm.selectedLanguages.isEmpty {
        HStack(spacing: 8) {
          Image(systemName: "globe")
            .font(.system(size: 12))
            .foregroundColor(.secondary)
          
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
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
      }
    }
  }
  
  @ViewBuilder
  private func inactiveEntryMetadataSection(entry: ThreadEntry, vm: PostComposerViewModel) -> some View {
    VStack(spacing: 8) {
      // Compact inline outline hashtags
      if !entry.outlineTags.isEmpty {
        HStack(spacing: 8) {
          Image(systemName: "number")
            .font(.system(size: 12))
            .foregroundColor(.secondary)
          
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
              ForEach(entry.outlineTags, id: \.self) { tag in
                Text("#\(tag)")
                  .font(.system(size: 11, weight: .medium))
                  .padding(.horizontal, 8)
                  .padding(.vertical, 4)
                  .background(Color.secondary.opacity(0.1))
                  .foregroundColor(.secondary)
                  .cornerRadius(6)
              }
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
      }
      
      // Compact inline language chips
      if !entry.selectedLanguages.isEmpty {
        HStack(spacing: 8) {
          Image(systemName: "globe")
            .font(.system(size: 12))
            .foregroundColor(.secondary)
          
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
              ForEach(entry.selectedLanguages, id: \.self) { lang in
                Text(Locale.current.localizedString(forLanguageCode: lang.lang.languageCode?.identifier ?? "") ?? lang.lang.minimalIdentifier)
                  .font(.system(size: 11, weight: .medium))
                  .padding(.horizontal, 8)
                  .padding(.vertical, 4)
                  .background(Color.secondary.opacity(0.1))
                  .foregroundColor(.secondary)
                  .cornerRadius(6)
              }
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
      }
    }
  }
}
