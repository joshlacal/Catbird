//
//  VideoModel.swift
//  Catbird
//
//  Created by Josh LaCalamito on 10/24/24.
//

import Observation
import Foundation
import AVKit
import SwiftUI
import Petrel

@Observable final class VideoModel {
    let id: String
    let url: URL
    let type: VideoType
    let aspectRatio: CGFloat
    var currentTime: Double = 0
    var duration: Double?
    var isLoading = false
    var error: Error?
    var isPlaying = false
    var isMuted = true
    var volume: Float = 0.0
    
    enum VideoType: Equatable {
        case hlsStream(AppBskyEmbedVideo.View)
        case tenorGif(URI)
        
        var isGif: Bool {
            if case .tenorGif = self { return true }
            return false
        }
    }
    
    init(id: String, url: URL, type: VideoType, aspectRatio: CGFloat) {
        self.id = id
        self.url = url
        self.type = type
        self.aspectRatio = aspectRatio
    }
}

