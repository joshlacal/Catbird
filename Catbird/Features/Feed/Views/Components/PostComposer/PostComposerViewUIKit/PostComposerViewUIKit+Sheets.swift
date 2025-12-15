//
//  PostComposerViewUIKit+Sheets.swift
//  Catbird
//

import SwiftUI
import PhotosUI
import Petrel
import os

private let pcSheetsLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Catbird", category: "PostComposerSheets")

extension PostComposerViewUIKit {
  
  @ViewBuilder
  func sheetModifiers<Content: View>(vm: PostComposerViewModel, _ content: Content) -> some View {
    let photoPickerContent = content
      .photosPicker(isPresented: $photoPickerVisible, selection: $photoPickerItems, matching: .images, photoLibrary: .shared())
      .onChange(of: photoPickerItems) { items in
        pcSheetsLogger.info("PostComposerSheets: Photo picker items changed - count: \(items.count)")
        handleMediaSelection(from: items, isVideo: false, vm: vm)
      }
      .photosPicker(isPresented: $videoPickerVisible, selection: $videoPickerItems, matching: .videos, photoLibrary: .shared())
      .onChange(of: videoPickerItems) { items in
        pcSheetsLogger.info("PostComposerSheets: Video picker items changed - count: \(items.count)")
        handleMediaSelection(from: items, isVideo: true, vm: vm)
      }
    
    let audioSheetContent = photoPickerContent
      .sheet(isPresented: $showingAudioRecorder) {
        PostComposerAudioRecordingView(
          onAudioRecorded: { url in
            pcSheetsLogger.info("PostComposerSheets: Audio recorded - URL: \(url.path)")
            currentAudioURL = url
            // Note: duration would need to be calculated separately if needed
            showingAudioRecorder = false
          },
          onCancel: {
            pcSheetsLogger.info("PostComposerSheets: Audio recording cancelled")
            showingAudioRecorder = false
          }
        )
      }
      .sheet(isPresented: $showingAccountSwitcher) {
        // Pass current draft when switching accounts from composer
        AccountSwitcherView(showsDismissButton: true, draftToTransfer: vm.saveDraftState())
          .applyAppStateEnvironment(appState)
          .onDisappear {
            handleAccountSwitchComplete(vm: vm)
          }
      }
    
    let otherSheetsContent = audioSheetContent
      .sheet(isPresented: $showingLanguagePicker) {
        LanguagePickerSheet(selectedLanguages: Binding(
          get: { vm.selectedLanguages },
          set: { vm.selectedLanguages = $0 }
        ))
      }
      .sheet(isPresented: $showingGifPicker) {
        GifPickerView { gif in
          pcSheetsLogger.info("PostComposerSheets: GIF selected - URL: \(gif.url)")
          vm.selectGif(gif)
          showingGifPicker = false
        }
      }
      .sheet(isPresented: $showingThreadgate) {
        ThreadgateOptionsView(settings: Binding(
          get: { vm.threadgateSettings },
          set: { vm.threadgateSettings = $0 }
        ))
      }
      .sheet(isPresented: $showingLabelSelector) {
        LabelSelectorView(selectedLabels: Binding(
          get: { vm.selectedLabels },
          set: { vm.selectedLabels = $0 }
        ))
      }

    
    let draftsSheetContent = otherSheetsContent
      .sheet(isPresented: $showingDrafts) {
        DraftsListView(appState: appState) { draftVM in
          pcSheetsLogger.info("PostComposerSheets: Draft selected from drafts list")
          if let draft = appState.composerDraftManager.loadSavedDraft(draftVM) {
            pcSheetsLogger.debug("PostComposerSheets: Loading draft - text length: \(draft.postText.count)")
            // Apply draft to current composer
            vm.enterDraftMode()
            vm.restoreDraftState(draft)
            // Move focus to editor after loading
            activeEditorFocusID = UUID()
          } else {
            pcSheetsLogger.warning("PostComposerSheets: Failed to load draft")
          }
          showingDrafts = false
        }
      }

    let linkSheetContent = draftsSheetContent
      .sheet(isPresented: $showingLinkCreation) {
        LinkCreationDialog(
          selectedText: selectedTextForLink,
          onComplete: { url, displayText in
            pcSheetsLogger.info("PostComposerSheets: Link created - URL: \(url), displayText: '\(displayText ?? "nil")', range: \(selectedRangeForLink)")
            let linkText = displayText ?? selectedTextForLink
            let linkURL = url
            
            let newFacet = RichTextFacetUtils.LinkFacet(
                range: selectedRangeForLink,
                url: linkURL,
              displayText: linkText
            )
            linkFacets.append(newFacet)
            pcSheetsLogger.debug("PostComposerSheets: Total link facets after creation: \(linkFacets.count)")
            vm.updateManualLinkFacets(from: linkFacets)
            
            // Update the attributed text to show the link
            let mutable = NSMutableAttributedString(attributedString: vm.richAttributedText)
            mutable.addAttribute(.link, value: linkURL, range: selectedRangeForLink)
            mutable.addAttribute(.foregroundColor, value: PlatformColor.systemBlue, range: selectedRangeForLink)
            vm.richAttributedText = mutable
            
            // Move cursor after the link
            let newPosition = selectedRangeForLink.location + selectedRangeForLink.length
            pendingSelectionRange = NSRange(location: newPosition, length: 0)
            pcSheetsLogger.debug("PostComposerSheets: Cursor moved to position \(newPosition)")
            
            showingLinkCreation = false
          },
          onCancel: {
            pcSheetsLogger.info("PostComposerSheets: Link creation cancelled")
            showingLinkCreation = false
          }
        )
      }
      .sheet(isPresented: Binding(
        get: { vm.isAltTextEditorPresented },
        set: { vm.isAltTextEditorPresented = $0 }
      )) {
        if let videoItem = vm.videoItem, vm.currentEditingMediaId == videoItem.id {
          AltTextEditorView(
            altText: videoItem.altText,
            image: videoItem.image ?? Image(systemName: "video.fill"),
            imageId: videoItem.id,
            imageData: videoItem.rawData,
            onSave: vm.updateAltText
          )
        } else if let index = vm.mediaItems.firstIndex(where: { $0.id == vm.currentEditingMediaId }) {
          AltTextEditorView(
            altText: vm.mediaItems[index].altText,
            image: vm.mediaItems[index].image ?? Image(systemName: "photo"),
            imageId: vm.mediaItems[index].id,
            imageData: vm.mediaItems[index].rawData,
            onSave: vm.updateAltText
          )
        }
      }
      .sheet(isPresented: Binding(
        get: { vm.isPhotoEditorPresented },
        set: { vm.isPhotoEditorPresented = $0 }
      )) {
        #if os(iOS)
        if let index = vm.currentEditingImageIndex,
           vm.mediaItems.indices.contains(index),
           let rawData = vm.mediaItems[index].rawData,
           let uiImage = UIImage(data: rawData) {
          PhotoEditorSheet(image: uiImage) { editedImage in
            pcSheetsLogger.info("PostComposerSheets: Photo edit completed for image at index \(index)")
            vm.updateEditedImage(editedImage, at: index)
          }
        }
        #elseif os(macOS)
        if let index = vm.currentEditingImageIndex,
           vm.mediaItems.indices.contains(index),
           let rawData = vm.mediaItems[index].rawData,
           let nsImage = NSImage(data: rawData) {
          PhotoEditorSheet(image: nsImage) { editedImage in
            pcSheetsLogger.info("PostComposerSheets: Photo edit completed for image at index \(index)")
            vm.updateEditedImage(editedImage, at: index)
          }
        }
        #endif
      }

    linkSheetContent
      .alert("Discard Draft?", isPresented: $showingDismissAlert) {
        Button("Discard", role: .destructive) {
          pcSheetsLogger.info("PostComposerSheets: User chose to discard draft")
          dismissReason = .discard
          appState.composerDraftManager.clearDraft()
          dismiss()
        }
        Button("Keep Editing", role: .cancel) { 
          pcSheetsLogger.info("PostComposerSheets: User chose to keep editing")
        }
      } message: {
        Text("You'll lose your post if you discard now.")
      }
  }
}
