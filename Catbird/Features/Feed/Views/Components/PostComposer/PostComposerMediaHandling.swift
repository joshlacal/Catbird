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

        guard mediaItems.isEmpty, videoItem == nil, selectedGif == nil else {
            alertItem = AlertItem(title: "One Kind of Media per Post",
                message: "Remove the existing attachments before adding a video.")
            return
        }

        // Create video media item
        let newVideoItem = MediaItem(pickerItem: item)
        self.videoItem = newVideoItem
        syncMediaStateToCurrentThread()
        saveDraftIfNeeded()

        // Load video thumbnail and metadata
        await loadVideoThumbnail(for: newVideoItem)
    }

    @MainActor
    func processPhotoSelection(_ items: [PhotosPickerItem]) async {
      if mediaItems.count + items.count > maxImagesAllowed { alertItem = imageLimitAlert() }
      // The image loader inspects GIF bytes after its single bounded Photos transfer.
      await addMediaItems(items)
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
            guard mediaItems.isEmpty, videoItem == nil, selectedGif == nil else {
                alertItem = AlertItem(title: "One Kind of Media per Post",
                    message: "Remove the existing attachments before adding a video.")
                return
            }
            let context = mediaLoadContext()
            let newVideoItem = MediaItem(pickerItem: videoPickerItem)
            self.videoItem = newVideoItem
            syncMediaStateToCurrentThread()
            saveDraftIfNeeded()
            await loadVideoThumbnail(for: newVideoItem)

            guard !Task.isCancelled, ownsMediaLoad(context), self.videoItem?.id == newVideoItem.id else { return }
            if videoItems.count > 1 {
                alertItem = AlertItem(
                    title: "One Video per Post",
                    message: "Only the first video was added. Videos can’t be combined with other media."
                )
            }
        } else {
            // Process as images without discarding an existing video or GIF.
            if mediaItems.count + items.count > maxImagesAllowed {
                alertItem = imageLimitAlert()
            }

            await addMediaItems(items)
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
      guard mediaItems.isEmpty, videoItem == nil, selectedGif == nil else {
        alertItem = AlertItem(title: "GIF Needs Its Own Post",
          message: "Remove the existing attachments before adding an animated GIF.")
        return
      }
      var item = MediaItem()
      item.rawData = gifData
      item.isGifConversion = true
      mediaItems.append(item)
      syncMediaStateToCurrentThread()
      saveDraftIfNeeded()
      let context = mediaLoadContext()
      await loadImageForItem(withId: item.id)
      guard !Task.isCancelled, ownsMediaLoad(context) else { return }
      syncMediaStateToCurrentThread()
      saveDraftIfNeeded()
    }

    @MainActor
    func processGIFAsVideo(_ item: PhotosPickerItem) async {
      // Preserve the picker handle in a visible attachment before downloading from iCloud.
      await addMediaItems([item])
    }

    nonisolated static func convertGIFToVideo(_ gifData: Data) async throws -> URL {
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
                    
                    let deadline = ContinuousClock.now.advanced(by: .seconds(120))
                    for i in 0..<frameCount {
                        guard let image = CGImageSourceCreateImageAtIndex(imageSource, i, nil) else { continue }

                        guard let pixelBuffer = Self.createPixelBuffer(from: image, width: Int(width), height: Int(height)) else { continue }

                        // Wait for writer to be ready - this is on a background queue so brief waits are acceptable
                        while !writerInput.isReadyForMoreMediaData {
                            guard ContinuousClock.now < deadline, videoWriter.status == .writing else {
                                videoWriter.cancelWriting()
                                throw MediaPreviewLoadError.timedOut
                            }
                            Thread.sleep(forTimeInterval: 0.01)
                        }
                        guard ContinuousClock.now < deadline else {
                            videoWriter.cancelWriting()
                            throw MediaPreviewLoadError.timedOut
                        }
                        guard adaptor.append(pixelBuffer, withPresentationTime: currentTime) else {
                            throw videoWriter.error ?? NSError(domain: "GIFConversion", code: 5,
                                userInfo: [NSLocalizedDescriptionKey: "Could not encode GIF frame"])
                        }
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
    
    nonisolated private static func createPixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
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
      await loadVideoThumbnail(for: item)
    }

}
