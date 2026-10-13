import AVFoundation
import Foundation
import ImageIO
import os
import OSLog
import Petrel
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Upload and Image Processing Extension

extension PostComposerViewModel {
    
    // MARK: - Image Processing and Uploading
    
    func createImagesEmbed(items: [MediaItem]? = nil) async throws -> AppBskyFeedPost.AppBskyFeedPostEmbedUnion? {
        let activeItems = items ?? mediaItems
        guard !activeItems.isEmpty, let client = appState.atProtoClient else { 
            logger.trace("PostComposerUploading: createImagesEmbed - no media items or client")
            return nil 
        }

        logger.info("PostComposerUploading: Creating images embed with \(activeItems.count) items")
        var imageEmbeds: [AppBskyEmbedImages.Image] = []

        for (index, item) in activeItems.enumerated() {
            guard let rawData = item.rawData, item.image != nil, !item.isGifConversion else {
                throw NSError(domain: "ComposerMedia", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "An attachment couldn’t be loaded. Retry it or remove it before posting."
                ]) 
            }

            logger.debug("PostComposerUploading: Processing image \(index + 1)/\(activeItems.count) - size: \(rawData.count) bytes")
            let (imageData, pixelSize) = try await ComposerImageProcessor.prepareImageForUpload(rawData)
            logger.debug("PostComposerUploading: Image processed - final size: \(imageData.count) bytes")
            let (responseCode, blobOutput) = try await client.com.atproto.repo.uploadBlob(
                data: imageData,
                mimeType: "image/jpeg",
                stripMetadata: true
            )
            guard responseCode == 200, let uploadedBlob = blobOutput?.blob else {
                logger.error("PostComposerUploading: Blob upload failed - response code: \(responseCode)")
                throw PostComposerUploadError.badResponse(responseCode)
            }
            let blob = uploadedBlob
            
            logger.info("PostComposerUploading: Image \(index + 1) uploaded successfully")

            // Only include aspect ratio if we have valid dimensions (non-zero)
            let aspectRatio: AppBskyEmbedDefs.AspectRatio?
            if let ratio = item.aspectRatio, ratio.width > 0, ratio.height > 0 {
                aspectRatio = AppBskyEmbedDefs.AspectRatio(
                    width: Int(ratio.width),
                    height: Int(ratio.height)
                )
            } else if pixelSize.width > 0 && pixelSize.height > 0 {
                aspectRatio = AppBskyEmbedDefs.AspectRatio(
                    width: Int(pixelSize.width),
                    height: Int(pixelSize.height)
                )
            } else {
                aspectRatio = nil
            }

            let altText = item.altText
            let imageEmbed = AppBskyEmbedImages.Image(
                image: blob,
                alt: altText,
                aspectRatio: aspectRatio
            )

            imageEmbeds.append(imageEmbed)
        }

        // More than legacyImagesEmbedMax images promotes to app.bsky.embed.gallery
        // (matching the official client); otherwise keep the legacy images embed
        // so older clients can still render the post.
        if imageEmbeds.count > legacyImagesEmbedMax {
            logger.info("PostComposerUploading: \(imageEmbeds.count) images — promoting to gallery embed")
            let galleryItems = imageEmbeds.map { image in
                AppBskyEmbedGallery.AppBskyEmbedGalleryItemsUnion.appBskyEmbedGalleryImage(
                    AppBskyEmbedGallery.Image(
                        image: image.image,
                        alt: image.alt,
                        // Gallery items require an aspect ratio; default to square
                        // when dimensions were unavailable (matches official client)
                        aspectRatio: image.aspectRatio
                            ?? AppBskyEmbedDefs.AspectRatio(width: 1, height: 1)
                    )
                )
            }
            return .appBskyEmbedGallery(AppBskyEmbedGallery(items: galleryItems))
        }

        return .appBskyEmbedImages(AppBskyEmbedImages(images: imageEmbeds))
    }

    func createVideoEmbed(
        for suppliedItem: MediaItem? = nil, entryID: UUID? = nil
    ) async throws -> AppBskyFeedPost.AppBskyFeedPostEmbedUnion? {
        guard let videoItem = suppliedItem ?? videoItem else { return nil }
        guard let mediaUploadManager = mediaUploadManager, let client = appState.atProtoClient else {
            throw VideoUploadError.noClientAvailable
        }

        let context = mediaLoadContext()
        guard let accountDID = context.accountDID else { throw VideoUploadError.noClientAvailable }
        let videoID = videoItem.id
        let originalURL = videoItem.rawVideoURL
        let originalData = videoItem.videoData
        guard let owner = videoUploadOwner(for: videoID, entryID: entryID) else {
            throw VideoUploadError.noClientAvailable
        }
        let initiatingAppState = appState
        let isAccountCurrent: @MainActor @Sendable () -> Bool = { [weak initiatingAppState] in
            guard let initiatingAppState else { return false }
            return initiatingAppState.userDID == accountDID && initiatingAppState.atProtoClient === client
        }
        let isCurrent: @MainActor @Sendable () -> Bool = { [weak self, weak mediaUploadManager] in
            guard let self, let mediaUploadManager,
                  self.ownsMediaLoad(context), self.appState.atProtoClient === client,
                  self.mediaUploadManager === mediaUploadManager else { return false }
            let currentItem: MediaItem?
            if let entryID {
                currentItem = self.threadEntries.first(where: { $0.id == entryID })?.videoItem
            } else {
                currentItem = self.videoItem
            }
            return currentItem?.id == videoID && currentItem?.rawVideoURL == originalURL
                && currentItem?.videoData == originalData
        }
        guard isCurrent() else { throw CancellationError() }

        isVideoUploading = true
        defer { if isCurrent() { isVideoUploading = false } }
        logger.debug("DEBUG: Creating video embed, starting upload process")

        do {
            var uploadedCaptions: [AppBskyEmbedVideo.Caption]? = nil
            if let caption = videoItem.caption {
                logger.info("PostComposerUploading: Uploading video caption (.vtt) for language \(caption.lang.lang.minimalIdentifier)")
                let uploadedCaption = try await mediaUploadManager.uploadCaptionBlob(caption)
                guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
                uploadedCaptions = [uploadedCaption]
                logger.info("PostComposerUploading: Video caption uploaded successfully")
            }

            let blob: Blob

            if let videoURL = videoItem.rawVideoURL {
                logger.debug("DEBUG: Using URL for video upload: \(videoURL)")
                blob = try await mediaUploadManager.uploadVideo(
                    url: videoURL, alt: videoItem.altText, owner: owner,
                    isOwnerCurrent: isCurrent, isAccountCurrent: isAccountCurrent
                )
            } else if let videoAsset = videoItem.rawVideoAsset {
                logger.debug("DEBUG: Using AVAsset for video upload")

                let tempDir = FileManager.default.temporaryDirectory
                let tempFileName = "export_video_\(UUID().uuidString).mp4"
                let tempFileURL = tempDir.appendingPathComponent(tempFileName)

                logger.debug("DEBUG: Exporting asset to temporary file: \(tempFileURL.path)")
                let _ = try await exportAsset(videoAsset, to: tempFileURL)
                guard isCurrent(), !Task.isCancelled else { throw CancellationError() }

                logger.debug("DEBUG: Asset export successful, uploading from: \(tempFileURL.path)")
                blob = try await mediaUploadManager.uploadVideo(
                    url: tempFileURL, alt: videoItem.altText, owner: owner,
                    isOwnerCurrent: isCurrent, isAccountCurrent: isAccountCurrent
                )
            } else if let videoData = videoItem.videoData {
                logger.debug("DEBUG: Using Data for video upload, size: \(videoData.count) bytes")

                let tempDir = FileManager.default.temporaryDirectory
                let tempFileName = "data_video_\(UUID().uuidString).mp4"
                let tempFileURL = tempDir.appendingPathComponent(tempFileName)

                logger.debug("DEBUG: Writing video data to temporary file: \(tempFileURL.path)")
                try videoData.write(to: tempFileURL)

                logger.debug("DEBUG: Uploading from temporary file: \(tempFileURL.path)")
                blob = try await mediaUploadManager.uploadVideo(
                    url: tempFileURL, alt: videoItem.altText, owner: owner,
                    isOwnerCurrent: isCurrent, isAccountCurrent: isAccountCurrent
                )
            } else {
                logger.error("ERROR: No video source available for upload")
                throw VideoUploadError.uploadFailed
            }

            guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
            logger.debug("DEBUG: Video upload successful, creating embed")
            let embed = mediaUploadManager.createVideoEmbed(
                aspectRatio: videoItem.aspectRatio,
                alt: videoItem.altText.isEmpty ? "Video" : videoItem.altText,
                presentation: videoItem.isGifConversion ? "gif" : nil,
                captions: uploadedCaptions
            )

            return embed
        } catch {
            logger.error("ERROR: Video upload failed: \(error)")
            // Rethrow unchanged so the composer can explain the failure to the user.
            throw error
        }
    }

    func videoUploadOwner(for videoID: UUID, entryID: UUID? = nil) -> VideoUploadOwner? {
        let context = mediaLoadContext()
        guard let accountDID = context.accountDID else { return nil }
        // The containing entry survives saving, reordering and account restoration. A saved-row
        // identifier or the first thread entry would change the key for the same attachment.
        let entryNamespace = (entryID ?? context.entryID)?.uuidString ?? videoID.uuidString
        return VideoUploadOwner(
            accountDID: accountDID,
            draftID: entryNamespace,
            entryID: entryNamespace,
            mediaID: videoID.uuidString
        )
    }

    private func exportAsset(_ asset: AVAsset, to outputURL: URL) async throws -> AVAssetExportSession {
        logger.debug("DEBUG: Creating export session")
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            logger.error("ERROR: Could not create export session")
            throw NSError(
                domain: "VideoExportError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create export session for video"]
            )
        }

        logger.debug("DEBUG: Starting export operation")
        let preparation = MediaPreviewLoadAttempt(timeout: .seconds(120))
        defer { preparation.cancel() }
        do {
            try await preparation.value {
                try await exportSession.export(to: outputURL, as: .mp4)
            }
            logger.debug("DEBUG: Export completed successfully")
        } catch {
            logger.debug("DEBUG: Export failed with error: \(error)")
            throw error
        }

        return exportSession
    }
    
    private func processImageForUpload(_ data: Data) async throws -> Data {
        let (processed, _) = try await ComposerImageProcessor.prepareImageForUpload(data)
        return processed
    }
}

// MARK: - Off-Main ImageIO Processor

enum ComposerImageProcessor {
    /// Prepares an image for upload: downsamples to max 2000px, strips metadata, and compresses to fit under blob size limit (976_560 bytes).
    /// Runs off the main actor using ImageIO and logs the "ComposerImageProcess" signpost interval.
    nonisolated static func prepareImageForUpload(
        _ data: Data,
        maxPixelSize: Int = 2000,
        maxBytes: Int = 976_560
    ) async throws -> (data: Data, pixelSize: CGSize) {
        let signpostState = PerformanceSignposts.beginInterval("ComposerImageProcess")
        defer { PerformanceSignposts.endInterval("ComposerImageProcess", signpostState) }
        
        return try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                throw NSError(domain: "ComposerImageProcessor", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create image source"
                ])
            }
            
            var pixelSize: CGSize = .zero
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                let width = (properties[kCGImagePropertyPixelWidth] as? CGFloat) ?? 0
                let height = (properties[kCGImagePropertyPixelHeight] as? CGFloat) ?? 0
                let orientation = (properties[kCGImagePropertyOrientation] as? UInt32) ?? 1
                if orientation >= 5 && orientation <= 8 {
                    pixelSize = CGSize(width: height, height: width)
                } else {
                    pixelSize = CGSize(width: width, height: height)
                }
            }
            
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true
            ]
            
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw NSError(domain: "ComposerImageProcessor", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to decode thumbnail image"
                ])
            }
            
            let finalWidth = CGFloat(cgImage.width)
            let finalHeight = CGFloat(cgImage.height)
            if pixelSize == .zero || pixelSize.width == 0 || pixelSize.height == 0 {
                pixelSize = CGSize(width: finalWidth, height: finalHeight)
            } else {
                let scale = min(CGFloat(maxPixelSize) / max(pixelSize.width, pixelSize.height), 1.0)
                pixelSize = CGSize(width: round(pixelSize.width * scale), height: round(pixelSize.height * scale))
            }
            
            // Encode using CGImageDestination, stripping metadata
            var lowQuality: CGFloat = 0.3
            var highQuality: CGFloat = 0.90
            var bestData: Data?
            
            let initialQuality: CGFloat = 0.85
            if let encoded = encodeJPEG(cgImage: cgImage, quality: initialQuality) {
                if encoded.count <= maxBytes {
                    return (encoded, pixelSize)
                }
                bestData = encoded
                highQuality = initialQuality
            }
            
            // Binary search (up to 4 steps) to find quality that fits under maxBytes
            for _ in 0..<4 {
                let midQuality = (lowQuality + highQuality) / 2.0
                guard let encoded = encodeJPEG(cgImage: cgImage, quality: midQuality) else { break }
                if encoded.count <= maxBytes {
                    bestData = encoded
                    lowQuality = midQuality
                } else {
                    highQuality = midQuality
                }
            }
            
            if let bestData, bestData.count <= maxBytes {
                return (bestData, pixelSize)
            }
            
            if let encoded = encodeJPEG(cgImage: cgImage, quality: lowQuality) {
                return (encoded, pixelSize)
            }
            
            throw NSError(domain: "ComposerImageProcessor", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode image under size limit"
            ])
        }.value
    }
    
    private nonisolated static func encodeJPEG(cgImage: CGImage, quality: CGFloat) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return mutableData as Data
    }
    
    /// Creates a downsampled preview thumbnail (~300-360 px max) off main actor
    nonisolated static func makePreview(from data: Data, maxPixel: CGFloat = 360) async -> (CGImage, CGSize)? {
        await Task.detached(priority: .userInitiated) {
            syncPreview(from: data, maxPixel: maxPixel)
        }.value
    }
    
    /// Synchronously creates a downsampled preview thumbnail (~300-360 px max) using ImageIO without full-res bitmap decode
    nonisolated static func syncPreview(from data: Data, maxPixel: CGFloat = 360) -> (CGImage, CGSize)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var originalSize = CGSize.zero
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = (properties[kCGImagePropertyPixelWidth] as? CGFloat) ?? 0
            let height = (properties[kCGImagePropertyPixelHeight] as? CGFloat) ?? 0
            let orientation = (properties[kCGImagePropertyOrientation] as? UInt32) ?? 1
            if orientation >= 5 && orientation <= 8 {
                originalSize = CGSize(width: height, height: width)
            } else {
                originalSize = CGSize(width: width, height: height)
            }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        if originalSize == .zero {
            originalSize = CGSize(width: thumbnail.width, height: thumbnail.height)
        }
        return (thumbnail, originalSize)
    }
}
