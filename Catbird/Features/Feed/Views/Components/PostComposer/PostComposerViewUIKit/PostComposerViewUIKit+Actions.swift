//
//  PostComposerViewUIKit+Actions.swift
//  Catbird
//

import SwiftUI
import Petrel
import os
import PhotosUI

private let pcActionsLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Catbird", category: "PostComposerActions")

extension PostComposerViewUIKit {
  
  func cancelAction(vm: PostComposerViewModel) {
    pcActionsLogger.info("PostComposerActions: Cancel tapped")
    if hasContent(vm: vm) {
      pcActionsLogger.info("PostComposerActions: Showing dismiss alert due to content")
      showingDismissAlert = true
    } else {
      pcActionsLogger.info("PostComposerActions: Discarding empty composer")
      let ended = vm.isReply ? vm.minimizeEditingDraft() : vm.discardEditingDraft()
      guard ended else { return }
      dismissReason = .discard
      dismiss()
    }
  }
  
  func submitAction(vm: PostComposerViewModel) {
    let validation = vm.submitValidationState
    guard canSubmit(vm: vm) else {
      pcActionsLogger.warning("PostComposerActions: Submit blocked - \(validation.message ?? "unknown validation failure")")
      return 
    }
    pcActionsLogger.info("PostComposerActions: Submit initiated - isThreadMode: \(vm.isThreadMode), text length: \(vm.postText.count), media: \(vm.mediaItems.count), video: \(vm.videoItem != nil), gif: \(vm.selectedGif != nil)")
    isSubmitting = true
    
    Task { @MainActor in
      do {
        let completed: Bool
        if vm.isThreadMode {
          completed = try await vm.createThread()
        } else {
          completed = try await vm.createPost()
        }
        guard completed else {
          isSubmitting = false
          vm.saveDraftIfNeeded()
          appState.toastManager.show(ToastItem(
            message: "Your newer draft changes have been kept.", icon: "doc.text"
          ))
          return
        }
        vm.clearAll()
        dismissReason = .submit
        dismiss()
      } catch {
        isSubmitting = false
        pcActionsLogger.error("PostComposerActions: Submit failed - error: \(String(describing: error), privacy: .public)")
        vm.saveDraftIfNeeded()
        if let message = PostComposerErrorCopy.message(for: error, isThread: vm.isThreadMode) {
          appState.toastManager.show(ToastItem(
            message: message, icon: "exclamationmark.triangle.fill", duration: 4
          ))
        }
      }
    }
  }
  
  func canSubmit(vm: PostComposerViewModel) -> Bool {
    return vm.submitValidationState.canSubmit && !isSubmitting && !hasPendingMediaIntent
  }
  
  func insertEmoji(_ emoji: String, vm: PostComposerViewModel) {
    pcActionsLogger.info("PostComposerActions: Inserting emoji '\(emoji)' at cursor position \(vm.cursorPosition)")
    var attributed = vm.richAttributedText
    let plainText = attributed.string as NSString
    let insertionPoint = min(max(0, vm.cursorPosition), plainText.length)
    
    let mutable = NSMutableAttributedString(attributedString: attributed)
    mutable.replaceCharacters(in: NSRange(location: insertionPoint, length: 0), with: emoji)
    vm.richAttributedText = mutable
    vm.cursorPosition = insertionPoint + (emoji as NSString).length
    pendingSelectionRange = NSRange(location: vm.cursorPosition, length: 0)
    pcActionsLogger.debug("PostComposerActions: Emoji inserted, new cursor position: \(vm.cursorPosition)")
  }
  
  func presentPhotoPicker(vm: PostComposerViewModel) {
    photoPickerVisible = true
  }
  
  func handleMediaSelection(from items: [PhotosPickerItem], isVideo: Bool = false, vm: PostComposerViewModel) {
    guard !items.isEmpty else { return }
    pcActionsLogger.info("PostComposerActions: Handling media selection - items: \(items.count), isVideo: \(isVideo)")
    Task {
      if isVideo {
        if let item = items.first {
          pcActionsLogger.debug("PostComposerActions: Processing video selection")
          await vm.processVideoSelection(item)
        }
      } else {
        pcActionsLogger.debug("PostComposerActions: Processing photo selection")
        await vm.processPhotoSelection(items)
      }
      await MainActor.run {
        photoPickerItems = []
        videoPickerItems = []
        pcActionsLogger.debug("PostComposerActions: Media picker items cleared")
      }
    }
  }
}
