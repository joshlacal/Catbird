//
//  VideoModel.swift
//  Catbird
//
//  Created by Josh LaCalamito on 10/24/24.
//

import AVKit
import Foundation
import Observation
import Petrel
import SwiftUI

@Observable final class VideoModel {
  let id: String
  let url: URL
  let type: VideoType
  let aspectRatio: CGFloat
  let thumbnailURL: URL?
  var currentTime: Double = 0
  var duration: Double?
  var isLoading = false
  var error: Error?
  var isPlaying = false
  var isMuted = true
  var volume: Float = 0.0


  enum VideoType: Equatable {
    case hlsStream(playlistURL: URL, cid: CID, aspectRatio: AspectRatio?)
    case tenorGif(URI)
    case giphyGif(URI)

    var isGif: Bool {
      switch self {
      case .tenorGif, .giphyGif:
        return true
      case .hlsStream(_, _, _):
        return false
      }
    }

    static func == (lhs: VideoType, rhs: VideoType) -> Bool {
      switch (lhs, rhs) {
      case let (.hlsStream(lURL, lCID, lAspect), .hlsStream(rURL, rCID, rAspect)):
        return lURL == rURL && lCID == rCID && lAspect?.width == rAspect?.width
          && lAspect?.height == rAspect?.height
      case let (.tenorGif(lURI), .tenorGif(rURI)):
        return lURI == rURI
      case let (.giphyGif(lURI), .giphyGif(rURI)):
        return lURI == rURI
      default:
        return false
      }
    }
  }

  struct AspectRatio: Equatable {
    let width: Int
    let height: Int
  }

  init(id: String, url: URL, type: VideoType, aspectRatio: CGFloat, thumbnailURL: URL? = nil) {
    self.id = id
    self.url = url
    self.type = type
    self.aspectRatio = aspectRatio
    self.thumbnailURL = thumbnailURL
  }
}
