import Testing
import SwiftUI
import Petrel
import PetrelCatbird
@testable import Catbird
/// Integration tests demonstrating the PostComposer fixes work in real-world scenarios
@Suite("PostComposer Integration Tests")
struct PostComposerIntegrationTests {
    
    @Test("Complete Post Creation Flow")
    func testCompletePostCreationFlow() async throws {
        let appState = AppState()
        let viewModel = PostComposerViewModel(appState: appState)
        
        await MainActor.run {
            // Simulate user typing
            viewModel.postText = "Hello Bluesky! #test"
            
            // Verify state is consistent
            #expect(viewModel.postText == "Hello Bluesky! #test")
            #expect(viewModel.canSubmitPost == true)
            #expect(viewModel.isPostButtonDisabled == false)
            
            // Test character count
            #expect(viewModel.characterCount == 19)
            #expect(viewModel.remainingCharacters == 281) // 300 - 19
        }
    }
    
    @Test("Thread Creation Workflow")
    func testThreadCreationWorkflow() async throws {
        let appState = AppState()
        let viewModel = PostComposerViewModel(appState: appState)
        
        await MainActor.run {
            // Start with single post
            viewModel.postText = "This is the first post in a thread"
            
            // Switch to thread mode
            viewModel.enterThreadMode()
            #expect(viewModel.isThreadMode == true)
            #expect(viewModel.threadEntries.count == 1)
            #expect(viewModel.threadEntries[0].text == "This is the first post in a thread")
            
            // Add second post
            viewModel.addNewThreadEntry()
            #expect(viewModel.threadEntries.count == 2)
            #expect(viewModel.currentThreadIndex == 1)
            
            viewModel.postText = "This is the second post"
            viewModel.updateCurrentThreadEntry()
            
            // Verify both posts are preserved
            #expect(viewModel.threadEntries[0].text == "This is the first post in a thread")
            #expect(viewModel.threadEntries[1].text == "This is the second post")
            
            // Switch back to first post
            viewModel.currentThreadIndex = 0
            viewModel.loadEntryState()
            #expect(viewModel.postText == "This is the first post in a thread")
            
            // Exit thread mode
            viewModel.exitThreadMode()
            #expect(viewModel.isThreadMode == false)
            #expect(viewModel.postText == "This is the first post in a thread")
        }
    }
    
    @Test("Draft Persistence Simulation")
    func testDraftPersistence() async throws {
        let appState = AppState()
        let viewModel = PostComposerViewModel(appState: appState)
        
        await MainActor.run {
            // User starts composing
            viewModel.postText = "I'm writing a draft post with some #hashtags"
            viewModel.selectedLanguages = [LanguageCodeContainer(languageCode: "en")]
            
            // Simulate app going to background - save draft
            viewModel.enterDraftMode()
            let draft = viewModel.saveDraftState()
            
            // Simulate app restart - restore draft
            let newViewModel = PostComposerViewModel(appState: appState)
            newViewModel.restoreDraftState(draft)
            
            // Verify draft was restored correctly
            #expect(newViewModel.postText == "I'm writing a draft post with some #hashtags")
            #expect(newViewModel.selectedLanguages.count == 1)
            #expect(newViewModel.selectedLanguages.first?.lang.languageCode?.identifier == "en")
        }
    }
    
    @Test("Media State Management")
    func testMediaStateManagement() async throws {
        let appState = AppState()
        let viewModel = PostComposerViewModel(appState: appState)
        
        await MainActor.run {
            // Test media clearing when selecting GIF
            let mockMediaItem = PostComposerViewModel.MediaItem()
            viewModel.mediaItems = [mockMediaItem]
            
            let mockGif = TenorGif(
                id: "test123",
                title: "Awesome GIF",
                content_description: "A test GIF",
                itemurl: "https://tenor.com/test",
                url: "https://media.tenor.com/test.gif",
                tags: ["test"],
                media_formats: TenorMediaFormats(
                    gif: TenorMediaItem(url: "https://media.tenor.com/test.gif", dims: [200, 200], duration: 1.0, preview: "", size: 1000),
                    mediumgif: nil, tinygif: nil, nanogif: nil,
                    mp4: nil, loopedmp4: nil, tinymp4: nil, nanomp4: nil,
                    webm: nil, tinywebm: nil, nanowebm: nil, webp: nil,
                    gifpreview: nil, tinygifpreview: nil, nanogifpreview: nil
                ),
                created: Date().timeIntervalSince1970,
                flags: [],
                hasaudio: false,
                content_description_source: "generated"
            )
            
            viewModel.selectGif(mockGif)
            
            // Verify other media was cleared
            #expect(viewModel.selectedGif?.id == "test123")
            #expect(viewModel.mediaItems.isEmpty)
            #expect(viewModel.videoItem == nil)
        }
    }
    
    @Test("Text Processing Stability")
    func testTextProcessingStability() async throws {
        let appState = AppState()
        let viewModel = PostComposerViewModel(appState: appState)
        
        await MainActor.run {
            // Test rapid text updates don't cause issues
            for i in 1...10 {
                viewModel.postText = "Update number \(i) with @mention and #tag"
                
                // Simulate rich text editor updates
                let attributed = NSAttributedString(string: viewModel.postText)
                viewModel.updateFromAttributedText(attributed)
            }
            
            // Final state should be consistent
            #expect(viewModel.postText == "Update number 10 with @mention and #tag")
            #expect(viewModel.richAttributedText.string == viewModel.postText)
        }
        
        // Allow any async operations to complete
        try await Task.sleep(nanoseconds: 10_000_000) // 0.01 seconds
        
        await MainActor.run {
            // State should still be stable
            #expect(viewModel.postText.contains("Update number 10"))
        }
    }

    @Test("Circle Post Creation Flow with Destination Lock")
    func testCirclePostCreationFlowWithDestinationLock() async throws {
        let family = CircleTestFixtures.family
        let transport = DestinationRecordingCircleTransport()
        let service = CircleService(transport: transport)
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let appState = AppState(userDID: "did:plc:testuser", client: client)

        let viewModel = await MainActor.run {
            PostComposerViewModel(
                destination: .circle(family),
                appState: appState,
                circleService: service
            )
        }

        await MainActor.run {
            viewModel.postText = "Hello Circle Space!"
            #expect(viewModel.canSubmitPost == true)
            #expect(viewModel.destination == .circle(family))
            #expect(viewModel.canChangeDestination == true)
        }

        let submission = try await MainActor.run {
            try viewModel.beginSubmission()
        }

        await MainActor.run {
            #expect(submission.destination == .circle(family))
            viewModel.selectDestination(.public)
            #expect(viewModel.destination == .circle(family))
            #expect(viewModel.canChangeDestination == false)
        }

        try await viewModel.createPost()

        let published = await transport.publishedPosts
        #expect(published.count == 1)
        #expect(published.first?.destination == family)
        #expect(published.first?.draft.text == "Hello Circle Space!")

        let publicCalls = await transport.publicEndpointCallCount
        #expect(publicCalls == 0)
    }

    @Test("Circle Reply Integration Carries ReplyRef")
    func testCircleReplyIntegrationCarriesReplyRef() async throws {
        let family = CircleTestFixtures.family
        let transport = DestinationRecordingCircleTransport()
        let service = CircleService(transport: transport)
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let appState = AppState(userDID: "did:plc:testuser", client: client)

        let parentURI = try ATProtocolURI(uriString: "\(CircleTestFixtures.familyURI.uriString())/app.bsky.feed.post/parent999")
        let parentCID = CID.fromDAGCBOR(Data("parent-cid-999".utf8))
        let parentRecord = AppBskyFeedPost(
            text: "Parent in Space",
            entities: nil,
            facets: nil,
            reply: nil,
            embed: nil,
            langs: [],
            labels: nil,
            tags: nil,
            createdAt: ATProtocolDate(date: Date())
        )
        let parentPost = AppBskyFeedDefs.PostView(
            uri: parentURI,
            cid: parentCID,
            author: AppBskyActorDefs.ProfileViewBasic(
                did: try DID(didString: "did:plc:author1"),
                handle: try Handle(handleString: "author1.bsky.social"),
                displayName: nil,
                pronouns: nil,
                avatar: nil,
                associated: nil,
                viewer: nil,
                labels: nil,
                createdAt: nil,
                verification: nil,
                status: nil,
                debug: nil
            ),
            record: ATProtocolValueContainer.knownType(parentRecord),
            embed: nil,
            bookmarkCount: nil,
            replyCount: 0,
            repostCount: 0,
            likeCount: 0,
            quoteCount: 0,
            indexedAt: ATProtocolDate(date: Date()),
            viewer: nil,
            labels: nil,
            threadgate: nil,
            debug: nil
        )

        let viewModel = await MainActor.run {
            PostComposerViewModel(
                parentPost: parentPost,
                destination: .circle(family),
                appState: appState,
                circleService: service
            )
        }

        await MainActor.run {
            #expect(viewModel.isReplyLockedToCircle == true)
            #expect(viewModel.canChangeDestination == false)
            viewModel.postText = "Replying inside circle"
        }

        try await viewModel.createPost()

        let published = await transport.publishedPosts
        #expect(published.count == 1)
        guard let draft = published.first?.draft else {
            Issue.record("Missing draft")
            return
        }
        #expect(draft.reply != nil)
        #expect(draft.reply?.parent.uri == parentURI)
        #expect(draft.reply?.parent.cid == parentCID)
        #expect(draft.reply?.root.uri == parentURI)
        #expect(draft.reply?.root.cid == parentCID)
    }

    @Test("Circle Destination Blocks Thread Mode Integration")
    func testCircleDestinationBlocksThreadModeIntegration() async throws {
        let family = CircleTestFixtures.family
        let appState = AppState()

        let viewModel = await MainActor.run {
            PostComposerViewModel(
                destination: .circle(family),
                appState: appState
            )
        }

        await MainActor.run {
            viewModel.enterThreadMode()
            #expect(viewModel.isThreadMode == false)
        }

        let publicViewModel = await MainActor.run {
            PostComposerViewModel(
                destination: .public,
                appState: appState
            )
        }

        await MainActor.run {
            publicViewModel.enterThreadMode()
            #expect(publicViewModel.isThreadMode == true)

            publicViewModel.selectDestination(.circle(family))
            #expect(publicViewModel.isThreadMode == false)
            #expect(publicViewModel.destination == .circle(family))
        }
    }
}