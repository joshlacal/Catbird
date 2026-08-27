import Foundation

/// Tri-state consent for external media embeds
public enum ExternalMediaConsent: String, Codable, Sendable, CaseIterable {
    case undecided
    case allow
    case hide
    
    public var title: String {
        switch self {
        case .undecided: return "Ask Before Playing"
        case .allow: return "Always Allow"
        case .hide: return "Always Block"
        }
    }
}

/// External media providers supported for rich embed playback
public enum ExternalMediaProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case youtube
    case youtubeShorts
    case vimeo
    case twitch
    case spotify
    case appleMusic
    case soundcloud
    case giphy
    case tenor
    case klipy
    case flickr
    case bandcamp
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .youtube: return "YouTube"
        case .youtubeShorts: return "YouTube Shorts"
        case .vimeo: return "Vimeo"
        case .twitch: return "Twitch"
        case .spotify: return "Spotify"
        case .appleMusic: return "Apple Music"
        case .soundcloud: return "SoundCloud"
        case .giphy: return "GIPHY"
        case .tenor: return "Tenor"
        case .klipy: return "Klipy"
        case .flickr: return "Flickr"
        case .bandcamp: return "Bandcamp"
        }
    }
    
    public var hostDescription: String {
        switch self {
        case .youtube: return "youtube.com, youtu.be"
        case .youtubeShorts: return "youtube.com/shorts"
        case .vimeo: return "vimeo.com"
        case .twitch: return "twitch.tv"
        case .spotify: return "open.spotify.com"
        case .appleMusic: return "music.apple.com"
        case .soundcloud: return "soundcloud.com"
        case .giphy: return "giphy.com"
        case .tenor: return "tenor.com"
        case .klipy: return "static.klipy.com"
        case .flickr: return "flickr.com"
        case .bandcamp: return "bandcamp.com"
        }
    }
}
