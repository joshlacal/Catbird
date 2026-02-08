//
//  ProfileDisplayable.swift
//  Catbird
//
//  Created on 3/9/25.
//

import SwiftUI
import Petrel

/// Protocol for any profile-like object that can be displayed in a row
protocol ProfileDisplayable: Identifiable, Equatable, Hashable {
    var did: DID { get }
    var handle: Handle { get }
    var displayName: String? { get }
    var avatar: URI? { get }
    var pronouns: String? { get }
    var verification: AppBskyActorDefs.VerificationState? { get }

    func finalAvatarURL() -> URL?
}

// Default helpers
extension ProfileDisplayable {
    func finalAvatarURL() -> URL? { avatar?.url }
    var pronouns: String? { nil }
    var verification: AppBskyActorDefs.VerificationState? { nil }
}

/// Conformance for ProfileViewDetailed
extension AppBskyActorDefs.ProfileViewDetailed: ProfileDisplayable {}

/// Conformance for ProfileView
extension AppBskyActorDefs.ProfileView: ProfileDisplayable {}

/// Conformance for ProfileViewBasic
extension AppBskyActorDefs.ProfileViewBasic: ProfileDisplayable {}

#if os(iOS)
/// Conformance for ProfileViewBasic (from ChatBsky)
extension ChatBskyActorDefs.ProfileViewBasic: ProfileDisplayable {}
#endif

// MARK: - Retroactive Identifiable / Equatable / Hashable conformances

extension AppBskyActorDefs.ProfileViewDetailed: Identifiable {
    public var id: String { did.didString() }
}

extension AppBskyActorDefs.ProfileViewDetailed: Equatable {
    public static func == (lhs: AppBskyActorDefs.ProfileViewDetailed, rhs: AppBskyActorDefs.ProfileViewDetailed) -> Bool {
        lhs.did.didString() == rhs.did.didString()
    }
}

extension AppBskyActorDefs.ProfileViewDetailed: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(did.didString()) }
}

extension AppBskyActorDefs.ProfileView: Identifiable {
    public var id: String { did.didString() }
}

extension AppBskyActorDefs.ProfileView: Equatable {
    public static func == (lhs: AppBskyActorDefs.ProfileView, rhs: AppBskyActorDefs.ProfileView) -> Bool {
        lhs.did.didString() == rhs.did.didString()
    }
}

extension AppBskyActorDefs.ProfileView: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(did.didString()) }
}

extension AppBskyActorDefs.ProfileViewBasic: Identifiable {
    public var id: String { did.didString() }
}

extension AppBskyActorDefs.ProfileViewBasic: Equatable {
    public static func == (lhs: AppBskyActorDefs.ProfileViewBasic, rhs: AppBskyActorDefs.ProfileViewBasic) -> Bool {
        lhs.did.didString() == rhs.did.didString()
    }
}

extension AppBskyActorDefs.ProfileViewBasic: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(did.didString()) }
}

#if os(iOS)
extension ChatBskyActorDefs.ProfileViewBasic: Identifiable {
    public var id: String { did.didString() }
}

extension ChatBskyActorDefs.ProfileViewBasic: Equatable {
    public static func == (lhs: ChatBskyActorDefs.ProfileViewBasic, rhs: ChatBskyActorDefs.ProfileViewBasic) -> Bool {
        lhs.did.didString() == rhs.did.didString()
    }
}

extension ChatBskyActorDefs.ProfileViewBasic: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(did.didString()) }
}
#endif
