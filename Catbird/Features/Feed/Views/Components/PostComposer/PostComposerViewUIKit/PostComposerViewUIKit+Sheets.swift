//
//  PostComposerViewUIKit+Sheets.swift
//  Catbird
//

import SwiftUI
import PhotosUI
import Petrel
import os
import AVFoundation
import CoreMedia

private let pcSheetsLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Catbird", category: "PostComposerSheets")

extension PostComposerViewUIKit {
  
  @ViewBuilder
  func sheetModifiers<Content: View>(vm: PostComposerViewModel, _ content: Content) -> some View {
    let photoPickerContent = content
      .photosPicker(isPresented: $photoPickerVisible, selection: $photoPickerItems,
                    maxSelectionCount: max(1, vm.maxImagesAllowed - vm.mediaItems.count),
                    matching: .images, preferredItemEncoding: .current, photoLibrary: .shared())
      .onChange(of: photoPickerItems) { _, items in
        pcSheetsLogger.info("PostComposerSheets: Photo picker items changed - count: \(items.count)")
        handleMediaSelection(from: items, isVideo: false, vm: vm)
      }
      .photosPicker(isPresented: $videoPickerVisible, selection: $videoPickerItems,
                    maxSelectionCount: 1, matching: .videos, photoLibrary: .shared())
      .onChange(of: videoPickerItems) { _, items in
        pcSheetsLogger.info("PostComposerSheets: Video picker items changed - count: \(items.count)")
        handleMediaSelection(from: items, isVideo: true, vm: vm)
      }
      .alert(item: Binding(
        get: { vm.alertItem },
        set: { vm.alertItem = $0 }
      )) { item in
        Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("OK")))
      }
    
    let audioSheetContent = photoPickerContent
      .sheet(isPresented: $showingAudioRecorder, onDismiss: {
        if viewModel === vm, vm.ownsEditingDraft, vm.pendingAudioURL != nil {
          showingAudioVisualizerPreview = true
        }
      }) {
        let recordingClaim = vm.editingClaim
        let recordingEntryID = vm.threadEntries.indices.contains(vm.currentThreadIndex)
          ? vm.threadEntries[vm.currentThreadIndex].id : nil
        PostComposerAudioRecordingView(
          onAudioRecorded: { url in
            guard viewModel === vm, let recordingEntryID,
                  vm.preserveRecordedAudio(at: url, claim: recordingClaim, threadEntryID: recordingEntryID) else { return }
            showingAudioRecorder = false
          },
          onCancel: {
            pcSheetsLogger.info("PostComposerSheets: Audio recording cancelled")
            showingAudioRecorder = false
          }
        )
      }
      .sheet(isPresented: $showingAudioVisualizerPreview) {
        if let audioURL = vm.pendingAudioURL, let threadEntryID = vm.pendingAudioThreadEntryID,
           vm.threadEntries.contains(where: { $0.id == threadEntryID }) {
          let previewClaim = vm.editingClaim
          PendingComposerAudioPreview(
            audioURL: audioURL,
            onVideoGenerated: { videoURL in
              guard viewModel === vm else { return }
              Task { @MainActor in
                do {
                  let attached = try await vm.finishPendingAudio(
                    withVideoAt: videoURL, audioURL: audioURL,
                    claim: previewClaim, threadEntryID: threadEntryID
                  )
                  if !attached, viewModel === vm, vm.ownsEditingDraft, vm.editingClaim == previewClaim,
                     vm.pendingAudioURL == audioURL {
                    appState.toastManager.show(ToastItem(
                      message: "Your draft changed. Your recording was kept; tap Finish Audio Attachment to try again.",
                      icon: "waveform"
                    ))
                  }
                } catch {
                  guard !Task.isCancelled, viewModel === vm, vm.ownsEditingDraft,
                        vm.editingClaim == previewClaim, vm.pendingAudioURL == audioURL else { return }
                  pcSheetsLogger.error("PostComposerSheets: Audio attachment failed - \(String(describing: error), privacy: .public)")
                  let reason = UserFacingError.message(for: error, action: "attach your recording")
                    ?? "Couldn’t attach your recording."
                  appState.toastManager.show(ToastItem(
                    message: "\(reason) Your recording was kept.",
                    icon: "exclamationmark.triangle.fill"
                  ))
                }
              }
            },
            onCancel: { showingAudioVisualizerPreview = false }
          )
          .environment(appState)
        } else if let audioURL = vm.pendingAudioURL {
          NavigationStack {
            ScrollView {
              VStack(spacing: 20) {
                Text("Original Post Unavailable").appFont(AppTextRole.headline)
                Text("This recording belongs to a post that is no longer in this draft. Save the recording before removing the attachment.")
                ShareLink("Save Recording", item: audioURL)
                Button("Remove Audio Attachment", role: .destructive) {
                  vm.removePendingAudio()
                  showingAudioVisualizerPreview = false
                }
                Button("Close") { showingAudioVisualizerPreview = false }
              }
              .padding()
            }
          }
        }
      }
      .sheet(isPresented: $showingAccountSwitcher) {
        let transfer = accountSwitchSnapshot
        AccountSwitcherView(
          showsDismissButton: true,
          composerTransfer: transfer,
          onSwitchCompleted: { outcome in
            handleAccountSwitchComplete(outcome, vm: vm, snapshot: transfer)
          }
        )
        .environment(AppStateManager.shared)
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
        PostInteractionSettingsView(settings: Binding(
          get: { vm.interactionSettings },
          set: { vm.interactionSettings = $0 }
        ))
      }
      .sheet(isPresented: $showingLabelSelector) {
        LabelSelectorView(selectedLabels: Binding(
          get: { vm.selectedLabels },
          set: { vm.selectedLabels = $0 }
        ))
      }
      .sheet(isPresented: $showingOutlineTagsEditor) {
        NavigationStack {
          OutlineTagsView(tags: Binding(
            get: { vm.outlineTags },
            set: { vm.outlineTags = $0 }
          ))
          .navigationTitle("Hashtags")
          #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
          #endif
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { showingOutlineTagsEditor = false }
            }
          }
          .padding(.horizontal, 16)
        }
      }

    
    let draftsSheetContent = otherSheetsContent
      .sheet(isPresented: $showingDrafts) {
        DraftsListView(appState: appState) { draftVM in
          pcSheetsLogger.info("PostComposerSheets: Draft selected from drafts list")
          if editingSession.savedDraftID == draftVM.id, vm.ownsEditingDraft {
            showingDrafts = false
            return
          }
          do {
            // Flush live typing before the session archives the old editor.
            // The replacement claims a new presentation lease, rejecting late callbacks.
            let replacement = try vm.replacementForSavedDraft(draftVM)
            autoSaveTask?.cancel()
            viewModel = replacement
            activeEditorFocusID = UUID()
            startAutoSave()
          } catch {
            appState.toastManager.show(ToastItem(
              message: error.localizedDescription, icon: "exclamationmark.triangle.fill"
            ))
          }
          showingDrafts = false
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.automatic)
      }

    let linkSheetContent = draftsSheetContent
      .sheet(isPresented: $showingLinkCreation) {
        LinkCreationDialog(
          selectedText: linkSelection?.selectedText ?? "",
          onComplete: { url, displayText in
            guard let selection = linkSelection,
                  let result = ComposerLinkEdit.apply(
                    url: url,
                    displayText: displayText,
                    selection: selection,
                    to: vm.richAttributedText
                  ) else {
              pcSheetsLogger.warning("PostComposerSheets: Refusing stale or invalid link selection")
              linkSelection = nil
              showingLinkCreation = false
              return
            }

            pcSheetsLogger.info("PostComposerSheets: Link created - URL: \(url), range: \(result.linkedRange)")
            vm.updateFromAttributedText(
              result.attributedText,
              cursorPosition: result.caretRange.location
            )
            linkFacets.append(result.linkFacet)
            vm.updateManualLinkFacets(from: linkFacets)
            vm.richAttributedText = result.attributedText
            pendingSelectionRange = result.caretRange
            linkSelection = nil
            showingLinkCreation = false
          },
          onCancel: {
            pcSheetsLogger.info("PostComposerSheets: Link creation cancelled")
            linkSelection = nil
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
      #if os(iOS)
      .fullScreenCover(isPresented: Binding(
        get: { vm.isPhotoEditorPresented },
        set: { vm.isPhotoEditorPresented = $0 }
      )) {
        if let index = vm.currentEditingImageIndex,
           vm.mediaItems.indices.contains(index),
           let rawData = vm.mediaItems[index].rawData,
           let uiImage = UIImage(data: rawData) {
          PhotoEditorSheet(image: uiImage) { editedImage in
            pcSheetsLogger.info("PostComposerSheets: Photo edit completed for image at index \(index)")
            vm.updateEditedImage(editedImage, at: index)
          }
        } else {
          // The photo is gone or not loaded yet; a full-screen cover can't be swiped away.
          Color.clear.onAppear { vm.isPhotoEditorPresented = false }
        }
      }
      #elseif os(macOS)
      .sheet(isPresented: Binding(
        get: { vm.isPhotoEditorPresented },
        set: { vm.isPhotoEditorPresented = $0 }
      )) {
        if let index = vm.currentEditingImageIndex,
           vm.mediaItems.indices.contains(index),
           let rawData = vm.mediaItems[index].rawData,
           let nsImage = NSImage(data: rawData) {
          PhotoEditorSheet(image: nsImage) { editedImage in
            pcSheetsLogger.info("PostComposerSheets: Photo edit completed for image at index \(index)")
            vm.updateEditedImage(editedImage, at: index)
          }
        }
      }
      #endif

    linkSheetContent
  }
}

private struct PendingComposerAudioPreview: View {
  let audioURL: URL
  let onVideoGenerated: (URL) -> Void
  let onCancel: () -> Void
  @State private var duration: TimeInterval?
  @State private var loadingError: String?

  var body: some View {
    Group {
      if let duration {
        AudioVisualizerPreview(
          audioURL: audioURL, audioDuration: duration,
          onVideoGenerated: onVideoGenerated, onCancel: onCancel
        )
      } else {
        NavigationStack {
          Group {
            if let loadingError {
              ContentUnavailableView("Audio Unavailable", systemImage: "waveform",
                                     description: Text(loadingError))
            } else {
              ProgressView("Loading recording…")
            }
          }
          .navigationTitle("Audio Visualizer")
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Cancel", action: onCancel)
            }
          }
        }
      }
    }
    .interactiveDismissDisabled()
    .task(id: audioURL) {
      do {
        let loadedDuration = try await AVURLAsset(url: audioURL).load(.duration).seconds
        guard !Task.isCancelled else { return }
        guard loadedDuration.isFinite, loadedDuration > 0 else {
          throw CocoaError(.fileReadCorruptFile)
        }
        duration = loadedDuration
      } catch {
        guard !Task.isCancelled else { return }
        loadingError = "This recording couldn’t be loaded."
      }
    }
  }
}
