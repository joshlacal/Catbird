//
//  FeedTypes.swift
//  Catbird
//
//  Created by Josh LaCalamito on 1/31/25.
//

import Foundation
import Petrel

/// Types of feeds that can be displayed
enum FetchType: Hashable {
    /// Home timeline feed with chronological posts
    case timeline
    
    /// Custom feed from a feed generator
    case feed(ATProtocolURI)

    /// Feed from a list (curated, moderation, etc.)
    case list(ATProtocolURI)
    
    /// Posts from a specific author
    case author(String)
    
    /// Posts liked by a specific author
    case likes(String)
    
    /// Unique identifier for this fetch type (used for comparisons)
    var identifier: String {
        switch self {
        case .timeline:
            return "timeline"
        case .list(let uri):
            return "list:\(uri.uriString())"
        case .feed(let uri):
            return "feed:\(uri.uriString())"
        case .author(let did):
            return "author:\(did)"
        case .likes(let did):
            return "likes:\(did)"
        }
    }
    
    /// Human-readable display name for this feed type
    var displayName: String {
        switch self {
        case .timeline:
            return "Timeline"
        case .list(let uri):
            // Get just the record key part from the URI
            let recordKey = uri.uriString().components(separatedBy: "/").last ?? "Unknown"
            return "List: \(recordKey)"
        case .feed(let uri):
            // Get just the record key part from the URI
            let recordKey = uri.uriString().components(separatedBy: "/").last ?? "Unknown"
            return "Custom Feed: \(recordKey)"
        case .author(let did):
            // Display handle if available, otherwise DID
            return "Posts by \(did)"
        case .likes(let did):
            return "Likes by \(did)"
        }
    }
}

// Extend Equatable for FetchType
extension FetchType: Equatable {
    static func == (lhs: FetchType, rhs: FetchType) -> Bool {
        return lhs.identifier == rhs.identifier
    }
}
