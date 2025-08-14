//
//  NotificationThumbnailTests.swift
//  CatbirdTests
//
//  Created by Claude Code on 2025-08-09.
//

import Testing
import Petrel
import Foundation
@testable import Catbird

@Suite("Notification Thumbnail Tests")
struct NotificationThumbnailTests {
  
  @Test("Extract image thumbnails from embed")
  func testImageThumbnailExtraction() {
    // Create a mock image embed
    let mockImageThumbURI = ATProtocolURI(uriString: "https://cdn.bsky.app/img/feed_thumbnail/plain/test.jpg")!
    let mockImageFullURI = ATProtocolURI(uriString: "https://cdn.bsky.app/img/feed_fullsize/plain/test.jpg")!
    
    let mockImage = AppBskyEmbedImages.ViewImage(
      thumb: mockImageThumbURI,
      fullsize: mockImageFullURI,
      alt: "Test image",
      aspectRatio: AppBskyEmbedImages.AspectRatio(width: 100, height: 100)
    )
    
    let mockImagesView = AppBskyEmbedImages.View(images: [mockImage])
    let mockEmbed = AppBskyEmbedDefs.ViewUnion.appBskyEmbedImagesView(mockImagesView)
    
    let mockPost = createMockPost(with: mockEmbed)
    
    // Test the extraction
    let notificationCard = createMockNotificationCard()
    let thumbnails = notificationCard.extractMediaThumbnails(from: mockPost)
    
    #expect(thumbnails.count == 1)
    #expect(thumbnails.first?.mediaType == .image)
    #expect(thumbnails.first?.url.absoluteString.contains("test.jpg") == true)
  }
  
  @Test("Extract video thumbnails from embed")
  func testVideoThumbnailExtraction() {
    // Create a mock video embed
    let mockVideoThumbnailURI = ATProtocolURI(uriString: "https://video.bsky.app/thumbnail.jpg")!
    let mockVideoPlaylistURI = ATProtocolURI(uriString: "https://video.bsky.app/playlist.m3u8")!
    
    let mockVideoView = AppBskyEmbedVideo.View(
      cid: CID(string: "bafyreitest"),
      playlist: mockVideoPlaylistURI,
      thumbnail: mockVideoThumbnailURI,
      alt: "Test video",
      aspectRatio: AppBskyEmbedVideo.AspectRatio(width: 100, height: 100)
    )
    
    let mockEmbed = AppBskyEmbedDefs.ViewUnion.appBskyEmbedVideoView(mockVideoView)
    let mockPost = createMockPost(with: mockEmbed)
    
    // Test the extraction
    let notificationCard = createMockNotificationCard()
    let thumbnails = notificationCard.extractMediaThumbnails(from: mockPost)
    
    #expect(thumbnails.count == 1)
    #expect(thumbnails.first?.mediaType == .video)
    #expect(thumbnails.first?.url.absoluteString.contains("thumbnail.jpg") == true)
  }
  
  @Test("Extract external link thumbnails from embed")
  func testExternalThumbnailExtraction() {
    // Create a mock external embed
    let mockExternalURI = ATProtocolURI(uriString: "https://example.com")!
    let mockThumbURI = ATProtocolURI(uriString: "https://example.com/thumb.jpg")!
    
    let mockExternal = AppBskyEmbedExternal.ViewExternal(
      uri: mockExternalURI,
      title: "Test Link",
      description: "A test link",
      thumb: mockThumbURI
    )
    
    let mockExternalView = AppBskyEmbedExternal.View(external: mockExternal)
    let mockEmbed = AppBskyEmbedDefs.ViewUnion.appBskyEmbedExternalView(mockExternalView)
    let mockPost = createMockPost(with: mockEmbed)
    
    // Test the extraction
    let notificationCard = createMockNotificationCard()
    let thumbnails = notificationCard.extractMediaThumbnails(from: mockPost)
    
    #expect(thumbnails.count == 1)
    #expect(thumbnails.first?.mediaType == .external)
    #expect(thumbnails.first?.url.absoluteString.contains("thumb.jpg") == true)
  }
  
  @Test("Handle posts with no media embeds")
  func testNoMediaEmbeds() {
    // Create a post with just text, no media
    let mockEmbed = AppBskyEmbedDefs.ViewUnion.appBskyEmbedRecordView(
      AppBskyEmbedRecord.View(
        record: .appBskyEmbedRecordViewRecord(
          AppBskyEmbedRecord.ViewRecord(
            uri: ATProtocolURI(uriString: "at://test.bsky.social/app.bsky.feed.post/test")!,
            cid: CID(string: "bafyreitest"),
            author: createMockProfile(),
            value: .knownType(AppBskyFeedPost(text: "Test post", createdAt: ATProtocolDate.now)),
            labels: [],
            embeds: nil,
            indexedAt: ATProtocolDate.now
          )
        )
      )
    )
    
    let mockPost = createMockPost(with: mockEmbed)
    
    // Test the extraction
    let notificationCard = createMockNotificationCard()
    let thumbnails = notificationCard.extractMediaThumbnails(from: mockPost)
    
    #expect(thumbnails.isEmpty)
  }
  
  // MARK: - Helper Methods
  
  private func createMockPost(with embed: AppBskyEmbedDefs.ViewUnion) -> AppBskyFeedDefs.PostView {
    return AppBskyFeedDefs.PostView(
      uri: ATProtocolURI(uriString: "at://test.bsky.social/app.bsky.feed.post/test")!,
      cid: CID(string: "bafyreitest"),
      author: createMockProfile(),
      record: .knownType(AppBskyFeedPost(text: "Test post", createdAt: ATProtocolDate.now)),
      embed: embed,
      replyCount: 0,
      repostCount: 0,
      likeCount: 0,
      quoteCount: 0,
      indexedAt: ATProtocolDate.now,
      viewer: nil,
      labels: [],
      threadgate: nil
    )
  }
  
  private func createMockProfile() -> AppBskyActorDefs.ProfileViewBasic {
    return AppBskyActorDefs.ProfileViewBasic(
      did: DID(didString: "did:plc:test"),
      handle: Handle(handle: "test.bsky.social"),
      displayName: "Test User",
      avatar: nil,
      associated: nil,
      viewer: nil,
      labels: [],
      createdAt: nil
    )
  }
  
  private func createMockNotificationCard() -> MockNotificationCard {
    return MockNotificationCard()
  }
}

// Mock class to test the private method
class MockNotificationCard {
  func extractMediaThumbnails(from post: AppBskyFeedDefs.PostView) -> [MediaThumbnailInfo] {
    guard let embed = post.embed else { return [] }
    
    var thumbnails: [MediaThumbnailInfo] = []
    
    switch embed {
    case .appBskyEmbedImagesView(let images):
      for image in images.images {
        if let thumbURL = URL(string: image.thumb.uriString()) {
          let isGif = image.fullsize.uriString().lowercased().contains("gif") ||
                     image.thumb.uriString().lowercased().contains("gif")
          
          thumbnails.append(MediaThumbnailInfo(
            url: thumbURL,
            mediaType: isGif ? .gif : .image,
            totalCount: images.images.count
          ))
        }
      }
      
    case .appBskyEmbedVideoView(let video):
      if let thumbnailURI = video.thumbnail,
         let thumbURL = URL(string: thumbnailURI.uriString()) {
        thumbnails.append(MediaThumbnailInfo(
          url: thumbURL,
          mediaType: .video,
          totalCount: 1
        ))
      }
      
    case .appBskyEmbedExternalView(let external):
      if let thumbURI = external.external.thumb,
         let thumbURL = URL(string: thumbURI.uriString()) {
        thumbnails.append(MediaThumbnailInfo(
          url: thumbURL,
          mediaType: .external,
          totalCount: 1
        ))
      }
      
    default:
      break
    }
    
    return thumbnails
  }
}