import Foundation
import os
import PhotosUI
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

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
      let context = mediaLoadContext()
      guard ownsMediaLoad(context) else { return }
      guard videoItem == nil, selectedGif == nil else {
        alertItem = AlertItem(title: "One Kind of Media per Post",
          message: "Remove the existing video or GIF before adding images.")
        return
      }
      let availableSlots = max(0, maxImagesAllowed - mediaItems.count)
      guard availableSlots > 0 else { return }
      let newMediaItems = items.prefix(availableSlots).map { MediaItem(pickerItem: $0) }
      mediaItems.append(contentsOf: newMediaItems)
      syncMediaStateToCurrentThread()
      saveDraftIfNeeded()

      // Show all placeholders before starting their single transfer. Each loader has its own
      // deadline, so this group never waits for an uncooperative Photos operation itself.
      await withTaskGroup(of: Void.self) { group in
        for id in newMediaItems.map(\.id) {
          let attempt = mediaPreviewLoads.begin(for: id)
          group.addTask { @MainActor [weak self] in
            await self?.loadImageForItem(withId: id, context: context, attempt: attempt)
          }
        }
      }
      guard !Task.isCancelled, ownsMediaLoad(context) else { return }
      syncMediaStateToCurrentThread()
      saveDraftIfNeeded()
    }

    @MainActor
    func retryMediaLoading(withId id: UUID) async {
        let context = mediaLoadContext()
        if let item = videoItem, item.id == id {
            guard !item.isLoading else { return }
            await loadVideoThumbnail(for: item)
        } else {
            guard let item = mediaItems.first(where: { $0.id == id }), !item.isLoading else { return }
            await loadImageForItem(withId: id)
        }
        guard !Task.isCancelled, ownsMediaLoad(context) else { return }
        syncMediaStateToCurrentThread()
        saveDraftIfNeeded()
    }

    // MARK: - Media State Synchronization
    
    func syncMediaStateToCurrentThread() {
        if isThreadMode && threadEntries.indices.contains(currentThreadIndex) {
            threadEntries[currentThreadIndex].mediaItems = mediaItems
            threadEntries[currentThreadIndex].videoItem = videoItem
            threadEntries[currentThreadIndex].selectedGif = selectedGif
        }
    }

    func ownsMediaPreviewLoad(
      _ attempt: MediaPreviewLoadAttempt, for id: UUID, context: MediaLoadContext
    ) -> Bool {
      !Task.isCancelled && mediaPreviewLoads.owns(attempt, for: id) && ownsMediaLoad(context)
    }

    @MainActor
    func loadImageForItem(
      withId id: UUID, context suppliedContext: MediaLoadContext? = nil,
      attempt suppliedAttempt: MediaPreviewLoadAttempt? = nil
    ) async {
      let context = suppliedContext ?? mediaLoadContext()
      let attempt = suppliedAttempt ?? mediaPreviewLoads.begin(for: id)
      defer {
        if mediaPreviewLoads.finish(attempt, for: id) {
          finishMediaLoad(withId: id, context: context)
        }
      }
      guard ownsMediaPreviewLoad(attempt, for: id, context: context),
            let index = mediaItems.firstIndex(where: { $0.id == id }) else { return }
      let item = mediaItems[index]
      mediaItems[index].isLoading = true

      do {
        let data: Data
        if let rawData = item.rawData {
          data = rawData
        } else if let url = item.rawImageURL {
          data = try await attempt.value {
            try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
          }
        } else if let pickerItem = item.pickerItem {
          guard let loaded = try await attempt.value({
            try await pickerItem.loadTransferable(type: Data.self)
          }) else { throw MediaPreviewImageError.unavailable }
          data = loaded
        } else {
          throw MediaPreviewImageError.unavailable
        }

        guard ownsMediaPreviewLoad(attempt, for: id, context: context),
              let currentIndex = mediaItems.firstIndex(where: { $0.id == id }) else { return }
        // Keep the bytes even if decoding or conversion fails, so retry never loses the source.
        mediaItems[currentIndex].rawData = data
        if isDataAnimatedGIF(data) {
          mediaItems[currentIndex].isGifConversion = true
          guard mediaItems.count == 1, videoItem == nil, selectedGif == nil else {
            alertItem = AlertItem(title: "GIF Needs Its Own Post",
              message: "An animated GIF becomes a video. Remove the other attachments before retrying this GIF.")
            return
          }
          let url = try await attempt.value { try await Self.convertGIFToVideo(data) }
          guard ownsMediaPreviewLoad(attempt, for: id, context: context),
                mediaItems.count == 1, videoItem == nil, selectedGif == nil,
                let current = mediaItems.first(where: { $0.id == id }) else { return }
          var converted = current
          converted.rawVideoURL = url
          converted.isGifConversion = true
          mediaItems.removeAll(where: { $0.id == id })
          videoItem = converted
          // A new thumbnail attempt supersedes this conversion's token.
          await loadVideoThumbnail(for: converted)
          return
        }
        guard let platformImage = PlatformImage(data: data) else {
          throw MediaPreviewImageError.unavailable
        }
        #if os(iOS)
        mediaItems[currentIndex].image = Image(uiImage: platformImage)
        #elseif os(macOS)
        mediaItems[currentIndex].image = Image(nsImage: platformImage)
        #endif
        mediaItems[currentIndex].aspectRatio = platformImage.imageSize
      } catch is CancellationError {
        // The matching finalizer exposes Retry without removing the attachment.
      } catch {
        guard ownsMediaPreviewLoad(attempt, for: id, context: context),
              mediaItems.contains(where: { $0.id == id }) else { return }
        let message = error is MediaPreviewLoadError
          ? "Preview preparation timed out. The attachment is still here. Retry when it is available on this device."
          : "Retry this attachment or remove it before posting."
        alertItem = AlertItem(title: "Couldn’t Load Image", message: message)
      }
    }

    // MARK: - Removing Media Items

    func removeMediaItem(at index: Int) {
        guard mediaItems.indices.contains(index) else { return }
        mediaPreviewLoads.cancel(for: mediaItems[index].id)
        mediaItems.remove(at: index)
        syncMediaStateToCurrentThread()
        saveDraftIfNeeded()
    }

    func removeMediaItem(withId id: UUID) {
        mediaPreviewLoads.cancel(for: id)
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


    // MARK: - Video Caption Management

    func updateVideoCaption(_ caption: VideoCaption?) {
        self.videoItem?.caption = caption
        syncMediaStateToCurrentThread()
        saveDraftIfNeeded()
    }

    func removeVideoCaption() {
        self.videoItem?.caption = nil
        syncMediaStateToCurrentThread()
        saveDraftIfNeeded()
    }
    // MARK: - Photo Editing

    func beginEditingImage(for id: UUID, at index: Int) {
        guard mediaItems.indices.contains(index), mediaItems[index].rawData != nil else { return }
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
        
        let context = mediaLoadContext()
        guard self.videoItem?.id == videoItem.id, ownsMediaLoad(context) else { return }
        let attempt = mediaPreviewLoads.begin(for: videoItem.id)
        self.videoItem?.isLoading = true
        defer {
          if mediaPreviewLoads.finish(attempt, for: videoItem.id) {
            finishMediaLoad(withId: videoItem.id, context: context)
          }
        }

        do {
            var asset: AVAsset?
            var videoURL: URL?
            
            if let rawVideoURL = videoItem.rawVideoURL {
                videoURL = rawVideoURL
                asset = AVURLAsset(url: rawVideoURL)
            } else if let pickerItem = videoItem.pickerItem {
                // Copy the movie file straight to disk instead of loading it into memory.
                if let movie = try await attempt.value({ try await pickerItem.loadTransferable(type: PickedMovie.self) }) {
                    guard self.videoItem?.id == videoItem.id, ownsMediaPreviewLoad(attempt, for: videoItem.id, context: context) else { return }
                    videoURL = movie.url
                    asset = AVURLAsset(url: movie.url)
                    self.videoItem?.rawVideoURL = movie.url
                }
            }
            
            guard let asset = asset else {
                logger.error("ERROR: Could not create AVAsset")
                rejectVideo(videoItem, title: "Couldn’t Load Video", message: "This video couldn’t be loaded. Try again.")
                return
            }

            // Use the same policy as the multipart uploader before preparing a preview.
            if let videoURL,
               let fileSize = (try? FileManager.default.attributesOfItem(atPath: videoURL.path))?[.size] as? NSNumber,
               fileSize.int64Value > Self.maxVideoFileSize {
                rejectVideo(videoItem, title: "Video Too Large", message: VideoUploadPolicy.sizeMessage)
                return
            }
            let duration = try await attempt.value { try await asset.load(.duration) }
            guard self.videoItem?.id == videoItem.id, ownsMediaPreviewLoad(attempt, for: videoItem.id, context: context) else { return }
            if CMTimeGetSeconds(duration) > Self.maxVideoDurationSeconds {
                rejectVideo(videoItem, title: "Video Too Long", message: VideoUploadPolicy.durationMessage)
                return
            }
            
            // Store the asset
            self.videoItem?.rawVideoAsset = asset
            
            // Generate thumbnail
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.appliesPreferredTrackTransform = true
            
            let time = CMTime(seconds: 0, preferredTimescale: 1)
            let cgImage = try await attempt.value { try await imageGenerator.image(at: time).image }
            
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
            
            guard self.videoItem?.id == videoItem.id, ownsMediaPreviewLoad(attempt, for: videoItem.id, context: context) else { return }
            // Update only the attachment that requested this thumbnail.
            self.videoItem?.image = image
            self.videoItem?.isLoading = false
            self.videoItem?.aspectRatio = CGSize(width: imageSize.width, height: imageSize.height)
            
            logger.debug("DEBUG: Video thumbnail loaded successfully")
            // After thumbnail, preflight eligibility (single-shot)
            await checkVideoUploadEligibility()
            
        } catch is CancellationError {
            // Leave the source and metadata available for retry.
        } catch {
            guard self.videoItem?.id == videoItem.id, ownsMediaPreviewLoad(attempt, for: videoItem.id, context: context) else { return }
            logger.error("ERROR: Failed to load video thumbnail: \(error)")
            let message = error is MediaPreviewLoadError
              ? "Preview preparation timed out. The attachment is still here. Retry when it is available on this device."
              : "This video couldn’t be loaded. Try again."
            rejectVideo(videoItem, title: "Couldn’t Load Video", message: message)
        }
    }

    static let maxVideoFileSize = VideoUploadPolicy.maximumBytes
    static let maxVideoDurationSeconds = VideoUploadPolicy.maximumDuration

    /// Keep the source, description and captions available for retry or explicit removal.
    @MainActor
    private func rejectVideo(_ rejected: MediaItem, title: String, message: String) {
        guard self.videoItem?.id == rejected.id else { return }
        self.videoItem?.isLoading = false
        syncMediaStateToCurrentThread()
        alertItem = AlertItem(title: title, message: message)
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

// MARK: - Picked Movie

/// A movie from the photo picker, copied to the app group so drafts can reopen it.
struct PickedMovie: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let directory = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: "group.blue.catbird.shared")?
                .appendingPathComponent("SharedDrafts", isDirectory: true)
                ?? FileManager.default.temporaryDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let pathExtension = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = directory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(pathExtension)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
    }
}

private enum MediaPreviewImageError: Error {
  case unavailable
}
