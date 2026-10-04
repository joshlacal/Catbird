import Foundation
import SwiftUI
import SwiftData
import Observation
import OSLog
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// AppSettings manages all app-specific settings that aren't synced with the Bluesky server
@Observable final class AppSettings {
    enum PersistenceState: Equatable {
        case unavailable
        case ready
        case saving
        case saveFailed
    }

    /// The narrow local-store boundary also lets failure fixtures exercise the real manager.
    struct Persistence {
        var fetch: (ModelContext, String) throws -> AppSettingsModel?
        var save: (ModelContext) throws -> Void
        var isActiveAccount: @MainActor (String, AppSettings) -> Bool = { accountDID, settings in
            let lifecycle = AppStateManager.shared.lifecycle
            guard let active = lifecycle.appState else { return false }
            return lifecycle.userDID == accountDID && active.appSettings === settings
        }
        var scheduleSave: (@escaping () -> Void) -> Timer? = { action in
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in action() }
        }
        var standardDefaults: UserDefaults = .standard
        var sharedDefaults: UserDefaults = AppSettingsModel.sharedDefaults()
        // Production binds the account's drained work queue. Rejection keeps the effect pending.
        var startEffect: @MainActor (@escaping @MainActor () async -> Void) -> Bool = { _ in false }

        static let live = Persistence(
            fetch: { context, accountDID in
                let targetId = AppSettingsModel.settingsId(for: accountDID)
                let descriptor = FetchDescriptor<AppSettingsModel>(predicate: #Predicate { $0.id == targetId })
                return try context.fetch(descriptor).first
            },
            save: { try $0.save() }
        )
    }

    private let logger = Logger(subsystem: "blue.catbird", category: "AppSettings")
    private var modelContext: ModelContext?
    // These are detached copies. Failed writes cannot be autosaved by the shared context.
    private var settingsModel: AppSettingsModel?
    private var savedSettings: AppSettingsModel? {
        didSet { confirmedReadingSnapshotIdentity = UUID() }
    }
    private var confirmedReadingSnapshotIdentity = UUID()
    private var pendingDrafts: [String: AppSettingsModel] = [:]
    private var pendingBaselines: [String: AppSettingsModel] = [:]
    private struct PendingEffect {
        let identity = UUID()
        let description: String?
        let action: @MainActor () async -> Void
    }
    private var pendingEffects: [String: [String: PendingEffect]] = [:]
    private var admittedEffectIdentities: Set<UUID> = []
    private var startedEffectIdentities: [String: Set<UUID>] = [:]
    private var accountDID: String?
    private var suspendedAccountDID: String?
    private var generation: UInt64 = 0
    private var defaults = AppSettingsModel()
    private var isInitializing = true
    private var notificationDebounceTimer: Timer?
    private var accessibilityObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private(set) var systemAccessibility = SystemAccessibilitySnapshot()
    var persistence = Persistence.live
    private(set) var persistenceState: PersistenceState = .unavailable

    var canEditPersistedSettings: Bool {
        !isLocalChangesSuspended && (persistenceState == .ready || persistenceState == .saving)
    }

    var isLocalChangesSuspended: Bool { suspendedAccountDID != nil }

    /// Describes the retained attempt while controls show the last confirmed values.
    var pendingChangesDescription: String {
        guard let accountDID,
              let pending = pendingDrafts[accountDID] ?? settingsModel ?? savedSettings,
              let savedSettings = pendingBaselines[accountDID] ?? savedSettings else {
            return "Pending changes will be available after your saved settings load."
        }
        var changes: [String] = []
        func bool(_ title: String, _ path: KeyPath<AppSettingsModel, Bool>) {
            if pending[keyPath: path] != savedSettings[keyPath: path] {
                changes.append("\(title): \(pending[keyPath: path] ? "On" : "Off")")
            }
        }
        func string(_ title: String, _ path: KeyPath<AppSettingsModel, String>, _ names: [String: String] = [:]) {
            let value = pending[keyPath: path]
            if value != savedSettings[keyPath: path] {
                let display = names[value] ?? value
                changes.append("\(title): \(display)")
            }
        }
        string("Theme", \.theme, ["system": "Follow System", "light": "Light", "dark": "Dark"])
        string("Dark Mode Style", \.darkThemeMode, ["dim": "Dim", "black": "True Black", "pureBlack": "Pure Black"])
        string("Accent Color", \.accentColor, ["default": "Default", "twilight": "Twilight", "lavender": "Lavender", "sunrise": "Sunrise", "aurora": "Aurora", "dusk": "Dusk", "midnight": "Midnight"])
        string("Font Style", \.fontStyle, ["system": "System", "serif": "Serif", "rounded": "Rounded", "monospaced": "Monospaced"])
        string("Font Size", \.fontSize, ["small": "Small", "default": "Default", "large": "Large", "extraLarge": "Extra Large"])
        string("Line Spacing", \.lineSpacing, ["tight": "Tight", "normal": "Normal", "relaxed": "Relaxed"])
        string("Letter Spacing", \.letterSpacing, ["tight": "Tight", "normal": "Normal", "loose": "Loose"])
        bool("Use System Text Size", \.dynamicTypeEnabled)
        string("Maximum Text Size", \.maxDynamicTypeSize, ["system": "Full System Range", "xxLarge": "Extra Extra Large", "xxxLarge": "Extra Extra Extra Large", "accessibility1": "Accessibility Medium", "accessibility2": "Accessibility Large", "accessibility3": "Accessibility Extra Large", "accessibility4": "Accessibility Extra Extra Large", "accessibility5": "Accessibility Extra Extra Extra Large"])
        bool("Require Alt Text", \.requireAltText)
        bool("Larger Alt Text Badges", \.largerAltTextBadges)
        bool("Disable Haptics", \.disableHaptics)
        bool("Reduce Motion", \.reduceMotion)
        bool("Prefer Crossfade Transitions", \.prefersCrossfade)
        bool("Increase Contrast", \.increaseContrast)
        bool("Bold Text", \.boldText)
        if pending.displayScale != savedSettings.displayScale {
            changes.append("Display Scale: \(Int(pending.displayScale * 100))%")
        }
        bool("Show Reading Time Estimates", \.showReadingTimeEstimates)
        bool("Highlight Links", \.highlightLinks)
        string("Link Style", \.linkStyle, ["color": "Color", "underline": "Underline", "both": "Color and Underline"])
        bool("Confirm Before Actions", \.confirmBeforeActions)
        if pending.longPressDuration != savedSettings.longPressDuration {
            changes.append("Long Press Duration: \(pending.longPressDuration) seconds")
        }
        bool("Shake to Undo", \.shakeToUndo)
        bool("Credit Repost Discovery", \.enableViaAttribution)
        bool("Sensitive Content Scanning", \.sensitiveContentScanningEnabled)
        bool("Autoplay Videos", \.autoplayVideos)
        bool("Open Links in Catbird", \.useInAppBrowser)
        bool("Show Trending Topics", \.showTrendingTopics)
        bool("Show Trending Videos", \.showTrendingVideos)
        string("Thread Sort Order", \.threadSortOrder, ["hot": "Top", "top": "Top", "oldest": "Oldest First", "newest": "Newest First", "random": "Random"])
        bool("Prioritize Users I Follow", \.prioritizeFollowedUsers)
        bool("Threaded Replies", \.threadedReplies)
        bool("Show Hidden Posts", \.showHiddenPosts)
        bool("Show Saved Feed Samples", \.showSavedFeedSamples)
        for provider in ExternalMediaProvider.allCases where pending.consent(for: provider) != savedSettings.consent(for: provider) {
            changes.append("\(provider.displayName): \(pending.consent(for: provider).title)")
        }
        bool("Use External Players", \.useWebViewEmbeds)
        let languageName: (String) -> String = { code in
            code == "system" ? "System Default" : Locale.current.localizedString(forIdentifier: code) ?? code
        }
        string("App Language", \.appLanguage, [pending.appLanguage: languageName(pending.appLanguage)])
        string("Primary Language", \.primaryLanguage, [pending.primaryLanguage: languageName(pending.primaryLanguage)])
        if pending.contentLanguages != savedSettings.contentLanguages {
            changes.append("Content Languages: \(pending.contentLanguages.map(languageName).joined(separator: ", "))")
        }
        bool("Hide Other Languages", \.hideNonPreferredLanguages)
        bool("Show Language Indicators", \.showLanguageIndicators)
        bool("Logged-out Visibility", \.loggedOutVisibility)
        changes.append(contentsOf: (pendingEffects[accountDID] ?? [:]).sorted { $0.key < $1.key }.compactMap { $0.value.description })
        return changes.isEmpty ? "Your selected settings are waiting to be saved." : changes.joined(separator: "\n")
    }

    struct PendingChangesSummary: Equatable {
        let accountDID: String
        let description: String
        let persistenceState: PersistenceState
    }

    enum PendingDecision { case save, discard }
    enum PendingResolution: Equatable { case resolved, saveFailed, accountChanged, unavailable }

    enum AccountSwitchFlushFailure: LocalizedError, Equatable {
        case accountChanged, saveFailed, unfinishedChanges

        var errorDescription: String? {
            switch self {
            case .accountChanged:
                return "The original account could not be verified for its settings changes."
            case .saveFailed:
                return "Your local settings could not be saved. Retry saving or discard the pending changes before switching accounts."
            case .unfinishedChanges:
                return "Some settings changes still need to finish before you switch accounts. Return to Settings on the current account and try again."
            }
        }
    }

    private(set) var accountSwitchFlushFailure: AccountSwitchFlushFailure?

    struct ConfirmedReadingLanguages: Equatable, Sendable {
        fileprivate let identity: UUID
        let accountDID: String
        let primaryLanguage: String
        let contentLanguages: [String]
    }

    /// Explicit compatibility Retry may use only this account's immutable confirmed choice.
    @MainActor
    func confirmedReadingLanguages(for accountDID: String) -> ConfirmedReadingLanguages? {
        guard self.accountDID == accountDID, persistenceState == .ready,
              !isLocalChangesSuspended, pendingDrafts[accountDID] == nil,
              persistence.isActiveAccount(accountDID, self), let savedSettings else { return nil }
        return ConfirmedReadingLanguages(identity: confirmedReadingSnapshotIdentity, accountDID: accountDID,
            primaryLanguage: savedSettings.primaryLanguage, contentLanguages: savedSettings.contentLanguages)
    }

    var hasPendingChanges: Bool {
        guard let accountDID else { return false }
        return pendingDrafts[accountDID] != nil || !(pendingEffects[accountDID] ?? [:]).isEmpty
    }

    var pendingChangesSummary: PendingChangesSummary? {
        guard let accountDID, hasPendingChanges else { return nil }
        return PendingChangesSummary(accountDID: accountDID, description: pendingChangesDescription, persistenceState: persistenceState)
    }

    var effectiveReduceMotion: Bool {
        AccessibilityAccommodationPolicy.isEnabled(system: systemAccessibility.reduceMotion, app: reduceMotion)
    }

    var effectivePrefersCrossfade: Bool {
        AccessibilityAccommodationPolicy.usesCrossfade(system: systemAccessibility, reduceMotion: reduceMotion, prefersCrossfade: prefersCrossfade)
    }

    var effectiveIncreaseContrast: Bool {
        AccessibilityAccommodationPolicy.isEnabled(system: systemAccessibility.increaseContrast, app: increaseContrast)
    }

    var effectiveBoldText: Bool {
        AccessibilityAccommodationPolicy.isEnabled(system: systemAccessibility.boldText, app: boldText)
    }

    init() {
        #if os(iOS)
        let center = NotificationCenter.default
        let names = [UIAccessibility.reduceMotionStatusDidChangeNotification,
                     UIAccessibility.prefersCrossFadeTransitionsStatusDidChange,
                     UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
                     UIAccessibility.boldTextStatusDidChangeNotification]
        #elseif os(macOS)
        let center = NSWorkspace.shared.notificationCenter
        let names = [NSWorkspace.accessibilityDisplayOptionsDidChangeNotification]
        #endif
        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshSystemAccessibility() }
            }
            accessibilityObservers.append((center, observer))
        }
        Task { @MainActor [weak self] in self?.refreshSystemAccessibility() }
    }

    deinit {
        for (center, observer) in accessibilityObservers { center.removeObserver(observer) }
        notificationDebounceTimer?.invalidate()
    }

    @MainActor func refreshSystemAccessibility(_ snapshot: SystemAccessibilitySnapshot? = nil) {
        systemAccessibility = snapshot ?? .current
    }

    @MainActor
    func resolvePendingChanges(for accountDID: String, decision: PendingDecision) async -> PendingResolution {
        guard self.accountDID == accountDID else { return .accountChanged }
        guard !isLocalChangesSuspended else { return .unavailable }
        switch decision {
        case .save:
            guard modelContext != nil, savedSettings != nil else { return .unavailable }
            return persistPendingChanges(for: accountDID) ? .resolved : .saveFailed
        case .discard:
            guard hasPendingChanges else { return persistenceState == .ready ? .resolved : .unavailable }
            let confirmedDisplay = savedSettings ?? pendingBaselines[accountDID]
            generation &+= 1
            notificationDebounceTimer?.invalidate()
            notificationDebounceTimer = nil
            pendingDrafts.removeValue(forKey: accountDID)
            pendingBaselines.removeValue(forKey: accountDID)
            pendingEffects.removeValue(forKey: accountDID)
            settingsModel = confirmedDisplay.map { snapshot($0, accountDID: accountDID) }
            persistenceState = savedSettings == nil ? .unavailable : .ready
            return .resolved
        }
    }

    @discardableResult
    func persistPendingChanges(for accountDID: String) -> Bool {
        guard self.accountDID == accountDID, !isLocalChangesSuspended else { return false }
        return persistPendingChanges()
    }

    /// Close every ordinary edit path before the account switch's first suspension point.
    @MainActor @discardableResult
    func suspendLocalChanges(for accountDID: String) -> Bool {
        guard self.accountDID == accountDID,
              suspendedAccountDID == nil || suspendedAccountDID == accountDID else { return false }
        suspendedAccountDID = accountDID
        accountSwitchFlushFailure = nil
        generation &+= 1
        notificationDebounceTimer?.invalidate()
        notificationDebounceTimer = nil
        admittedEffectIdentities.removeAll()
        return true
    }

    /// The switch owner calls this synchronously after draining the account's actual work.
    @MainActor @discardableResult
    func flushPendingChangesForAccountSwitch(for accountDID: String) -> Bool {
        guard self.accountDID == accountDID, suspendedAccountDID == accountDID else {
            accountSwitchFlushFailure = .accountChanged
            return false
        }
        if pendingDrafts[accountDID] != nil, !persistPendingChanges(allowSuspended: true) {
            accountSwitchFlushFailure = .saveFailed
            return false
        }
        // Retirement would destroy this manager. A committed row alone cannot replace
        // a retained compatibility action, such as clearing the legacy language filter.
        guard (pendingEffects[accountDID] ?? [:]).isEmpty,
              (startedEffectIdentities[accountDID] ?? []).isEmpty else {
            accountSwitchFlushFailure = .unfinishedChanges
            return false
        }
        accountSwitchFlushFailure = nil
        return true
    }

    /// Reopen only the retained source that the lifecycle owner has verified as active.
    @MainActor @discardableResult
    func resumeLocalChanges(for accountDID: String) -> Bool {
        guard self.accountDID == accountDID, suspendedAccountDID == accountDID,
              persistence.isActiveAccount(accountDID, self) else { return false }
        suspendedAccountDID = nil
        generation &+= 1
        admittedEffectIdentities.removeAll()
        if pendingDrafts[accountDID] != nil, persistenceState == .saving {
            settingsModel = savedSettings.map { snapshot($0, accountDID: accountDID) }
            persistenceState = .saveFailed
        }
        publishSavedSettings(accountDID: accountDID, generation: generation, notify: true, allowPendingDraft: true)
        return true
    }

    /// A player may open only after the complete provider choice is committed.
    @MainActor @discardableResult
    func applyExternalMediaConsent(_ consent: ExternalMediaConsent, providers: [ExternalMediaProvider]) -> Bool {
        guard canEditPersistedSettings, let settingsModel, let accountDID,
              persistence.isActiveAccount(accountDID, self) else { return false }
        for provider in providers { settingsModel.setConsent(consent, for: provider) }
        saveChanges()
        return persistPendingChanges()
    }

    func configure(accountDID: String) {
        guard !isLocalChangesSuspended else { return }
        guard self.accountDID != accountDID else { return }
        generation &+= 1
        // Retain the originating account's attempt until Save or Discard resolves it.
        notificationDebounceTimer?.invalidate()
        notificationDebounceTimer = nil
        self.accountDID = accountDID
        modelContext = nil
        settingsModel = nil
        savedSettings = nil
        persistenceState = .unavailable
        isInitializing = true
    }

    func initialize(with modelContext: ModelContext, accountDID: String, notifyOnSuccess: Bool = false) {
        guard !isLocalChangesSuspended else { return }
        configure(accountDID: accountDID)
        generation &+= 1
        let attemptGeneration = generation
        notificationDebounceTimer?.invalidate()
        notificationDebounceTimer = nil
        self.modelContext = modelContext
        isInitializing = true
        let context = ModelContext(modelContext.container)
        context.autosaveEnabled = false
        do {
            let row: AppSettingsModel
            let existing = try persistence.fetch(context, accountDID)
            guard isCurrent(accountDID, generation: attemptGeneration) else { return }
            if let existing {
                row = existing
            } else {
                row = AppSettingsModel(accountDID: accountDID)
                if let legacy = try AppSettingsModel.legacySettingsForMigration(in: context) {
                    AppSettingsModel.copySettings(from: legacy, to: row)
                    context.delete(legacy)
                } else {
                    let allowLegacyFallback = try !AppSettingsModel.hasPerAccountSettings(in: context)
                    row.migrateFromUserDefaults(accountDID: accountDID, includeLegacyFallback: allowLegacyFallback, writeWidgetBackup: false, defaults: standardDefaults)
                }
                context.insert(row)
                try persistence.save(context)
            }
            guard isCurrent(accountDID, generation: attemptGeneration) else { return }
            savedSettings = snapshot(row, accountDID: accountDID)
            settingsModel = snapshot(row, accountDID: accountDID)
            // A repeat initialization must not silently discard a failed or debounced attempt.
            persistenceState = pendingDrafts[accountDID] == nil ? .ready : .saveFailed
            isInitializing = false
            // A successful reload confirms this snapshot even while an older edit awaits Retry Saving.
            saveThemeSettingsToUserDefaults(allowPendingDraft: true)
            publishSavedSettings(
                accountDID: accountDID, generation: attemptGeneration,
                notify: notifyOnSuccess, allowPendingDraft: true
            )
        } catch {
            guard isCurrent(accountDID, generation: attemptGeneration) else { return }
            settingsModel = savedSettings.map { snapshot($0, accountDID: accountDID) }
            persistenceState = .unavailable
            isInitializing = false
            logger.error("Local settings could not be loaded: \(error.localizedDescription)")
        }
    }

    func retryPersistence() {
        guard !isLocalChangesSuspended, let accountDID, let modelContext else { return }
        switch persistenceState {
        case .unavailable:
            initialize(with: modelContext, accountDID: accountDID, notifyOnSuccess: true)
        case .saveFailed:
            _ = persistPendingChanges()
        case .ready, .saving:
            break
        }
    }

    /// Coalesce effects by purpose; retries apply only the effect belonging to the retained draft.
    func afterPendingSave(key: String = "settings", description: String? = nil, _ action: @escaping @MainActor () async -> Void) {
        guard !isLocalChangesSuspended, let accountDID, pendingDrafts[accountDID] != nil else { return }
        pendingEffects[accountDID, default: [:]][key] = PendingEffect(description: description, action: action)
    }

    private func publishSavedSettings(
        accountDID: String, generation: UInt64, notify: Bool, allowPendingDraft: Bool = false
    ) {
        let confirmed = savedSettings
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(accountDID, generation: generation),
                  !self.isLocalChangesSuspended,
                  self.savedSettings === confirmed,
                  self.persistenceState == .ready || (allowPendingDraft && self.persistenceState == .saveFailed)
            else { return }
            if self.persistence.isActiveAccount(accountDID, self) {
                self.saveThemeSettingsToUserDefaults(writesActiveBackup: true, allowPendingDraft: allowPendingDraft)
                PlatformHaptics.isEnabled = HapticsPolicy.isEnabled(disableHaptics: confirmed?.disableHaptics ?? false)
            }
            if notify {
                NotificationCenter.default.post(
                    name: NSNotification.Name("AppSettingsChanged"), object: self,
                    userInfo: ["accountDID": accountDID]
                )
            }
            self.applyPendingEffects(accountDID: accountDID, generation: generation)
        }
    }

    @MainActor
    private func applyPendingEffects(accountDID: String, generation: UInt64) {
        for (key, effect) in pendingEffects[accountDID] ?? [:] {
            guard !isLocalChangesSuspended, isCurrent(accountDID, generation: generation),
                  persistenceState == .ready, persistence.isActiveAccount(accountDID, self),
                  !admittedEffectIdentities.contains(effect.identity) else { continue }
            admittedEffectIdentities.insert(effect.identity)
            let admitted = persistence.startEffect { @MainActor [weak self] in
                defer {
                    self?.admittedEffectIdentities.remove(effect.identity)
                    self?.startedEffectIdentities[accountDID]?.remove(effect.identity)
                }
                guard let self, self.isCurrent(accountDID, generation: generation),
                      !self.isLocalChangesSuspended,
                      self.persistenceState == .ready,
                      self.persistence.isActiveAccount(accountDID, self),
                      self.pendingEffects[accountDID]?[key]?.identity == effect.identity else { return }
                self.pendingEffects[accountDID]?.removeValue(forKey: key)
                self.startedEffectIdentities[accountDID, default: []].insert(effect.identity)
                await effect.action()
            }
            if !admitted { admittedEffectIdentities.remove(effect.identity) }
        }
    }

    /// Flush the current account's pending edit. Returns true only after a successful save.
    @discardableResult
    func persistPendingChanges() -> Bool {
        guard !isLocalChangesSuspended else { return false }
        return persistPendingChanges(allowSuspended: false)
    }

    private func persistPendingChanges(allowSuspended: Bool) -> Bool {
        guard allowSuspended || !isLocalChangesSuspended else { return false }
        guard let accountDID, let modelContext, let draft = pendingDrafts[accountDID] else {
            if !isLocalChangesSuspended, persistenceState == .ready, let accountDID {
                publishSavedSettings(accountDID: accountDID, generation: generation, notify: false)
            }
            return persistenceState == .ready
        }
        let attemptGeneration = generation
        notificationDebounceTimer?.invalidate()
        notificationDebounceTimer = nil
        let context = ModelContext(modelContext.container)
        context.autosaveEnabled = false
        do {
            guard let row = try persistence.fetch(context, accountDID) else {
                throw CocoaError(.persistentStoreOperation)
            }
            guard isCurrent(accountDID, generation: attemptGeneration) else { return false }
            AppSettingsModel.copySettings(from: draft, to: row, changedFrom: pendingBaselines[accountDID])
            try persistence.save(context)
            guard isCurrent(accountDID, generation: attemptGeneration) else { return false }
            savedSettings = snapshot(row, accountDID: accountDID)
            settingsModel = snapshot(row, accountDID: accountDID)
            pendingDrafts.removeValue(forKey: accountDID)
            pendingBaselines.removeValue(forKey: accountDID)
            persistenceState = .ready
            saveThemeSettingsToUserDefaults()
            publishSavedSettings(accountDID: accountDID, generation: attemptGeneration, notify: true)
            return true
        } catch {
            guard isCurrent(accountDID, generation: attemptGeneration) else { return false }
            // Drop the private context; only the detached attempted values survive for Retry.
            settingsModel = savedSettings.map { snapshot($0, accountDID: accountDID) }
            persistenceState = .saveFailed
            logger.error("Local settings were not saved: \(error.localizedDescription)")
            return false
        }
    }

    private func snapshot(_ source: AppSettingsModel, accountDID: String) -> AppSettingsModel {
        let copy = AppSettingsModel(accountDID: accountDID)
        AppSettingsModel.copySettings(from: source, to: copy)
        return copy
    }

    private func isCurrent(_ accountDID: String, generation: UInt64) -> Bool {
        self.accountDID == accountDID && self.generation == generation
    }

    private var standardDefaults: UserDefaults { persistence.standardDefaults }
    private var accountScopedDefaultsDID: String? { accountDID }
    private var shouldUseRuntimeLegacyFallback: Bool {
        AppSettingsModel.shouldUseLegacyFallback(for: accountScopedDefaultsDID, defaults: standardDefaults)
    }

    private func saveChanges() {
        guard !isInitializing, canEditPersistedSettings,
              let accountDID, let settingsModel else { return }
        if pendingBaselines[accountDID] == nil, let savedSettings {
            pendingBaselines[accountDID] = snapshot(savedSettings, accountDID: accountDID)
        }
        pendingDrafts[accountDID] = snapshot(settingsModel, accountDID: accountDID)
        persistenceState = .saving
        let attemptGeneration = generation
        notificationDebounceTimer?.invalidate()
        notificationDebounceTimer = persistence.scheduleSave { [weak self] in
            guard let self, self.isCurrent(accountDID, generation: attemptGeneration) else { return }
            self.persistPendingChanges()
        }
    }

    /// Save critical settings to UserDefaults as backup
    private func saveThemeSettingsToUserDefaults(writesActiveBackup: Bool = false, allowPendingDraft: Bool = false) {
        guard !writesActiveBackup || !isLocalChangesSuspended else { return }
        guard persistenceState == .ready || (allowPendingDraft && persistenceState == .saveFailed),
              let confirmed = savedSettings else { return }
        let theme = confirmed.theme
        let darkThemeMode = confirmed.darkThemeMode
        let accentColor = confirmed.accentColor
        let fontStyle = confirmed.fontStyle
        let fontSize = confirmed.fontSize
        let lineSpacing = confirmed.lineSpacing
        let letterSpacing = confirmed.letterSpacing
        let dynamicTypeEnabled = confirmed.dynamicTypeEnabled
        let maxDynamicTypeSize = confirmed.maxDynamicTypeSize
        let useWebViewEmbeds = confirmed.useWebViewEmbeds
        let defaults = standardDefaults
        if writesActiveBackup {
            AppSettingsModel.markActiveSettingsAccount(accountScopedDefaultsDID, defaults: defaults)
        }

        // The global/widget backup belongs only to the active account.
        if writesActiveBackup {
        // Save theme settings
        defaults.set(theme, forKey: "theme")
        defaults.set(darkThemeMode, forKey: "darkThemeMode")
        defaults.set(accentColor, forKey: "accentColor")
        
        // Save font settings for reliability
        defaults.set(fontStyle, forKey: "fontStyle")
        defaults.set(fontSize, forKey: "fontSize")
        defaults.set(lineSpacing, forKey: "lineSpacing")
        defaults.set(letterSpacing, forKey: "letterSpacing")
        defaults.set(dynamicTypeEnabled, forKey: "dynamicTypeEnabled")
        defaults.set(maxDynamicTypeSize, forKey: "maxDynamicTypeSize")
        
        // Save webview settings for persistence
        defaults.set(useWebViewEmbeds, forKey: "useWebViewEmbeds")
        for provider in ExternalMediaProvider.allCases {
            let consent = confirmed.consent(for: provider)
            defaults.set(consent.rawValue, forKey: "externalMediaConsent.\(provider.rawValue)")
        }
        }
        if let accountDID = accountScopedDefaultsDID {
            let accountScopedThemeKeys = [
                ("theme", theme),
                ("darkThemeMode", darkThemeMode),
                ("accentColor", accentColor),
                ("fontStyle", fontStyle),
                ("fontSize", fontSize),
                ("lineSpacing", lineSpacing),
                ("letterSpacing", letterSpacing),
                ("maxDynamicTypeSize", maxDynamicTypeSize),
            ]

            for (key, value) in accountScopedThemeKeys {
                defaults.set(value, forKey: AppSettingsModel.scopedKey(key, accountDID: accountDID))
            }

            let accountScopedBoolKeys: [(String, Bool)] = [
                ("dynamicTypeEnabled", dynamicTypeEnabled),
                ("useWebViewEmbeds", useWebViewEmbeds),
            ]
            for provider in ExternalMediaProvider.allCases {
                let consent = confirmed.consent(for: provider)
                defaults.set(
                    consent.rawValue,
                    forKey: AppSettingsModel.scopedKey("externalMediaConsent.\(provider.rawValue)", accountDID: accountDID)
                )
            }

            for (key, value) in accountScopedBoolKeys {
                defaults.set(value, forKey: AppSettingsModel.scopedKey(key, accountDID: accountDID))
            }
        }
        
        // Also save to app group for widgets
        if writesActiveBackup {
            let groupDefaults = persistence.sharedDefaults
            groupDefaults.set(theme, forKey: "theme")
            groupDefaults.set(darkThemeMode, forKey: "darkThemeMode")
        }
        
        logger.debug("Settings saved to UserDefaults: theme=\(self.theme), darkMode=\(self.darkThemeMode), webViewEmbeds=\(self.useWebViewEmbeds)")
    }
    
    /// Load theme settings from UserDefaults if SwiftData is not available
    private func loadThemeSettingsFromUserDefaults() -> (theme: String, darkThemeMode: String) {
        let defaults = standardDefaults
        let savedTheme = AppSettingsModel.stringValue(
            for: "theme",
            accountDID: accountScopedDefaultsDID,
            defaults: defaults,
            includeLegacyFallback: shouldUseRuntimeLegacyFallback
        ) ?? "system"
        let savedDarkMode = AppSettingsModel.stringValue(
            for: "darkThemeMode",
            accountDID: accountScopedDefaultsDID,
            defaults: defaults,
            includeLegacyFallback: shouldUseRuntimeLegacyFallback
        ) ?? "dim"
        
        return (theme: savedTheme, darkThemeMode: savedDarkMode)
    }
    
    /// Load font settings from UserDefaults if SwiftData is not available
    private func loadFontSettingsFromUserDefaults() -> (fontStyle: String, fontSize: String, lineSpacing: String, letterSpacing: String, dynamicTypeEnabled: Bool, maxDynamicTypeSize: String) {
        let defaults = standardDefaults
        
        let savedFontStyle = AppSettingsModel.stringValue(for: "fontStyle", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? "system"
        let savedFontSize = AppSettingsModel.stringValue(for: "fontSize", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? "default"
        let savedLineSpacing = AppSettingsModel.stringValue(for: "lineSpacing", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? "normal"
        let savedLetterSpacing = AppSettingsModel.stringValue(for: "letterSpacing", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? "normal"
        let savedDynamicTypeEnabled = AppSettingsModel.boolValue(for: "dynamicTypeEnabled", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? true
        let savedMaxDynamicTypeSize = AppSettingsModel.stringValue(for: "maxDynamicTypeSize", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? "accessibility1"
        
        return (
            fontStyle: savedFontStyle,
            fontSize: savedFontSize,
            lineSpacing: savedLineSpacing,
            letterSpacing: savedLetterSpacing,
            dynamicTypeEnabled: savedDynamicTypeEnabled,
            maxDynamicTypeSize: savedMaxDynamicTypeSize
        )
    }
    
    /// Load webview settings from UserDefaults if SwiftData is not available
    private func loadWebViewSettingsFromUserDefaults() -> (useWebViewEmbeds: Bool, placeholder: Void) {
        let defaults = standardDefaults
        let savedUseWebViewEmbeds = AppSettingsModel.boolValue(for: "useWebViewEmbeds", accountDID: accountScopedDefaultsDID, defaults: defaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? true
        return (
            useWebViewEmbeds: savedUseWebViewEmbeds,
            placeholder: ()
        )
    }
    // MARK: - Computed Properties
    
    // Appearance
    var theme: String {
        get { 
            // Try SwiftData first, then UserDefaults fallback
            if let theme = settingsModel?.theme {
                return theme
            }
            return loadThemeSettingsFromUserDefaults().theme
        }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.theme = newValue
            saveChanges()
        }
    }
    
    var darkThemeMode: String {
        get {
            // Try SwiftData first, then UserDefaults fallback
            if let darkMode = settingsModel?.darkThemeMode {
                return darkMode
            }
            return loadThemeSettingsFromUserDefaults().darkThemeMode
        }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.darkThemeMode = newValue
            saveChanges()
        }
    }

    var accentColor: String {
        get {
            if let settingsModel = settingsModel {
                return settingsModel.accentColor
            }
            return AppSettingsModel.stringValue(
                for: "accentColor",
                accountDID: accountScopedDefaultsDID,
                defaults: standardDefaults,
                includeLegacyFallback: shouldUseRuntimeLegacyFallback
            ) ?? "default"
        }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.accentColor = newValue
            saveChanges()
        }
    }
    
    var fontStyle: String {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.fontStyle
            }
            return loadFontSettingsFromUserDefaults().fontStyle
        }
        set {
            guard canEditPersistedSettings else { return }
            if let settingsModel = settingsModel {
                settingsModel.fontStyle = newValue
            }
            saveChanges()
        }
    }
    
    var fontSize: String {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.fontSize
            }
            return loadFontSettingsFromUserDefaults().fontSize
        }
        set {
            guard canEditPersistedSettings else { return }
            if let settingsModel = settingsModel {
                settingsModel.fontSize = newValue
            }
            saveChanges()
        }
    }
    
    var lineSpacing: String {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.lineSpacing
            }
            return loadFontSettingsFromUserDefaults().lineSpacing
        }
        set {
            guard canEditPersistedSettings else { return }
            if let settingsModel = settingsModel {
                settingsModel.lineSpacing = newValue
            }
            saveChanges()
        }
    }
    
    var letterSpacing: String {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.letterSpacing
            }
            return loadFontSettingsFromUserDefaults().letterSpacing
        }
        set {
            guard canEditPersistedSettings else { return }
            if let settingsModel = settingsModel {
                settingsModel.letterSpacing = newValue
            }
            saveChanges()
        }
    }
    
    var dynamicTypeEnabled: Bool {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.dynamicTypeEnabled
            }
            return loadFontSettingsFromUserDefaults().dynamicTypeEnabled
        }
        set {
            guard canEditPersistedSettings else { return }
            if let settingsModel = settingsModel {
                settingsModel.dynamicTypeEnabled = newValue
            }
            saveChanges()
        }
    }
    
    var maxDynamicTypeSize: String {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.maxDynamicTypeSize
            }
            return loadFontSettingsFromUserDefaults().maxDynamicTypeSize
        }
        set {
            guard canEditPersistedSettings else { return }
            if let settingsModel = settingsModel {
                settingsModel.maxDynamicTypeSize = newValue
            }
            saveChanges()
        }
    }
    
    // Accessibility
    var requireAltText: Bool {
        get { settingsModel?.requireAltText ?? defaults.requireAltText }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.requireAltText = newValue
            saveChanges()
        }
    }
    
    var largerAltTextBadges: Bool {
        get { settingsModel?.largerAltTextBadges ?? defaults.largerAltTextBadges }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.largerAltTextBadges = newValue
            saveChanges()
        }
    }
    
    var disableHaptics: Bool {
        get { settingsModel?.disableHaptics ?? defaults.disableHaptics }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.disableHaptics = newValue
            saveChanges()
        }
    }

    // Motion Settings
    var reduceMotion: Bool {
        get { settingsModel?.reduceMotion ?? defaults.reduceMotion }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.reduceMotion = newValue
            saveChanges()
        }
    }
    
    var prefersCrossfade: Bool {
        get { settingsModel?.prefersCrossfade ?? defaults.prefersCrossfade }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.prefersCrossfade = newValue
            saveChanges()
        }
    }
    
    // Display Settings
    var increaseContrast: Bool {
        get { settingsModel?.increaseContrast ?? defaults.increaseContrast }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.increaseContrast = newValue
            saveChanges()
        }
    }
    
    var boldText: Bool {
        get { settingsModel?.boldText ?? defaults.boldText }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.boldText = newValue
            saveChanges()
        }
    }
    
    var displayScale: Double {
        get { settingsModel?.displayScale ?? defaults.displayScale }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.displayScale = newValue
            saveChanges()
        }
    }
    
    // Reading Settings
    var showReadingTimeEstimates: Bool {
        get { settingsModel?.showReadingTimeEstimates ?? defaults.showReadingTimeEstimates }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.showReadingTimeEstimates = newValue
            saveChanges()
        }
    }
    
    var highlightLinks: Bool {
        get { settingsModel?.highlightLinks ?? defaults.highlightLinks }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.highlightLinks = newValue
            saveChanges()
        }
    }
    
    var linkStyle: String {
        get { settingsModel?.linkStyle ?? defaults.linkStyle }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.linkStyle = newValue
            saveChanges()
        }
    }
    
    // Interaction Settings
    var confirmBeforeActions: Bool {
        get { settingsModel?.confirmBeforeActions ?? defaults.confirmBeforeActions }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.confirmBeforeActions = newValue
            saveChanges()
        }
    }
    
    var longPressDuration: Double {
        get { settingsModel?.longPressDuration ?? defaults.longPressDuration }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.longPressDuration = newValue
            saveChanges()
        }
    }
    
    var shakeToUndo: Bool {
        get { settingsModel?.shakeToUndo ?? defaults.shakeToUndo }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.shakeToUndo = newValue
            saveChanges()
        }
    }
    
    // Attribution Settings
    var enableViaAttribution: Bool {
        get { settingsModel?.enableViaAttribution ?? defaults.enableViaAttribution }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.enableViaAttribution = newValue
            saveChanges()
        }
    }
    
    // Content and Media
    var sensitiveContentScanningEnabled: Bool {
        get { settingsModel?.sensitiveContentScanningEnabled ?? defaults.sensitiveContentScanningEnabled }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.sensitiveContentScanningEnabled = newValue
            saveChanges()
        }
    }

    var autoplayVideos: Bool {
        get { settingsModel?.autoplayVideos ?? defaults.autoplayVideos }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.autoplayVideos = newValue
            saveChanges()
        }
    }
    
    var useInAppBrowser: Bool {
        get { settingsModel?.useInAppBrowser ?? defaults.useInAppBrowser }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.useInAppBrowser = newValue
            saveChanges()
        }
    }
    
    var showTrendingTopics: Bool {
        get { settingsModel?.showTrendingTopics ?? defaults.showTrendingTopics }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.showTrendingTopics = newValue
            saveChanges()
        }
    }
    
    var showTrendingVideos: Bool {
        get { settingsModel?.showTrendingVideos ?? defaults.showTrendingVideos }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.showTrendingVideos = newValue
            saveChanges()
        }
    }
    
    // Thread Preferences
    var threadSortOrder: String {
        get { settingsModel?.threadSortOrder ?? defaults.threadSortOrder }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.threadSortOrder = newValue
            saveChanges()
        }
    }
    
    var prioritizeFollowedUsers: Bool {
        get { settingsModel?.prioritizeFollowedUsers ?? defaults.prioritizeFollowedUsers }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.prioritizeFollowedUsers = newValue
            saveChanges()
        }
    }
    
    var threadedReplies: Bool {
        get { settingsModel?.threadedReplies ?? defaults.threadedReplies }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.threadedReplies = newValue
            saveChanges()
        }
    }
    
    var showHiddenPosts: Bool {
        get { settingsModel?.showHiddenPosts ?? defaults.showHiddenPosts }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.showHiddenPosts = newValue
            saveChanges()
        }
    }
    
    // Feed Preferences
    var showSavedFeedSamples: Bool {
        get { settingsModel?.showSavedFeedSamples ?? defaults.showSavedFeedSamples }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.showSavedFeedSamples = newValue
            saveChanges()
        }
    }
    // MARK: - External Media Preferences
    func externalMediaConsent(for provider: ExternalMediaProvider) -> ExternalMediaConsent {
        if let settingsModel = settingsModel {
            return settingsModel.consent(for: provider)
        }
        return loadExternalMediaConsentFromUserDefaults(for: provider)
    }

    func setExternalMediaConsent(_ consent: ExternalMediaConsent, for provider: ExternalMediaProvider) {
        guard canEditPersistedSettings else { return }
        settingsModel?.setConsent(consent, for: provider)
        saveChanges()
    }

    func setExternalMediaConsentForAllProviders(_ consent: ExternalMediaConsent) {
        for provider in ExternalMediaProvider.allCases {
            setExternalMediaConsent(consent, for: provider)
        }
    }

    private func loadExternalMediaConsentFromUserDefaults(for provider: ExternalMediaProvider) -> ExternalMediaConsent {
        let key = "externalMediaConsent.\(provider.rawValue)"
        if let raw = AppSettingsModel.stringValue(
            for: key,
            accountDID: accountScopedDefaultsDID,
            defaults: standardDefaults,
            includeLegacyFallback: false
        ), let consent = ExternalMediaConsent(rawValue: raw) {
            return consent
        }
        return .undecided
    }
    
    // WebView Embeds
    var useWebViewEmbeds: Bool {
        get { 
            if let settingsModel = settingsModel {
                return settingsModel.useWebViewEmbeds
            }
            return loadWebViewSettingsFromUserDefaults().useWebViewEmbeds
        }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.useWebViewEmbeds = newValue
            saveChanges()
        }
    }
    

    // Languages
    var appLanguage: String {
        get { settingsModel?.appLanguage ?? defaults.appLanguage }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.appLanguage = newValue
            saveChanges()
        }
    }
    
    var primaryLanguage: String {
        get { settingsModel?.primaryLanguage ?? defaults.primaryLanguage }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.primaryLanguage = newValue
            saveChanges()
        }
    }
    
    var contentLanguages: [String] {
        get { settingsModel?.contentLanguages ?? defaults.contentLanguages }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.contentLanguages = newValue
            saveChanges()
        }
    }
    
    var hideNonPreferredLanguages: Bool {
        get { settingsModel?.hideNonPreferredLanguages ?? defaults.hideNonPreferredLanguages }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.hideNonPreferredLanguages = newValue
            saveChanges()
        }
    }
    
    var showLanguageIndicators: Bool {
        get { settingsModel?.showLanguageIndicators ?? defaults.showLanguageIndicators }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.showLanguageIndicators = newValue
            saveChanges()
        }
    }
    
    // Privacy
    var loggedOutVisibility: Bool {
        get { settingsModel?.loggedOutVisibility ?? defaults.loggedOutVisibility }
        set {
            guard canEditPersistedSettings else { return }
            settingsModel?.loggedOutVisibility = newValue
            saveChanges()
        }
    }

    // Developer Settings
    
    
    // MARK: - Public Methods
    
    /// Reset only the visual choices managed by Appearance, preserving accessibility and account data.
    func resetAppearanceToDefaults() {
        guard canEditPersistedSettings else { return }
        settingsModel?.resetAppearanceToDefaults()
        saveChanges()
    }

    /// Reset all settings to defaults
    func resetToDefaults() {
        guard canEditPersistedSettings, let settingsModel else { return }
        // Keep the existing broad-reset exclusions without its eager UserDefaults writes.
        let reset = AppSettingsModel()
        reset.letterSpacing = settingsModel.letterSpacing
        reset.sensitiveContentScanningEnabled = settingsModel.sensitiveContentScanningEnabled
        AppSettingsModel.copySettings(from: reset, to: settingsModel)
        saveChanges()
    }
    
    /// Apply initial theme settings even before SwiftData is fully initialized
    /// This ensures theme is applied immediately on app startup
    func applyInitialThemeSettings(to themeManager: ThemeManager) {
        // Temporarily set isInitializing to true to prevent notification loops
        let wasInitializing = isInitializing
        isInitializing = true
        defer { isInitializing = wasInitializing }
        
        let themeSettings = loadThemeSettingsFromUserDefaults()
        
        logger.info("Applying initial theme settings from UserDefaults: theme=\(themeSettings.theme), darkMode=\(themeSettings.darkThemeMode)")
        
        let savedAccentColor = AppSettingsModel.stringValue(
            for: "accentColor",
            accountDID: accountScopedDefaultsDID,
            defaults: standardDefaults
        ) ?? "default"
        themeManager.applyTheme(
            theme: themeSettings.theme,
            darkThemeMode: themeSettings.darkThemeMode,
            accentColor: savedAccentColor
        )

        // Keep the legacy global backup aligned with the active account so early launch
        // reads (such as navigation font bootstrap) use the most recently active profile.
        saveThemeSettingsToUserDefaults()
    }
    
    /// Apply initial font settings immediately from UserDefaults if SwiftData is not available
    /// This ensures fonts are applied immediately on app startup
    func applyInitialFontSettings(to fontManager: FontManager) {
        // Temporarily set isInitializing to true to prevent notification loops
        let wasInitializing = isInitializing
        isInitializing = true
        defer { isInitializing = wasInitializing }
        
        // Create a temporary AppSettingsModel to get all current settings
        let currentSettings = AppSettingsModel()
        
        // Load settings from UserDefaults if SwiftData isn't available yet
        if settingsModel == nil {
            let fontSettings = loadFontSettingsFromUserDefaults()
            currentSettings.fontStyle = fontSettings.fontStyle
            currentSettings.fontSize = fontSettings.fontSize
            currentSettings.lineSpacing = fontSettings.lineSpacing
            currentSettings.letterSpacing = fontSettings.letterSpacing
            currentSettings.dynamicTypeEnabled = fontSettings.dynamicTypeEnabled
            currentSettings.maxDynamicTypeSize = fontSettings.maxDynamicTypeSize
            currentSettings.boldText = AppSettingsModel.boolValue(for: "boldText", accountDID: accountScopedDefaultsDID, defaults: standardDefaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? defaults.boldText
            currentSettings.increaseContrast = AppSettingsModel.boolValue(for: "increaseContrast", accountDID: accountScopedDefaultsDID, defaults: standardDefaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? defaults.increaseContrast
            currentSettings.displayScale = AppSettingsModel.doubleValue(for: "displayScale", accountDID: accountScopedDefaultsDID, defaults: standardDefaults, includeLegacyFallback: shouldUseRuntimeLegacyFallback) ?? defaults.displayScale
        } else {
            // Copy from existing settings model
            if let model = settingsModel {
                currentSettings.fontStyle = model.fontStyle
                currentSettings.fontSize = model.fontSize
                currentSettings.lineSpacing = model.lineSpacing
                currentSettings.letterSpacing = model.letterSpacing
                currentSettings.dynamicTypeEnabled = model.dynamicTypeEnabled
                currentSettings.maxDynamicTypeSize = model.maxDynamicTypeSize
                currentSettings.boldText = model.boldText
                currentSettings.increaseContrast = model.increaseContrast
                currentSettings.displayScale = model.displayScale
            }
        }
        
        logger.info("Applying initial font and accessibility settings: style=\(currentSettings.fontStyle), size=\(currentSettings.fontSize), spacing=\(currentSettings.lineSpacing), bold=\(currentSettings.boldText), contrast=\(currentSettings.increaseContrast), scale=\(currentSettings.displayScale)")
        
        fontManager.applyAllFontSettings(from: currentSettings)
    }
}

// MARK: - AppState Extension
extension AppState {
    struct AppSettingsKey: EnvironmentKey {
        static let defaultValue = AppSettings()
    }
}

extension EnvironmentValues {
    var appSettings: AppSettings {
        get { self[AppState.AppSettingsKey.self] }
        set { self[AppState.AppSettingsKey.self] = newValue }
    }
}
