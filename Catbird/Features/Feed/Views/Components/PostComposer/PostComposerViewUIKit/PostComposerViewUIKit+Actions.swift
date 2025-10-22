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
    let hasContent = !vm.postText.isEmpty || !vm.mediaItems.isEmpty || vm.videoItem != nil
    pcActionsLogger.debug("PostComposerActions: Has content: \(hasContent) - text: \(!vm.postText.isEmpty), media: \(!vm.mediaItems.isEmpty), video: \(vm.videoItem != nil)")
    if hasContent {
      pcActionsLogger.info("PostComposerActions: Showing dismiss alert due to content")
      showingDismissAlert = true
    } else {
      pcActionsLogger.info("PostComposerActions: Discarding empty composer")
      dismissReason = .discard
      appState.composerDraftManager.clearDraft()
      dismiss()
    }
  }
  
  func submitAction(vm: PostComposerViewModel) {
    guard canSubmit(vm: vm) else { 
      pcActionsLogger.warning("PostComposerActions: Submit blocked - canSubmit returned false")
      return 
    }
    pcActionsLogger.info("PostComposerActions: Submit initiated - isThreadMode: \(vm.isThreadMode), text length: \(vm.postText.count), media: \(vm.mediaItems.count), video: \(vm.videoItem != nil), gif: \(vm.selectedGif != nil)")
    isSubmitting = true
    
    Task {
      do {
        if vm.isThreadMode {
          pcActionsLogger.info("PostComposerActions: Creating thread with \(vm.threadEntries.count) entries")
          try await vm.createThread()
        } else {
          pcActionsLogger.info("PostComposerActions: Creating single post")
          try await vm.createPost()
        }
        pcActionsLogger.info("PostComposerActions: Post/thread created successfully")
        await MainActor.run {
          appState.composerDraftManager.clearDraft()
          vm.clearAll()
          dismissReason = .submit
          dismiss()
        }
      } catch {
        await MainActor.run {
          isSubmitting = false
          pcActionsLogger.error("PostComposerActions: Submit failed - error: \(error.localizedDescription)")
        }
      }
    }
  }
  
  func canSubmit(vm: PostComposerViewModel) -> Bool {
    let text = vm.postText.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasMedia = !vm.mediaItems.isEmpty || vm.videoItem != nil || vm.selectedGif != nil
    let result = !text.isEmpty || hasMedia
    pcActionsLogger.debug("PostComposerActions: canSubmit check - text: \(!text.isEmpty), media: \(hasMedia), result: \(result)")
    return result
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
  
  func handleMediaSelection(from items: [PhotosPickerItem], isVideo: Bool = false, vm: PostComposerViewModel) {
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
