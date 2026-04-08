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
      let totalSeconds = (video.duration ?? 0) / 1_000_000_000
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

      for video in newVideos {
        requestThumbnail(for: video)
      }
    } catch {
      Self.logger.error("Failed to load videos for \(did): \(error.localizedDescription)")
    }
  }

  func requestThumbnail(for video: VideoRecord) {
    guard thumbnails[video.id] == nil, thumbnailTasks[video.id] == nil else { return }

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
  //
  // AVAssetImageGenerator can't seek into Streamplace HLS streams because the
  // init segment is served by a separate XRPC endpoint and the playlists for
  // long videos are massive.
  //
  // Instead: fetch the init segment + a mid-video data segment directly from
  // the CDN, combine into a minimal MP4 fragment, extract a frame from that.

  private static func generateThumbnail(for video: VideoRecord) async -> CGImage? {
    logger.info("Thumbnail: starting for '\(video.video.title.prefix(40))'")

    do {
      let encodedURI = video.uri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? video.uri

      // 1. Fetch the media playlist to find segment URLs and byte ranges
      let playlistURL = URL(string: "https://vod-beta.stream.place/xrpc/place.stream.playback.getVideoPlaylist?uri=\(encodedURI)&track=1")!
      let (playlistData, _) = try await URLSession.shared.data(from: playlistURL)
      guard let playlist = String(data: playlistData, encoding: .utf8) else { return nil }

      // Parse segments: find one near the middle
      let lines = playlist.components(separatedBy: "\n")
      var segments: [(url: String, length: Int, offset: Int)] = []
      var pendingByteRange: (length: Int, offset: Int)?

      for line in lines {
        if line.hasPrefix("#EXT-X-BYTERANGE:") {
          let range = line.replacingOccurrences(of: "#EXT-X-BYTERANGE:", with: "")
          let parts = range.split(separator: "@")
          if parts.count == 2, let len = Int(parts[0]), let off = Int(parts[1]) {
            pendingByteRange = (len, off)
          }
        } else if line.hasPrefix("https://"), let br = pendingByteRange {
          segments.append((url: line.trimmingCharacters(in: .whitespacesAndNewlines), length: br.length, offset: br.offset))
          pendingByteRange = nil
        }
      }

      guard !segments.isEmpty else {
        logger.warning("Thumbnail: no segments found in playlist for '\(video.video.title.prefix(30))'")
        return nil
      }

      // Pick a segment near the middle
      let midIndex = segments.count / 2
      let seg = segments[midIndex]

      // 2. Fetch the init segment
      let initURL = URL(string: "https://vod-beta.stream.place/xrpc/place.stream.playback.getInitSegment?uri=\(encodedURI)&track=1")!
      let (initData, _) = try await URLSession.shared.data(from: initURL)

      // 3. Fetch the video segment via byte range
      var segRequest = URLRequest(url: URL(string: seg.url)!)
      let endByte = seg.offset + seg.length - 1
      segRequest.setValue("bytes=\(seg.offset)-\(endByte)", forHTTPHeaderField: "Range")
      let (segData, _) = try await URLSession.shared.data(for: segRequest)

      // 4. Combine init + segment into a temp file
      let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("sp_thumb_\(UUID().uuidString).mp4")
      var combined = Data()
      combined.append(initData)
      combined.append(segData)
      try combined.write(to: tempURL)
      defer { try? FileManager.default.removeItem(at: tempURL) }

      // 5. Extract a frame
      let asset = AVURLAsset(url: tempURL)
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 640, height: 360)
      generator.requestedTimeToleranceBefore = .positiveInfinity
      generator.requestedTimeToleranceAfter = .positiveInfinity

      let (cgImage, _) = try await generator.image(at: .zero)
      logger.info("Thumbnail: success for '\(video.video.title.prefix(40))' (\(cgImage.width)x\(cgImage.height))")
      return cgImage
    } catch {
      logger.warning("Thumbnail: failed for '\(video.video.title.prefix(40))': \(error.localizedDescription)")
      return nil
    }
  }
}
