//
//  ExperimentalSettings.swift
//  Catbird
//
//  Settings for experimental features that are not yet ready for general use.
//  Features gated here may have bugs, missing functionality, or data loss risks.
//

import SwiftUI
import OSLog

/// Global settings manager for experimental features
/// Features here are considered "highly experimental" and require explicit opt-in
@Observable
final class ExperimentalSettings {
    static let shared = ExperimentalSettings()
    
    private let logger = Logger(subsystem: "blue.catbird", category: "ExperimentalSettings")

    /// Storage key for AppView draft sync opt-in
    private static let draftSyncEnabledKey = "blue.catbird.draftSync.enabled"

    private init() {}

    // MARK: - Draft Sync (AppView-stored drafts)

    /// Whether composer drafts are synced to the Bluesky AppView (app.bsky.draft.*).
    /// Defaults to OFF as a current-main safety gate; an explicit opt-in is
    /// required even though the translation and synchronization path exists.
    var draftSyncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.draftSyncEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.draftSyncEnabledKey)
            logger.info("Draft sync \(newValue ? "enabled" : "disabled")")
        }
    }
}
