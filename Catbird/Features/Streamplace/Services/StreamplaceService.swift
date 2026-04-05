import AVFoundation
import Foundation
import Observation
import OSLog
import Petrel


@Observable
final class StreamplaceService {
  private static let logger = Logger(subsystem: "blue.catbird", category: "StreamplaceService")
  private let client: ATProtoClient

  private(set) var videos: [VideoRecord] = []
  private(set) var isLoading = false
  private(set) var hasMore = true
  private var cursor: String?

  // Thumbnail cache — lives in the service, not the view
  private(set) var thumbnails: [String: CGImage] = [:]
  private var thumbnailTasks: [String: Task<Void, Never>] = [:]

  struct VideoRecord: Identifiable, Equatable {
    let id: String
    let uri: String
    let video: PlaceStreamVideo
    var hlsURL: URL {
      var components = URLComponents(string: "https://vod-beta.stream.place/xrpc/place.stream.playback.getVideoPlaylist")!
      components.queryItems = [URLQueryItem(name: "uri", value: uri)]
      return components.url!
    }
    var formattedDuration: String {
      let totalSeconds = video.duration / 1_000_000_000
      let hours = totalSeconds / 3600
      let minutes = (totalSeconds % 3600) / 60
      let seconds = totalSeconds % 60
      if hours > 0 {
        return String(format: "%dh %dm", hours, minutes)
      } else {
        return String(format: "%dm %ds", minutes, seconds)
      }
    }

    static func == (lhs: VideoRecord, rhs: VideoRecord) -> Bool {
      lhs.id == rhs.id
    }
  }

  init(client: ATProtoClient) {
    self.client = client
  }

  func loadVideos(forDID did: String) async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }

    do {
      let params = ComAtprotoRepoListRecords.Parameters(
        repo: try ATIdentifier(string: did),
        collection: try NSID(nsidString: "place.stream.video"),
        limit: 50,
        cursor: cursor,
        reverse: true
      )
      let (_, output) = try await client.com.atproto.repo.listRecords(input: params)
      guard let output else { return }

      let newVideos = output.records.compactMap { record -> VideoRecord? in
        guard case .knownType(let value) = record.value,
              let video = value as? PlaceStreamVideo else {
          return nil
        }
        return VideoRecord(id: record.uri.uriString(), uri: record.uri.uriString(), video: video)
      }

      if cursor == nil {
        videos = newVideos
      } else {
        videos.append(contentsOf: newVideos)
      }

      cursor = output.cursor
      hasMore = output.cursor != nil

      // Kick off thumbnail generation for visible videos (non-cancellable)
      for video in newVideos {
        requestThumbnail(for: video)
      }
    } catch {
      print("StreamplaceService - Failed to load videos for \(did): \(error)")
    }
  }

  func requestThumbnail(for video: VideoRecord) {
    guard thumbnails[video.id] == nil, thumbnailTasks[video.id] == nil else { return }

    // Detached task — won't be cancelled when the view disappears
    thumbnailTasks[video.id] = Task.detached(priority: .utility) { [weak self] in
      let image = await Self.generateThumbnail(for: video)
      await MainActor.run {
        self?.thumbnailTasks[video.id] = nil
        if let image {
          self?.thumbnails[video.id] = image
        }
      }
    }
  }

  func hasVideos(forDID did: String) async -> Bool {
    do {
      let params = ComAtprotoRepoListRecords.Parameters(
        repo: try ATIdentifier(string: did),
        collection: try NSID(nsidString: "place.stream.video"),
        limit: 1,
        cursor: nil,
        reverse: nil
      )
      let (_, output) = try await client.com.atproto.repo.listRecords(input: params)
      return (output?.records.count ?? 0) > 0
    } catch {
      return false
    }
  }

  func reset() {
    videos = []
    cursor = nil
    hasMore = true
    isLoading = false
    for task in thumbnailTasks.values { task.cancel() }
    thumbnailTasks.removeAll()
    thumbnails.removeAll()
  }

  // MARK: - Thumbnail Generation

  private static func generateThumbnail(for video: VideoRecord) async -> CGImage? {
    logger.info("Thumbnail: starting for '\(video.video.title.prefix(30))'")

    let asset = AVURLAsset(url: video.hlsURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 640, height: 360)
    generator.requestedTimeToleranceBefore = .positiveInfinity
    generator.requestedTimeToleranceAfter = .positiveInfinity

    // Use a short seek time — the HLS playlists are huge for long videos,
    // and AVAssetImageGenerator needs to parse the whole playlist to seek far.
    // 30 seconds in is enough to get past "starting soon" screens.
    let seekTime = CMTime(seconds: 30, preferredTimescale: 600)

    // Timeout after 15 seconds — some playlists are very large
    do {
      let cgImage = try await withThrowingTaskGroup(of: CGImage.self) { group in
        group.addTask {
          let (image, _) = try await generator.image(at: seekTime)
          return image
        }
        group.addTask {
          try await Task.sleep(for: .seconds(15))
          throw CancellationError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
      }
      logger.info("Thumbnail: success for '\(video.video.title.prefix(30))'")
      return cgImage
    } catch {
      logger.warning("Thumbnail: failed for '\(video.video.title.prefix(30))': \(error.localizedDescription)")
      return nil
    }
  }
}
