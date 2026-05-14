import Testing
import SwiftUI
@testable import Catbird

@Test("PostComposer State Management - Basic Operations")
func testPostComposerBasicOperations() async throws {
    // Create a mock app state
    let appState = AppState()
    
    // Initialize PostComposerViewModel
    let viewModel = PostComposerViewModel(appState: appState)
    
    // Test 1: Basic text update doesn't cause infinite loops
    await MainActor.run {
        viewModel.postText = "Hello, world!"
        #expect(viewModel.postText == "Hello, world!")
        #expect(viewModel.richAttributedText.string == "Hello, world!")
    }
    
    // Test 2: Reset post clears all state properly
    await MainActor.run {
        viewModel.resetPost()
        #expect(viewModel.postText.isEmpty)
        #expect(viewModel.mediaItems.isEmpty)
        #expect(viewModel.videoItem == nil)
        #expect(viewModel.selectedGif == nil)
        #expect(viewModel.threadEntries.count == 1)
        #expect(viewModel.isThreadMode == false)
    }
}

@Test("PostComposer Thread Mode - State Synchronization")
func testThreadModeStateSynchronization() async throws {
    let appState = AppState()
    let viewModel = PostComposerViewModel(appState: appState)
    
    await MainActor.run {
        // Set up initial content
        viewModel.postText = "First post"
        viewModel.outlineTags = ["test"]
        
        // Enter thread mode
        viewModel.enterThreadMode()
        
        #expect(viewModel.isThreadMode == true)
        #expect(viewModel.threadEntries[0].text == "First post")
        #expect(viewModel.threadEntries[0].hashtags == ["test"])
        
        // Change text in thread mode
        viewModel.postText = "Modified first post"
        viewModel.updateCurrentThreadEntry()
        
        #expect(viewModel.threadEntries[0].text == "Modified first post")
        
        // Exit thread mode
        viewModel.exitThreadMode()
        
        #expect(viewModel.isThreadMode == false)
        #expect(viewModel.postText == "Modified first post")
        #expect(viewModel.outlineTags == ["test"])
    }
}

@Test("PostComposer Draft Management")
func testDraftManagement() async throws {
    let appState = AppState()
    let viewModel = PostComposerViewModel(appState: appState)
    
    await MainActor.run {
        // Set up some content
        viewModel.postText = "Draft content"
        viewModel.selectedLanguages = [LanguageCodeContainer(languageCode: "en")]
        viewModel.outlineTags = ["draft"]
        
        // Save draft state
        let draft = viewModel.saveDraftState()
        
        #expect(draft.postText == "Draft content")
        #expect(draft.selectedLanguages.count == 1)
        #expect(draft.outlineTags == ["draft"])
        
        // Clear the view model
        viewModel.resetPost()
        #expect(viewModel.postText.isEmpty)
        #expect(viewModel.selectedLanguages.isEmpty)
        
        // Restore draft
        viewModel.restoreDraftState(draft)
        
        #expect(viewModel.postText == "Draft content")
        #expect(viewModel.selectedLanguages.count == 1)
        #expect(viewModel.outlineTags == ["draft"])
    }
}

@Test("PostComposer Text Processing - No Infinite Loops")
func testTextProcessingStability() async throws {
    let appState = AppState()
    let viewModel = PostComposerViewModel(appState: appState)
    
    await MainActor.run {
        let initialText = "Test text with @mention and #hashtag"
        
        // This should not cause infinite loops
        viewModel.postText = initialText
        
        // Simulate rich text editor update
        let attributedText = NSAttributedString(string: initialText + " updated")
        viewModel.updateFromAttributedText(attributedText)
        
        #expect(viewModel.postText == initialText + " updated")
        #expect(viewModel.richAttributedText.string == initialText + " updated")
    }
    
    // Give it a moment to process any async updates
    try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
    
    await MainActor.run {
        // Text should be stable and not changed by background processing
        #expect(viewModel.postText.contains("Test text with @mention and #hashtag updated"))
    }
}

@Test("PostComposer Media State Consistency")
func testMediaStateConsistency() async throws {
    let appState = AppState()
    let viewModel = PostComposerViewModel(appState: appState)
    
    await MainActor.run {
        // Test GIF selection clears other media
        let mockMediaItem = PostComposerViewModel.MediaItem()
        viewModel.mediaItems = [mockMediaItem]
        
        let mockGif = TenorGif(
            id: "test",
            title: "Test GIF",
            content_description: "",
            itemurl: "",
            url: "https://example.com/gif.gif",
            tags: [],
            media_formats: TenorMediaFormats(
                gif: nil, mediumgif: nil, tinygif: nil, nanogif: nil,
                mp4: nil, loopedmp4: nil, tinymp4: nil, nanomp4: nil,
                webm: nil, tinywebm: nil, nanowebm: nil, webp: nil,
                gifpreview: nil, tinygifpreview: nil, nanogifpreview: nil
            ),
            created: 0,
            flags: [],
            hasaudio: false,
            content_description_source: ""
        )
        
        viewModel.selectGif(mockGif)
        
        #expect(viewModel.selectedGif != nil)
        #expect(viewModel.mediaItems.isEmpty)
        #expect(viewModel.videoItem == nil)
    }
}

@Test("PostComposer Thread Entry Management")
func testThreadEntryManagement() async throws {
    let appState = AppState()
    let viewModel = PostComposerViewModel(appState: appState)
    
    await MainActor.run {
        viewModel.enterThreadMode()
        
        // Add content to first entry
        viewModel.postText = "First thread post"
        viewModel.updateCurrentThreadEntry()
        
        // Add new thread entry
        viewModel.addNewThreadEntry()
        
        #expect(viewModel.threadEntries.count == 2)
        #expect(viewModel.currentThreadIndex == 1)
        #expect(viewModel.threadEntries[0].text == "First thread post")
        
        // Add content to second entry
        viewModel.postText = "Second thread post"
        viewModel.updateCurrentThreadEntry()
        
        // Switch back to first entry
        viewModel.currentThreadIndex = 0
        viewModel.loadEntryState()
        
        #expect(viewModel.postText == "First thread post")
        
        // Switch to second entry
        viewModel.currentThreadIndex = 1
        viewModel.loadEntryState()
        
        #expect(viewModel.postText == "Second thread post")
    }
}

@Test("UIKit composer submit validation matches shared validation")
func testUIKitComposerSubmitValidationMatchesSharedValidation() async throws {
    let appState = AppState()
    let view = PostComposerViewUIKit(appState: appState)
    let viewModel = PostComposerViewModel(appState: appState)

    await MainActor.run {
        viewModel.postText = String(repeating: "a", count: 301)
        #expect(viewModel.isPostButtonDisabled)
        #expect(view.canSubmit(vm: viewModel) == false)

        viewModel.postText = "Video still preparing"
        var videoItem = PostComposerViewModel.MediaItem()
        videoItem.isLoading = true
        viewModel.videoItem = videoItem
        #expect(viewModel.isPostButtonDisabled)
        #expect(view.canSubmit(vm: viewModel) == false)

        viewModel.videoItem = nil
        viewModel.videoUploadBlockedReason = "Email confirmation required"
        #expect(viewModel.isPostButtonDisabled)
        #expect(view.canSubmit(vm: viewModel) == false)

        viewModel.videoUploadBlockedReason = nil
        viewModel.postText = "Ready to post"
        #expect(viewModel.isPostButtonDisabled == false)
        #expect(view.canSubmit(vm: viewModel))
    }
}

@Test("PostComposer submit validation exposes blocking reasons")
func testSubmitValidationReasons() async throws {
    let appState = AppState()
    let viewModel = PostComposerViewModel(appState: appState)

    await MainActor.run {
        #expect(viewModel.submitValidationState.reason == .emptyContent)

        viewModel.postText = String(repeating: "a", count: 301)
        #expect(viewModel.submitValidationState.reason == .overCharacterLimit(current: 301, max: 300))
        #expect(viewModel.submitValidationState.shouldShowInlineMessage)

        viewModel.postText = "Preparing video"
        var videoItem = PostComposerViewModel.MediaItem()
        videoItem.isLoading = true
        viewModel.videoItem = videoItem
        #expect(viewModel.submitValidationState.reason == .videoPreparing)

        viewModel.videoItem = nil
        viewModel.videoUploadBlockedReason = "Email confirmation required"
        #expect(viewModel.submitValidationState.reason == .videoBlocked("Email confirmation required"))

        viewModel.videoUploadBlockedReason = nil
        viewModel.postText = ""
        var imageItem = PostComposerViewModel.MediaItem()
        imageItem.isLoading = false
        viewModel.mediaItems = [imageItem]
        #expect(viewModel.submitValidationState.canSubmit)
    }
}

@Test("PostComposer media removal uses stable item identifiers")
func testMediaRemovalUsesStableIdentifiers() async throws {
    let appState = AppState()
    let viewModel = PostComposerViewModel(appState: appState)

    await MainActor.run {
        var first = PostComposerViewModel.MediaItem()
        first.isLoading = false
        var second = PostComposerViewModel.MediaItem()
        second.isLoading = false

        viewModel.mediaItems = [first, second]
        viewModel.removeMediaItem(withId: first.id)

        #expect(viewModel.mediaItems.map(\.id) == [second.id])

        viewModel.enterThreadMode()
        viewModel.mediaItems = [second]
        viewModel.selectedGif = nil
        viewModel.updateCurrentThreadEntry()
        viewModel.removeMediaItem(withId: second.id)

        #expect(viewModel.mediaItems.isEmpty)
        #expect(viewModel.threadEntries[viewModel.currentThreadIndex].mediaItems.isEmpty)
    }
}
