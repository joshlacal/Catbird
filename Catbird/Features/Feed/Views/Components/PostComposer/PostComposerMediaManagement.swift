import Foundation
import os
import PhotosUI
import SwiftUI
import AVFoundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Media Management Extension

extension PostComposerViewModel {
    
    // MARK: - Adding Media Items
    
    @MainActor
    func addMediaItems(_ items: [PhotosPickerItem]) async {
        logger.info("PostComposerMedia: addMediaItems called with \(items.count) items")
        
        // Clear selected GIF when adding other media
        if selectedGif != nil {
            logger.debug("PostComposerMedia: Clearing existing GIF selection")
            selectedGif = nil
        }
        
        // Check each item for GIFs before processing as regular images
        for (index, item) in items.enumerated() {
            logger.debug("PostComposerMedia: Checking item \(index + 1)/\(items.count) for GIF content")
            
            if let data = try? await item.loadTransferable(type: Data.self) {
                logger.debug("PostComposerMedia: Loaded data for item \(index + 1) - size: \(data.count) bytes")
                
                if isDataAnimatedGIF(data) {
                    logger.info("PostComposerMedia: Item \(index + 1) is an animated GIF - converting to video")
                    // Clear other media when adding GIF
                    mediaItems.removeAll()
                    await processGIFAsVideoFromData(data)
                    syncMediaStateToCurrentThread()
                    return
                } else {
                    logger.trace("PostComposerMedia: Item \(index + 1) is not an animated GIF")
                }
            }
        }
        
        // If no GIFs found, process as regular images
        logger.info("PostComposerMedia: No animated GIFs found, processing \(items.count) items as regular images")
        
        // Clear video when adding images
        videoItem = nil
        
        let availableSlots = maxImagesAllowed - mediaItems.count
        guard availableSlots > 0 else { return }

        let itemsToAdd = items.prefix(availableSlots)
        let newMediaItems = itemsToAdd.map { MediaItem(pickerItem: $0) }

        mediaItems.append(contentsOf: newMediaItems)

        // Load each image asynchronously using IDs to avoid index invalidation
        let itemsToLoad = mediaItems.filter { $0.image == nil }.map { $0.id }
        for itemId in itemsToLoad {
            await loadImageForItem(withId: itemId)
        }
        
        // Sync media state to current thread
        syncMediaStateToCurrentThread()
        
        // Save draft after adding media
        saveDraftIfNeeded()
    }
    
    // MARK: - Media State Synchronization
    
    private func syncMediaStateToCurrentThread() {
        if isThreadMode && threadEntries.indices.contains(currentThreadIndex) {
            threadEntries[currentThreadIndex].mediaItems = mediaItems
            threadEntries[currentThreadIndex].videoItem = videoItem
            threadEntries[currentThreadIndex].selectedGif = selectedGif
        }
    }

    @MainActor
    private func loadImageForItem(withId id: UUID) async {
        guard let index = mediaItems.firstIndex(where: { $0.id == id }) else {
            logger.warning("PostComposerMedia: loadImageForItem - item with id \(id) not found")
            return
        }

        // Skip loading if this is pasted content (already has image data)
        guard let pickerItem = mediaItems[index].pickerItem else {
            logger.debug("PostComposerMedia: Skipping load for pasted content item with id \(id)")
            return
        }

        logger.debug("PostComposerMedia: Loading image for item with id \(id)")
        
        // Ensure isLoading is set to false even if we exit early or throw
        defer {
            if let currentIndex = mediaItems.firstIndex(where: { $0.id == id }) {
                mediaItems[currentIndex].isLoading = false
            }
        }
        
        do {
            let (data, platformImage) = try await loadImageData(from: pickerItem)

            guard let currentIndex = mediaItems.firstIndex(where: { $0.id == id }) else {
                logger.warning("PostComposerMedia: Item removed during loading for id \(id)")
                return
            }

            if let platformImage = platformImage {
                #if os(iOS)
                mediaItems[currentIndex].image = Image(uiImage: platformImage)
                #elseif os(macOS)
                mediaItems[currentIndex].image = Image(nsImage: platformImage)
                #endif
                mediaItems[currentIndex].aspectRatio = CGSize(
                    width: platformImage.imageSize.width, height: platformImage.imageSize.height)
                mediaItems[currentIndex].rawData = data
                logger.info("PostComposerMedia: Image loaded successfully for id \(id) - size: \(platformImage.imageSize.width)x\(platformImage.imageSize.height)")
            } else {
                logger.error("PostComposerMedia: Failed to create platform image from data for id \(id)")
                mediaItems.removeAll(where: { $0.id == id })
            }
        } catch let error as NSError {
            logger.error("PostComposerMedia: Error loading image for id \(id) - code: \(error.code), error: \(error.localizedDescription)")
            
            // Check if this is our special animated GIF error
            if error.code == 100, let gifData = error.userInfo["gifData"] as? Data {
                logger.info("PostComposerMedia: Caught animated GIF error for id \(id), converting to video")
                // Remove this item from mediaItems
                mediaItems.removeAll(where: { $0.id == id })
                // Process as GIF video
                await processGIFAsVideoFromData(gifData)
            } else {
                // Remove failed item
                logger.warning("PostComposerMedia: Removing failed item with id \(id)")
                mediaItems.removeAll(where: { $0.id == id })
            }
        } catch {
            logger.error("PostComposerMedia: Unexpected error loading image for id \(id) - error: \(error.localizedDescription)")
            // Remove failed item
            mediaItems.removeAll(where: { $0.id == id })
        }
    }

    private func loadImageData(from item: PhotosPickerItem) async throws -> (Data, PlatformImage?) {
        logger.debug("DEBUG: Loading image data from PhotosPickerItem")
        
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw NSError(
                domain: "ImageLoadingError", code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Failed to load image data"])
        }
        
        logger.debug("DEBUG: Loaded \(data.count) bytes of image data")
        
        // Check if this is actually an animated GIF that slipped through
        if isDataAnimatedGIF(data) {
            logger.debug("DEBUG: Detected animated GIF in loadImageData! Throwing error to trigger GIF conversion")
            throw NSError(
                domain: "ImageLoadingError", 
                code: 100,
                userInfo: [
                    NSLocalizedDescriptionKey: "This is an animated GIF",
                    "gifData": data
                ])
        }

        let platformImage = PlatformImage(data: data)
        return (data, platformImage)
    }
    
    // MARK: - Removing Media Items

    func removeMediaItem(at index: Int) {
        guard index < mediaItems.count else { return }
        mediaItems.remove(at: index)
        saveDraftIfNeeded()
    }

    func removeMediaItem(withId id: UUID) {
        if videoItem?.id == id {
            videoItem = nil
        } else {
            mediaItems.removeAll(where: { $0.id == id })
        }
        
        // Sync media state to current thread
        syncMediaStateToCurrentThread()
        
        // Save draft after removing media
        saveDraftIfNeeded()
    }

    // MARK: - Reorder Media Items
    @MainActor
    func moveMediaItemLeft(id: UUID) {
        guard let idx = mediaItems.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        mediaItems.swapAt(idx, idx - 1)
        syncMediaStateToCurrentThread()
        saveDraftIfNeeded()
    }

    @MainActor
    func moveMediaItemRight(id: UUID) {
        guard let idx = mediaItems.firstIndex(where: { $0.id == id }), idx < mediaItems.count - 1 else { return }
        mediaItems.swapAt(idx, idx + 1)
        syncMediaStateToCurrentThread()
        saveDraftIfNeeded()
    }

    // MARK: - Crop Image to Square
    @MainActor
    func cropMediaItemToSquare(id: UUID) {
        guard let index = mediaItems.firstIndex(where: { $0.id == id }), let data = mediaItems[index].rawData else { return }
        #if os(iOS)
        if let image = UIImage(data: data) {
            let size = min(image.size.width, image.size.height)
            let originX = (image.size.width - size) / 2.0
            let originY = (image.size.height - size) / 2.0
            let cropRect = CGRect(x: originX, y: originY, width: size, height: size)
            if let cg = image.cgImage?.cropping(to: cropRect) {
                let squared = UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
                if let jpeg = squared.jpegData(compressionQuality: 0.9) {
                    mediaItems[index].rawData = jpeg
                    mediaItems[index].image = Image(uiImage: squared)
                    mediaItems[index].aspectRatio = CGSize(width: squared.size.width, height: squared.size.height)
                }
            }
        }
        #elseif os(macOS)
        // macOS crop not implemented
        #endif
    }

    // MARK: - Reorder by index
    @MainActor
    func moveMediaItem(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              mediaItems.indices.contains(sourceIndex),
              mediaItems.indices.contains(destinationIndex) else { return }
        let item = mediaItems.remove(at: sourceIndex)
        mediaItems.insert(item, at: destinationIndex)
        syncMediaStateToCurrentThread()
    }
    
    // MARK: - Alt Text Management

    func updateAltText(_ text: String, for id: UUID) {
        if let videoItem = videoItem, videoItem.id == id {
            let truncatedText = String(text.prefix(maxAltTextLength))
            self.videoItem?.altText = truncatedText
        } else if let index = mediaItems.firstIndex(where: { $0.id == id }) {
            let truncatedText = String(text.prefix(maxAltTextLength))
            mediaItems[index].altText = truncatedText
        }
        saveDraftIfNeeded()
    }

    func beginEditingAltText(for id: UUID) {
        currentEditingMediaId = id
        isAltTextEditorPresented = true
    }

    // MARK: - Photo Editing

    func beginEditingImage(for id: UUID, at index: Int) {
        currentEditingImageIndex = index
        isPhotoEditorPresented = true
    }

    func updateEditedImage(_ newImage: PlatformImage, at index: Int) {
        guard mediaItems.indices.contains(index) else {
            logger.warning("PostComposerMedia: Cannot update edited image - index \(index) out of bounds")
            return
        }

        logger.info("PostComposerMedia: Updating edited image at index \(index)")

        #if os(iOS)
        // Convert image to SwiftUI Image
        mediaItems[index].image = Image(uiImage: newImage)

        // Convert to JPEG data for upload
        if let jpegData = newImage.jpegData(compressionQuality: 0.9) {
            mediaItems[index].rawData = jpegData
            logger.debug("PostComposerMedia: Converted edited image to JPEG - size: \(jpegData.count) bytes")
        }

        // Update aspect ratio
        mediaItems[index].aspectRatio = CGSize(
            width: newImage.size.width,
            height: newImage.size.height
        )
        #elseif os(macOS)
        // Convert image to SwiftUI Image
        mediaItems[index].image = Image(nsImage: newImage)

        // Convert to JPEG data for upload
        if let jpegData = newImage.jpegImageData(compressionQuality: 0.9) {
            mediaItems[index].rawData = jpegData
            logger.debug("PostComposerMedia: Converted edited image to JPEG - size: \(jpegData.count) bytes")
        }

        // Update aspect ratio
        mediaItems[index].aspectRatio = newImage.size
        #endif

        logger.info("PostComposerMedia: Image updated successfully at index \(index) - new size: \(self.mediaItems[index].aspectRatio?.width ?? 0)x\(self.mediaItems[index].aspectRatio?.height ?? 0)")

        saveDraftIfNeeded()
    }

    // MARK: - Video Thumbnail Loading
    
    @MainActor
    func loadVideoThumbnail(for videoItem: MediaItem) async {
        logger.debug("DEBUG: Loading video thumbnail")
        
        guard (self.videoItem != nil ? 0 : nil) != nil else { return }
        
        do {
            var asset: AVAsset?
            
            if let pickerItem = videoItem.pickerItem {
                // Load from PhotosPickerItem
                if let movieData = try await pickerItem.loadTransferable(type: Data.self) {
                    // Persist to App Group so it's accessible and survives tmp cleanup
                    let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.blue.catbird.shared")?
                        .appendingPathComponent("SharedDrafts", isDirectory: true)
                    if let dir {
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        let destURL = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
                        try movieData.write(to: destURL)
                        asset = AVAsset(url: destURL)
                        self.videoItem?.rawVideoURL = destURL
                        self.videoItem?.videoData = movieData
                    } else {
                        // Fallback to temporary directory
                        let tempURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString)
                            .appendingPathExtension("mov")
                        try movieData.write(to: tempURL)
                        asset = AVAsset(url: tempURL)
                        self.videoItem?.rawVideoURL = tempURL
                        self.videoItem?.videoData = movieData
                    }
                }
            } else if let videoURL = videoItem.rawVideoURL {
                // Load from URL (for GIF conversions)
                asset = AVAsset(url: videoURL)
            }
            
            guard let asset = asset else {
                logger.error("ERROR: Could not create AVAsset")
                return
            }
            
            // Store the asset
            self.videoItem?.rawVideoAsset = asset
            
            // Generate thumbnail
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.appliesPreferredTrackTransform = true
            
            let time = CMTime(seconds: 0, preferredTimescale: 1)
            let cgImage = try await imageGenerator.image(at: time).image
            
            guard let platformImage = PlatformImage.image(from: cgImage) else {
                throw NSError(
                    domain: "ImageLoadingError", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create platform image from CGImage"])
            }
            
            #if os(iOS)
            let image = Image(uiImage: platformImage)
            let imageSize = platformImage.size
            #elseif os(macOS)
            let image = Image(nsImage: platformImage)
            let imageSize = platformImage.size
            #endif
            
            // Update the video item
            self.videoItem?.image = image
            self.videoItem?.isLoading = false
            self.videoItem?.aspectRatio = CGSize(width: imageSize.width, height: imageSize.height)
            
            logger.debug("DEBUG: Video thumbnail loaded successfully")
            // After thumbnail, preflight eligibility (single-shot)
            await checkVideoUploadEligibility()
            
        } catch {
            logger.error("ERROR: Failed to load video thumbnail: \(error)")
            self.videoItem?.isLoading = false
        }
    }
    
    // MARK: - Media Source Tracking
    
    func generateSourceID(for source: MediaSource) -> String {
        switch source {
        case .photoPicker(let identifier):
            return "picker:\(identifier)"
        case .pastedImage(let data):
            return "paste:\(data.hashValue)"
        case .gifConversion(let identifier):
            return "gif:\(identifier)"
        case .genmojiConversion(let data):
            return "genmoji:\(data.hashValue)"
        }
    }
    
    func trackMediaSource(_ source: MediaSource) {
        let sourceID = generateSourceID(for: source)
        mediaSourceTracker.insert(sourceID)
    }
    
    func isMediaSourceAlreadyAdded(_ source: MediaSource) -> Bool {
        let sourceID = generateSourceID(for: source)
        return mediaSourceTracker.contains(sourceID)
    }
}
