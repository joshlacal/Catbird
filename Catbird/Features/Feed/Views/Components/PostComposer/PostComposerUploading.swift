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
    
    func createImagesEmbed() async throws -> AppBskyFeedPost.AppBskyFeedPostEmbedUnion? {
        guard !mediaItems.isEmpty, let client = appState.atProtoClient else { 
            logger.trace("PostComposerUploading: createImagesEmbed - no media items or client")
            return nil 
        }

        logger.info("PostComposerUploading: Creating images embed with \(self.mediaItems.count) items")
        var imageEmbeds: [AppBskyEmbedImages.Image] = []

        for (index, item) in mediaItems.enumerated() {
            guard let rawData = item.rawData else { 
                logger.warning("PostComposerUploading: Skipping image at index \(index) - no raw data")
                continue 
            }

            logger.debug("PostComposerUploading: Processing image \(index + 1)/\(self.mediaItems.count) - size: \(rawData.count) bytes")
            let imageData = try await processImageForUpload(rawData)
            logger.debug("PostComposerUploading: Image processed - final size: \(imageData.count) bytes")

            let (responseCode, blobOutput) = try await client.com.atproto.repo.uploadBlob(
                data: imageData,
                mimeType: "image/jpeg",
                stripMetadata: true
            )

            guard responseCode == 200, let blob = blobOutput?.blob else {
                logger.error("PostComposerUploading: Blob upload failed - response code: \(responseCode)")
                throw NSError(domain: "BlobUploadError", code: responseCode, userInfo: nil)
            }
            
            logger.info("PostComposerUploading: Image \(index + 1) uploaded successfully")

            let aspectRatio = AppBskyEmbedDefs.AspectRatio(
                width: Int(item.aspectRatio?.width ?? 0),
                height: Int(item.aspectRatio?.height ?? 0)
            )

            let altText = item.altText
            let imageEmbed = AppBskyEmbedImages.Image(
                image: blob,
                alt: altText,
                aspectRatio: aspectRatio
            )

            imageEmbeds.append(imageEmbed)
        }

        return .appBskyEmbedImages(AppBskyEmbedImages(images: imageEmbeds))
    }

    func createVideoEmbed() async throws -> AppBskyFeedPost.AppBskyFeedPostEmbedUnion? {
        guard let videoItem = videoItem, let mediaUploadManager = mediaUploadManager else {
            logger.debug("DEBUG: Missing videoItem or mediaUploadManager")
            return nil
        }

        isVideoUploading = true
        logger.debug("DEBUG: Creating video embed, starting upload process")

        do {
            let blob: Blob

            if let videoURL = videoItem.rawVideoURL {
                logger.debug("DEBUG: Using URL for video upload: \(videoURL)")
                blob = try await mediaUploadManager.uploadVideo(url: videoURL, alt: videoItem.altText)
            } else if let videoAsset = videoItem.rawVideoAsset {
                logger.debug("DEBUG: Using AVAsset for video upload")

                let tempDir = FileManager.default.temporaryDirectory
                let tempFileName = "export_video_\(UUID().uuidString).mp4"
                let tempFileURL = tempDir.appendingPathComponent(tempFileName)

                logger.debug("DEBUG: Exporting asset to temporary file: \(tempFileURL.path)")
                let _ = try await exportAsset(videoAsset, to: tempFileURL)

                logger.debug("DEBUG: Asset export successful, uploading from: \(tempFileURL.path)")
                blob = try await mediaUploadManager.uploadVideo(url: tempFileURL, alt: videoItem.altText)
            } else if let videoData = videoItem.videoData {
                logger.debug("DEBUG: Using Data for video upload, size: \(videoData.count) bytes")

                let tempDir = FileManager.default.temporaryDirectory
                let tempFileName = "data_video_\(UUID().uuidString).mp4"
                let tempFileURL = tempDir.appendingPathComponent(tempFileName)

                logger.debug("DEBUG: Writing video data to temporary file: \(tempFileURL.path)")
                try videoData.write(to: tempFileURL)

                logger.debug("DEBUG: Uploading from temporary file: \(tempFileURL.path)")
                blob = try await mediaUploadManager.uploadVideo(url: tempFileURL, alt: videoItem.altText)
            } else {
                logger.error("ERROR: No video source available for upload")
                isVideoUploading = false
                throw NSError(
                    domain: "VideoUploadError",
                    code: 8,
                    userInfo: [NSLocalizedDescriptionKey: "No video data available for upload. Please try again."]
                )
            }

            logger.debug("DEBUG: Video upload successful, creating embed")
            let embed = mediaUploadManager.createVideoEmbed(
                aspectRatio: videoItem.aspectRatio,
                alt: videoItem.altText.isEmpty ? "Video" : videoItem.altText
            )

            isVideoUploading = false
            return embed
        } catch {
            isVideoUploading = false
            logger.error("ERROR: Video upload failed: \(error)")

            let errorMessage: String
            switch error {
            case VideoUploadError.processingFailed(let reason):
                errorMessage = reason
            case VideoUploadError.uploadFailed:
                errorMessage = "Video upload failed"
            case VideoUploadError.processingTimeout:
                errorMessage = "Video processing timed out"
            case VideoUploadError.authenticationFailed:
                errorMessage = "Authentication error during upload"
            default:
                errorMessage = error.localizedDescription
            }

            throw NSError(
                domain: "VideoUploadError",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: errorMessage]
            )
        }
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
        do {
            try await exportSession.export(to: outputURL, as: .mp4)
            logger.debug("DEBUG: Export completed successfully")
        } catch {
            logger.debug("DEBUG: Export failed with error: \(error)")
            throw error
        }

        return exportSession
    }
    
    private func processImageForUpload(_ data: Data) async throws -> Data {
        var processedData = data

        if checkImageFormat(data) == "HEIC" {
            if let converted = convertHEICToJPEG(data) {
                processedData = converted
            }
        }

        if let image = PlatformImage(data: processedData),
           let compressed = compressImage(image, maxSizeInBytes: 900_000) {
            processedData = compressed
        }

        return processedData
    }
    
    // MARK: - Image Format Utilities
    
    private func checkImageFormat(_ data: Data) -> String {
        guard data.count >= 4 else { return "Unknown" }
        
        let bytes = data.prefix(4)
        
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "JPEG"
        } else if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "PNG"
        } else if bytes.starts(with: [0x00, 0x00, 0x00]) && data.count > 8 {
            let ftypBytes = data.subdata(in: 4..<8)
            if ftypBytes.starts(with: [0x66, 0x74, 0x79, 0x70]) {
                return "HEIC"
            }
        }
        
        return "Unknown"
    }
    
    private func convertHEICToJPEG(_ data: Data) -> Data? {
        guard let image = PlatformImage(data: data) else {
            return nil
        }
        
        #if os(iOS)
        guard let jpegData = image.jpegData(compressionQuality: 0.8) else {
            return nil
        }
        #elseif os(macOS)
        guard let jpegData = image.jpegImageData(compressionQuality: 0.8) else {
            return nil
        }
        #endif
        
        return jpegData
    }
    
    private func compressImage(_ image: PlatformImage, maxSizeInBytes: Int) -> Data? {
        // Use the built-in compression method from CrossPlatformImage
        return image.compressed(maxSizeInBytes: maxSizeInBytes)
    }
}
