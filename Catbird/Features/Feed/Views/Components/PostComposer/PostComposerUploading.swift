import AVFoundation
import Foundation
import os
import Petrel
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Upload and Image Processing Extension

extension PostComposerViewModel {
    
    // MARK: - Image Processing and Uploading
    
    /// Uploads `items`, or the active post's photos when nil. Thread entries pass their own
    /// items so the visible attachments are never swapped out during submit.
    func createImagesEmbed(items: [MediaItem]? = nil) async throws -> AppBskyFeedPost.AppBskyFeedPostEmbedUnion? {
        let items = items ?? mediaItems
        guard !items.isEmpty, let client = appState.atProtoClient else { 
            logger.trace("PostComposerUploading: createImagesEmbed - no media items or client")
            return nil 
        }

        if case .circle = destination {
            try await appState.circleService.requireImages()
        }

        logger.info("PostComposerUploading: Creating images embed with \(items.count) items")
        var sources: [Data] = []
        for item in items {
            guard let rawData = item.rawData, item.image != nil, !item.isGifConversion else {
                throw NSError(domain: "ComposerMedia", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "An attachment couldn’t be loaded. Retry it or remove it before posting."
                ]) 
            }
            sources.append(rawData)
        }

        // Decode and encode off the main actor, preparing the next photo while this one uploads.
        var imageEmbeds: [AppBskyEmbedImages.Image] = []
        var nextPreparation: Task<ComposerImagePreparation.PreparedUpload, Error>? = Self.startImagePreparation(sources[0])
        defer { nextPreparation?.cancel() }
        for (index, item) in items.enumerated() {
            guard let preparation = nextPreparation else { break }
            let prepared = try await preparation.value
            nextPreparation = index + 1 < sources.count ? Self.startImagePreparation(sources[index + 1]) : nil
            logger.debug("PostComposerUploading: Image \(index + 1)/\(items.count) prepared - \(sources[index].count) -> \(prepared.data.count) bytes")

            let blob: Blob
            #if DEBUG
            if let transport = appState.e2eCircleTransport {
                blob = try await transport.uploadImage(prepared.data)
            } else {
                let (responseCode, blobOutput) = try await client.com.atproto.repo.uploadBlob(
                    data: prepared.data,
                    mimeType: "image/jpeg",
                    stripMetadata: true
                )
                guard responseCode == 200, let uploadedBlob = blobOutput?.blob else {
                    logger.error("PostComposerUploading: Blob upload failed - response code: \(responseCode)")
                    throw PostComposerUploadError.badResponse(responseCode)
                }
                blob = uploadedBlob
            }
            #else
            let (responseCode, blobOutput) = try await client.com.atproto.repo.uploadBlob(
                data: prepared.data,
                mimeType: "image/jpeg",
                stripMetadata: true
            )
            guard responseCode == 200, let uploadedBlob = blobOutput?.blob else {
                logger.error("PostComposerUploading: Blob upload failed - response code: \(responseCode)")
                throw PostComposerUploadError.badResponse(responseCode)
            }
            blob = uploadedBlob
            #endif
            
            logger.info("PostComposerUploading: Image \(index + 1) uploaded successfully")

            // The uploaded pixel size is exact; the attachment's size is a fallback.
            let aspectRatio: AppBskyEmbedDefs.AspectRatio?
            if prepared.pixelSize.width > 0, prepared.pixelSize.height > 0 {
                aspectRatio = AppBskyEmbedDefs.AspectRatio(
                    width: Int(prepared.pixelSize.width),
                    height: Int(prepared.pixelSize.height)
                )
            } else if let ratio = item.aspectRatio, ratio.width > 0, ratio.height > 0 {
                aspectRatio = AppBskyEmbedDefs.AspectRatio(
                    width: Int(ratio.width),
                    height: Int(ratio.height)
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
        guard destination == .public else {
            throw CircleError.invalidParameter("Video and audio are unavailable in Circles.")
        }
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
    
    private static func startImagePreparation(
        _ data: Data
    ) -> Task<ComposerImagePreparation.PreparedUpload, Error> {
        Task.detached(priority: .userInitiated) {
            try ComposerImagePreparation.prepareForUploadSynchronously(data)
        }
    }
}
