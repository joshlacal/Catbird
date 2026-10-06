import AVFoundation
import ImageIO
import os
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Media Handling Extension

extension PostComposerViewModel {
    
    // MARK: - Photo and Video Selection Methods
    
    @MainActor
    func processVideoSelection(_ item: PhotosPickerItem) async {
        logger.debug("DEBUG: Processing video selection")

        // Check if it's a GIF
        let isGIF = item.supportedContentTypes.contains(where: { $0.conforms(to: .gif) })
        
        if isGIF {
            logger.debug("DEBUG: Selected item is a GIF, will convert to video")
            await processGIFAsVideo(item)
            return
        }

        // Validate content type
        let isVideo = item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) })
        logger.debug("DEBUG: Is selection a video? \(isVideo)")

        guard isVideo else {
            logger.debug("DEBUG: Selected item is not a video")
            alertItem = AlertItem(title: "Not a Video", message: "Choose a video to attach.")
            return
        }

        // A post has one kind of media, so the video replaces images and GIFs
        mediaItems.removeAll()
        selectedGif = nil

        // Create video media item
        let newVideoItem = MediaItem(pickerItem: item)
        self.videoItem = newVideoItem

        // Load video thumbnail and metadata
        await loadVideoThumbnail(for: newVideoItem)
    }

    @MainActor
    func processPhotoSelection(_ items: [PhotosPickerItem]) async {
        // Check for GIFs first
        for item in items {
            let isGIF = item.supportedContentTypes.contains(where: { contentType in
                contentType.conforms(to: .gif) || 
                contentType.identifier == "com.compuserve.gif" ||
                contentType.identifier == UTType.gif.identifier
            })
            
            if isGIF {
                logger.debug("DEBUG: Found GIF in photo selection, converting to video")
                await processGIFAsVideo(item)
                return
            }
            
            // Check by data inspection
            if let data = try? await item.loadTransferable(type: Data.self) {
                let isAnimatedGIF = isDataAnimatedGIF(data)
                
                if isAnimatedGIF {
                    logger.debug("DEBUG: Detected animated GIF by data inspection, converting to video")
                    await processGIFAsVideoFromData(data)
                    return
                }
            }
        }
        
        // Clear any existing video or GIF
        videoItem = nil
        selectedGif = nil

        // Handle image limit
        if mediaItems.count + items.count > maxImagesAllowed {
            alertItem = imageLimitAlert()
        }

        // Add images up to the limit
        await addMediaItems(Array(items.prefix(maxImagesAllowed - mediaItems.count)))
    }

    @MainActor
    func processMediaSelection(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }

        // Check for videos
        let videoItems = items.filter {
            $0.supportedContentTypes.contains(where: { $0.conforms(to: .movie) })
        }

        if !videoItems.isEmpty {
            // Use only the first video
            let videoPickerItem = videoItems[0]
            mediaItems.removeAll()
            selectedGif = nil
            
            let newVideoItem = MediaItem(pickerItem: videoPickerItem)
            self.videoItem = newVideoItem
            await loadVideoThumbnail(for: newVideoItem)

            if videoItems.count > 1 {
                alertItem = AlertItem(
                    title: "One Video per Post",
                    message: "Only the first video was added. Videos can’t be combined with other media."
                )
            }
        } else {
            // Process as images
            videoItem = nil
            selectedGif = nil

            if mediaItems.count + items.count > maxImagesAllowed {
                alertItem = imageLimitAlert()
            }

            await addMediaItems(Array(items.prefix(maxImagesAllowed - mediaItems.count)))
        }
    }
    
    /// Explains that only some of the chosen images were added.
    func imageLimitAlert() -> AlertItem {
        let remaining = max(0, maxImagesAllowed - mediaItems.count)
        let added = remaining == 1 ? "Only 1 more was added." : "Only \(remaining) more were added."
        return AlertItem(
            title: "Image Limit Reached",
            message: "A post can have up to \(maxImagesAllowed) images. \(remaining == 0 ? "No more images were added." : added)"
        )
    }

    // MARK: - GIF to Video Conversion
    
    func isDataAnimatedGIF(_ data: Data) -> Bool {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }
        
        let frameCount = CGImageSourceGetCount(imageSource)
        guard frameCount > 1 else { return false }
        
        if let uti = CGImageSourceGetType(imageSource) as String? {
            return uti == UTType.gif.identifier || uti == "com.compuserve.gif"
        }
        
        return false
    }
    
    @MainActor
    func processGIFAsVideoFromData(_ gifData: Data) async {
        logger.debug("DEBUG: Processing GIF from data, size: \(gifData.count) bytes")
        
        mediaItems.removeAll()
        selectedGif = nil
        
        do {
            let videoURL = try await convertGIFToVideo(gifData)
            
            var newVideoItem = MediaItem()
            newVideoItem.rawVideoURL = videoURL
            newVideoItem.isLoading = true
            newVideoItem.isGifConversion = true
            
            self.videoItem = newVideoItem
            await loadVideoThumbnail(for: newVideoItem)
            
        } catch {
            logger.error("ERROR: Failed to process GIF as video: \(error)")
            alertItem = AlertItem(
                title: "Couldn’t Add GIF",
                message: "This GIF couldn’t be converted to a video. Try a different GIF."
            )
        }
    }
    
    @MainActor
    func processGIFAsVideo(_ item: PhotosPickerItem) async {
        logger.debug("DEBUG: Processing GIF as video from PhotosPickerItem")
        
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            logger.error("ERROR: Could not load GIF data")
            alertItem = AlertItem(title: "Couldn’t Load GIF", message: "This GIF couldn’t be loaded. Try again.")
            return
        }
        
        await processGIFAsVideoFromData(data)
    }
    
    private func convertGIFToVideo(_ gifData: Data) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // Create temporary file for output
                    let tempDir = FileManager.default.temporaryDirectory
                    let outputURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
                    
                    // Create image source from GIF data
                    guard let imageSource = CGImageSourceCreateWithData(gifData as CFData, nil) else {
                        throw NSError(domain: "GIFConversion", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create image source"])
                    }
                    
                    let frameCount = CGImageSourceGetCount(imageSource)
                    guard frameCount > 1 else {
                        throw NSError(domain: "GIFConversion", code: 2, userInfo: [NSLocalizedDescriptionKey: "GIF has no frames"])
                    }
                    
                    // Get first frame to determine dimensions
                    guard let firstImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                        throw NSError(domain: "GIFConversion", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not get first frame"])
                    }
                    
                    let width = CGFloat(firstImage.width)
                    let height = CGFloat(firstImage.height)
                    
                    // Create video writer
                    let videoWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
                    
                    let videoSettings: [String: Any] = [
                        AVVideoCodecKey: AVVideoCodecType.h264,
                        AVVideoWidthKey: width,
                        AVVideoHeightKey: height
                    ]
                    
                    let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                        assetWriterInput: writerInput,
                        sourcePixelBufferAttributes: [
                            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB
                        ]
                    )
                    
                    videoWriter.add(writerInput)
                    
                    guard videoWriter.startWriting() else {
                        throw videoWriter.error ?? NSError(domain: "GIFConversion", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not start writing"])
                    }
                    
                    videoWriter.startSession(atSourceTime: .zero)
                    
                    let frameDuration = CMTime(value: 1, timescale: 10) // 0.1 seconds per frame
                    var currentTime = CMTime.zero
                    
                    for i in 0..<frameCount {
                        guard let image = CGImageSourceCreateImageAtIndex(imageSource, i, nil) else { continue }

                        guard let pixelBuffer = self.createPixelBuffer(from: image, width: Int(width), height: Int(height)) else { continue }

                        // Wait for writer to be ready - this is on a background queue so brief waits are acceptable
                        while !writerInput.isReadyForMoreMediaData {
                            Thread.sleep(forTimeInterval: 0.01)
                        }

                        adaptor.append(pixelBuffer, withPresentationTime: currentTime)
                        currentTime = CMTimeAdd(currentTime, frameDuration)
                    }
                    
                    writerInput.markAsFinished()
                    
                    videoWriter.finishWriting {
                        if let error = videoWriter.error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: outputURL)
                        }
                    }
                    
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func createPixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB
        ]
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            attributes as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            return nil
        }
        
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        return buffer
    }
    
    // Staged media owns only its new copy. Rejected work must never unlink a saved recording.
    struct PreparedPendingAudioVideo {
        let item: MediaItem
        var blockedReason: String?
        var blockedCode: String?

        func discard() {
            if let url = item.rawVideoURL { try? FileManager.default.removeItem(at: url) }
        }
    }

    func preparePendingAudioVideo(_ videoURL: URL) async throws -> PreparedPendingAudioVideo {
        try Task.checkCancellation()
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.blue.catbird.shared"
        ) else { throw ComposerEditingError.persistenceUnavailable }
        let directory = container.appendingPathComponent("SharedDrafts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copyURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        try FileManager.default.copyItem(at: videoURL, to: copyURL)
        var prepared = PreparedPendingAudioVideo(item: MediaItem(url: copyURL, isAudioVisualizerVideo: true))
        var completed = false
        defer { if !completed { prepared.discard() } }
        var item = prepared.item
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: copyURL))
        generator.appliesPreferredTrackTransform = true
        let cgImage = try await generator.image(at: .zero).image
        try Task.checkCancellation()
        #if os(iOS)
        item.image = Image(uiImage: UIImage(cgImage: cgImage))
        #elseif os(macOS)
        item.image = Image(nsImage: NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height)))
        #endif
        item.aspectRatio = CGSize(width: cgImage.width, height: cgImage.height)
        item.isLoading = false
        prepared = PreparedPendingAudioVideo(item: item)
        if let manager = mediaUploadManager {
            let permission = await manager.preflightUploadPermission(force: true)
            try Task.checkCancellation()
            if !permission.allowed {
                prepared.blockedReason = permission.message ?? "Video uploads are currently unavailable"
                prepared.blockedCode = permission.code
            }
        }
        completed = true
        return prepared
    }

    // MARK: - Audio Visualizer Video Processing
    
    @MainActor
    func processGeneratedVideoFromAudio(_ videoURL: URL) async {
        logger.debug("Processing generated audio visualizer video")
        
        // Clear existing media
        mediaItems.removeAll()
        selectedGif = nil
        
        // Create a MediaItem from the generated video URL
        let videoItem = MediaItem(url: videoURL, isAudioVisualizerVideo: true)
        self.videoItem = videoItem
        
        // Load video thumbnail and metadata
        await loadVideoThumbnailFromURL(for: videoItem, url: videoURL)
        
        // Sync to thread if in thread mode
        if isThreadMode && threadEntries.indices.contains(currentThreadIndex) {
            threadEntries[currentThreadIndex].videoItem = self.videoItem
        }
        
        logger.debug("Successfully processed audio visualizer video")
    }
    
    @MainActor
    private func loadVideoThumbnailFromURL(for item: MediaItem, url: URL) async {
        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        
        do {
            let cgImage = try await imageGenerator.image(at: .zero).image
            
            #if os(iOS)
            let thumbnail = UIImage(cgImage: cgImage)
            let imageSize = thumbnail.size
            videoItem?.image = Image(uiImage: thumbnail)
            #elseif os(macOS)
            let thumbnail = NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
            let imageSize = thumbnail.size
            videoItem?.image = Image(nsImage: thumbnail)
            #endif
            
            // Set aspect ratio for proper video embed creation
            videoItem?.aspectRatio = CGSize(width: imageSize.width, height: imageSize.height)
            videoItem?.isLoading = false
            
            logger.debug("Generated video thumbnail successfully with aspect ratio: \(imageSize.width)x\(imageSize.height)")
        } catch {
            logger.debug("Failed to generate video thumbnail: \(error)")
            videoItem?.isLoading = false
        }
    }
}