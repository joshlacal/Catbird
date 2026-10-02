//
//  StarterPackDraft.swift
//  Catbird
//
//  Created for Bluesky social app parity (WS-H / G57).
//

import Foundation
import Petrel

/// Draft model for creating or editing a starter pack.
public struct StarterPackDraft: Sendable, Equatable {
    public static let maxNameLength: Int = 50
    public static let maxDescriptionLength: Int = 300
    public static let minProfilesCount: Int = 1
    public static let maxProfilesCount: Int = 150
    public static let maxFeedsCount: Int = 3
    
    public var name: String
    public var description: String
    public var profiles: [AppBskyActorDefs.ProfileViewBasic]
    public var feeds: [AppBskyFeedDefs.GeneratorView]
    
    public init(
        name: String = "",
        description: String = "",
        profiles: [AppBskyActorDefs.ProfileViewBasic] = [],
        feeds: [AppBskyFeedDefs.GeneratorView] = []
    ) {
        self.name = name
        self.description = description
        self.profiles = profiles
        self.feeds = feeds
    }
    
    // MARK: - Validation
    
    public var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    public var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    public var isNameValid: Bool {
        let count = trimmedName.count
        return count >= 1 && count <= Self.maxNameLength
    }
    
    public var isDescriptionValid: Bool {
        description.count <= Self.maxDescriptionLength
    }
    
    public var isProfilesValid: Bool {
        profiles.count >= Self.minProfilesCount && profiles.count <= Self.maxProfilesCount
    }
    
    public var isFeedsValid: Bool {
        feeds.count <= Self.maxFeedsCount
    }
    
    public var isValid: Bool {
        isNameValid && isDescriptionValid && isProfilesValid && isFeedsValid
    }
    
    public var validationError: String? {
        if trimmedName.isEmpty {
            return "Name cannot be empty."
        }
        if trimmedName.count > Self.maxNameLength {
            return "Name must be \(Self.maxNameLength) characters or fewer."
        }
        if description.count > Self.maxDescriptionLength {
            return "Description must be \(Self.maxDescriptionLength) characters or fewer."
        }
        if profiles.count < Self.minProfilesCount {
            return "Please select at least \(Self.minProfilesCount) profile."
        }
        if profiles.count > Self.maxProfilesCount {
            return "Maximum of \(Self.maxProfilesCount) profiles allowed."
        }
        if feeds.count > Self.maxFeedsCount {
            return "Maximum of \(Self.maxFeedsCount) feeds allowed."
        }
        return nil
    }
    
    // MARK: - Mutating Helpers
    
    public mutating func addProfile(_ profile: AppBskyActorDefs.ProfileViewBasic) -> Bool {
        guard profiles.count < Self.maxProfilesCount else { return false }
        guard !profiles.contains(where: { $0.did == profile.did }) else { return false }
        profiles.append(profile)
        return true
    }
    
    public mutating func removeProfile(did: DID) {
        profiles.removeAll(where: { $0.did == did })
    }
    
    public mutating func addFeed(_ feed: AppBskyFeedDefs.GeneratorView) -> Bool {
        guard feeds.count < Self.maxFeedsCount else { return false }
        guard !feeds.contains(where: { $0.uri == feed.uri }) else { return false }
        feeds.append(feed)
        return true
    }
    
    public mutating func removeFeed(uri: ATProtocolURI) {
        feeds.removeAll(where: { $0.uri == uri })
    }
}
