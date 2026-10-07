//
//  ContentLabelView.swift
//  Catbird
//
//  Created by Claude on 5/12/25.
//

import SwiftUI
import Petrel
import Observation

/// Visibility settings for different content categories
enum ContentVisibility: String, Codable, Identifiable, CaseIterable {
    case show = "ignore"  // AT Protocol uses "ignore" for showing content
    case warn = "warn"
    case hide = "hide"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .show: return "Show"
        case .warn: return "Warn"
        case .hide: return "Hide"
        }
    }
    
    var iconName: String {
        switch self {
        case .show: return "eye"
        case .warn: return "eye.trianglebadge.exclamationmark"
        case .hide: return "eye.slash"
        }
    }
    
    var color: Color {
        switch self {
        case .show: return .green
        case .warn: return .orange
        case .hide: return .red
        }
    }
    
    /// Initialize from AT Protocol preference value
    init(fromPreference value: String) {
        switch value.lowercased() {
        case "ignore":
            self = .show
        case "warn":
            self = .warn
        case "hide":
            self = .hide
        default:
            self = .warn  // Default to warn for unknown values
        }
    }
    
    /// Convert to AT Protocol preference value
    var preferenceValue: String {
        switch self {
        case .show: return "ignore"
        case .warn: return "warn"
        case .hide: return "hide"
        }
    }
}

/// Helper function to get friendly label name
private func friendlyLabelName(_ labelKey: String) -> String {
    switch labelKey.lowercased() {
    case "nsfw", "porn":
        return "Adult Content"
    case "sexual":
        return "Sexual Content"
    case "suggestive":
        return "Sexually Suggestive"
    case "graphic", "gore":
        return "Graphic Content"
    case "violence":
        return "Violence"
    case "nudity":
        return "Non-Sexual Nudity"
    case "spam":
        return "Spam"
    case "misleading":
        return "Misleading"
    case "misinfo":
        return "Misinformation"
    case "hate":
        return "Hateful Content"
    case "harassment":
        return "Harassment"
    case "self-harm":
        return "Self-Harm"
    case "intolerant":
        return "Intolerance"
    default:
        // Capitalize and replace hyphens/underscores with spaces
        return labelKey.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

/// The rendered record, kept separate from labels on its author's profile.
struct PostLabelSubject {
    let uri: String
    let cid: CID
    let authorDID: String
    let authorHandle: String

    func labelIDs(in labels: [ComAtprotoLabelDefs.Label]?) -> Set<String> {
        Set((labels ?? []).filter {
            ReportingService.isLabelActive($0) && !$0.val.hasPrefix("!")
                && $0.uri.uriString() == uri && ($0.cid == nil || $0.cid == cid)
        }.map(\.id))
    }
}

private struct PostLabelSummaryIDsKey: EnvironmentKey {
    static let defaultValue: Set<String> = []
}

extension EnvironmentValues {
    var postLabelSummaryIDs: Set<String> {
        get { self[PostLabelSummaryIDsKey.self] }
        set { self[PostLabelSummaryIDsKey.self] = newValue }
    }
}

private struct PostLabelDisplayItem: Identifiable {
    let id: String
    let name: String
    let description: String?
    let issuer: String
    let isSelfApplied: Bool
}

/// A neutral, wrapping summary. Visibility policy stays in ContentLabelManager.
struct ContentLabelView: View {
    let labels: [ComAtprotoLabelDefs.Label]?
    var selfLabelValues: [String] = []
    var subject: PostLabelSubject? = nil

    @Environment(AppState.self) private var appState
    @State private var labelers: ContentLabelDefinitionLookup.Services = [:]
    @State private var subscribedIssuers: Set<String> = []
    @State private var metadataAccount = ""
    @State private var metadataClient: ObjectIdentifier?
    @State private var refresh = UUID()
    @State private var selectedDetails: DetailsSelection?

    private struct DetailsSelection: Identifiable {
        let id = UUID()
        let accountDID: String
    }

    private var metadataRequest: [String] {
        [appState.userDID, appState.atProtoClient.map { String(describing: ObjectIdentifier($0)) } ?? "",
         subject?.uri ?? "", subject?.cid.description ?? "", refresh.uuidString]
        + (labels ?? []).map(\.id).sorted() + selfLabelValues.sorted()
    }

    private var hasCurrentMetadata: Bool {
        metadataAccount == appState.userDID
            && metadataClient == appState.atProtoClient.map { ObjectIdentifier($0) }
    }

    private func isDisplayValue(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("!")
    }

    private var displayItems: [PostLabelDisplayItem] {
        // Until preferences load, only the default moderation service and the author are known issuers.
        let issuers = hasCurrentMetadata ? subscribedIssuers : Set([ReportingService.officialBlueskyDID])
        let services = hasCurrentMetadata ? labelers : [:]
        var seen = Set<String>()
        var selfValues = Set<String>()
        var result: [PostLabelDisplayItem] = []
        for label in labels ?? [] {
            guard ReportingService.isLabelActive(label), isDisplayValue(label.val) else { continue }
            if let subject {
                guard label.uri.uriString() == subject.uri,
                      label.cid == nil || label.cid == subject.cid else { continue }
            }
            let isSelf = subject.map { label.src.didString() == $0.authorDID } ?? false
            guard isSelf || issuers.contains(label.src.didString()) else { continue }
            let identity = label.id
            guard seen.insert(identity).inserted else { continue }
            let info = AccountLabelPresentation(label: label, labeler: services[label.src.didString()])
            let publishedName = services[label.src.didString()]?.policies.labelValueDefinitions?
                .first { $0.identifier == label.val }
                .flatMap { AccountLabelPresentation.localizedStrings($0.locales, preferredLanguages: Locale.preferredLanguages)?.name }
            let name = publishedName.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                ?? Self.fallbackName(label.val)
            result.append(PostLabelDisplayItem(id: identity, name: name, description: info.description,
                issuer: isSelf ? Self.authorAttribution(subject) : info.issuer, isSelfApplied: isSelf))
            if isSelf { selfValues.insert(label.val) }
        }
        for value in selfLabelValues where isDisplayValue(value) && selfValues.insert(value).inserted {
            result.append(PostLabelDisplayItem(id: "self|\(subject?.uri ?? "")|\(value)",
                name: Self.fallbackName(value), description: nil,
                issuer: Self.authorAttribution(subject), isSelfApplied: true))
        }
        return result
    }

    private static func authorAttribution(_ subject: PostLabelSubject?) -> String {
        guard let subject else { return String(localized: "Post author") }
        return subject.authorHandle.isEmpty ? subject.authorDID : "@\(subject.authorHandle)"
    }

    private static func fallbackName(_ value: String) -> String {
        switch value {
        case "porn", "nsfw": return String(localized: "Adult Content")
        case "sexual": return String(localized: "Sexually Suggestive")
        case "nudity": return String(localized: "Non-Sexual Nudity")
        case "graphic-media", "graphic", "gore": return String(localized: "Graphic Media")
        default: return value
        }
    }

    var body: some View {
        let items = displayItems
        let request = metadataRequest
        var seenNames = Set<String>()
        let names = items.map(\.name).filter { seenNames.insert($0).inserted }
        Group {
            if !items.isEmpty {
                Button {
                    selectedDetails = DetailsSelection(accountDID: appState.userDID)
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "tag")
                            .accessibilityHidden(true)
                        Text(names.joined(separator: " · "))
                            .lineLimit(nil)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(Color.secondary)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(subject == nil
                    ? Text("Content labels: \(names.joined(separator: ", "))")
                    : Text("Post labels: \(names.joined(separator: ", "))"))
                .accessibilityHint("Shows label descriptions and who applied them")
                .accessibilityIdentifier("postLabelSummary")
            }
        }
        .task(id: request) { await loadMetadata(for: request) }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FeedPreferencesChanged"))) { notification in
            if let account = notification.userInfo?["accountDID"] as? String, account != appState.userDID { return }
            refresh = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: PreferencesManager.acceptLabelersHeaderDidChange)) { notification in
            guard notification.userInfo?["accountDID"] as? String == appState.userDID else { return }
            refresh = UUID()
        }
        .onChange(of: metadataRequest) { _, _ in selectedDetails = nil }
        .sheet(item: $selectedDetails) { selection in
            PostLabelDetailsView(items: displayItems, accountDID: selection.accountDID, isPost: subject != nil)
        }
    }

    @MainActor
    private func loadMetadata(for request: [String]) async {
        guard !Task.isCancelled, request == metadataRequest else { return }
        guard (labels ?? []).contains(where: { ReportingService.isLabelActive($0) && isDisplayValue($0.val) }) else { return }
        let account = appState.userDID
        let client = appState.atProtoClient
        let manager = appState.preferencesManager
        labelers = [:]
        subscribedIssuers = []
        metadataAccount = ""
        metadataClient = nil
        do {
            guard let preferences = try manager.confirmedFeedFilterPreferences() ?? manager.retainedLocalFeedFilterPreferences(),
                  preferences.accountDID == account else { return }
            guard !Task.isCancelled, request == metadataRequest, appState.userDID == account,
                  appState.atProtoClient === client, manager.accountDID == account else { return }
            subscribedIssuers = Set(try ContentLabelDefinitionLookup.subscribedLabelerDIDs(preferences).map { $0.didString() })
            metadataAccount = account
            metadataClient = client.map { ObjectIdentifier($0) }
            guard let client else { return }
            let services = try await ContentLabelDefinitionLookup.subscribedServices(
                appState: appState, preferences: preferences, client: client)
            guard !Task.isCancelled, request == metadataRequest, appState.userDID == account,
                  appState.atProtoClient === client, manager.accountDID == account else { return }
            labelers = services
        } catch {
            // Keep exact identifiers and issuer DIDs when published display metadata is unavailable.
        }
    }
}

private struct PostLabelDetailsView: View {
    let items: [PostLabelDisplayItem]
    let accountDID: String
    let isPost: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            List(items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.name).appFont(AppTextRole.headline)
                    if let description = item.description, !description.isEmpty {
                        Text(description).appFont(AppTextRole.body)
                    }
                    Group {
                        if item.isSelfApplied {
                            Text("Self-applied by \(item.issuer)")
                        } else {
                            Text("Issued by \(item.issuer)")
                        }
                    }
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            .navigationTitle(isPost ? String(localized: "Post Labels") : String(localized: "Content Labels"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: appState.userDID) { _, value in
                if value != accountDID { dismiss() }
            }
        }
    }
}

struct ContentLabels {
    // Content-warning labels that should influence visibility (blur/hide)
     static let adultContentLabels: Set<String> = ["nsfw", "porn", "sexual"]
     static let warningContentLabels: Set<String> = ["nudity", "gore", "violence", "graphic", "graphic-media", "corpse", "self-harm", "suggestive"]
     static let contentWarningLabels: Set<String> = adultContentLabels.union(warningContentLabels)
}

/// A view that handles display decisions for labeled content
struct ContentLabelManager<Content: View>: View {

    let labels: [ComAtprotoLabelDefs.Label]?
    // Optional: additional self-applied label values (e.g., from record selfLabels)
    // Also presented as self-applied labels in the read-only summary.
    let selfLabelValues: [String]?
    let contentType: String
    let selfLabelsAlreadyShown: Bool
    let onReveal: (() -> Void)?
    let visibilityResolver: (@MainActor ([ComAtprotoLabelDefs.Label], [String]) async -> ContentVisibility)?
    @State private var isBlurred: Bool
    @State private var contentVisibility: ContentVisibility
    @State private var visibilityRequest = UUID()
    @Environment(AppState.self) private var appState
    @Environment(\.postLabelSummaryIDs) private var postLabelSummaryIDs
    let content: Content
    
    init(labels: [ComAtprotoLabelDefs.Label]?, selfLabelValues: [String]? = nil, contentType: String = "content", selfLabelsAlreadyShown: Bool = false, onReveal: (() -> Void)? = nil, visibilityResolver: (@MainActor ([ComAtprotoLabelDefs.Label], [String]) async -> ContentVisibility)? = nil, @ViewBuilder content: () -> Content) {
        self.labels = labels
        self.selfLabelValues = selfLabelValues
        self.contentType = contentType
        self.selfLabelsAlreadyShown = selfLabelsAlreadyShown
        self.onReveal = onReveal
        self.visibilityResolver = visibilityResolver
        self.content = content()
        // Use a more conservative initial visibility that will be updated by async task
        let initialVisibility = ContentLabelManager.getInitialContentVisibility(
            labels: labels, selfLabelValues: selfLabelValues
        )
        self._contentVisibility = State(initialValue: initialVisibility)
        self._isBlurred = State(initialValue: initialVisibility == .warn)
    }
    
    private var summaryLabels: [ComAtprotoLabelDefs.Label]? {
        labels?.filter { !postLabelSummaryIDs.contains($0.id) }
    }

    private var summarySelfLabels: [String] {
        selfLabelsAlreadyShown ? [] : (selfLabelValues ?? [])
    }

    /// Conservative initial visibility determination without user preferences
    /// This is used before async preference loading completes
    static func getInitialContentVisibility(
        labels: [ComAtprotoLabelDefs.Label]?, selfLabelValues: [String]? = nil
    ) -> ContentVisibility {
        // Apply the same conservative policy to record self-labels before async
        // preferences resolve, so media cannot appear briefly without its warning.
        let labelValues = ((labels ?? []).map(\.val) + (selfLabelValues ?? []))
            .map { $0.lowercased() }
            .filter { ContentLabels.contentWarningLabels.contains($0) }

        // Ignore labels that are not content warnings
        guard !labelValues.isEmpty else { return .show }

        // Check for sensitive content labels - be conservative and hide adult content initially
        if labelValues.contains(where: { ContentLabels.adultContentLabels.contains($0) }) {
            return .hide // Conservative default - will be updated by async task if user has adult content enabled
        }

        if labelValues.contains(where: { ContentLabels.warningContentLabels.contains($0) }) {
            return .warn
        }

        return .show
    }

    /// Legacy method - kept for compatibility but prefer getInitialContentVisibility for new code
    static func getContentVisibility(labels: [ComAtprotoLabelDefs.Label]?) -> ContentVisibility {
        guard let labels = labels, !labels.isEmpty else { return .show }

        // Check for the most restrictive content type first
        let labelValues = labels.map { $0.val.lowercased() }.filter { ContentLabels.contentWarningLabels.contains($0) }

        // No warning-eligible labels present
        guard !labelValues.isEmpty else { return .show }

        // Check for sensitive content labels and return appropriate visibility
        // This is the basic sync version - for full preference checking, use getEffectiveContentVisibility
        if labelValues.contains(where: { ContentLabels.contentWarningLabels.contains($0) }) {
            return .warn
        }

        return .show
    }
    
    static func shouldInitiallyBlur(labels: [ComAtprotoLabelDefs.Label]?) -> Bool {
        return getInitialContentVisibility(labels: labels) == .warn
    }
    
    /// Generate a friendly title for the warning
    private var warningTitle: String {
        guard let labels = labels, !labels.isEmpty else {
            return "Sensitive Content"
        }
        
        // If single label, use its friendly name
        if labels.count == 1 {
            return friendlyLabelName(labels[0].val)
        }
        
        // Multiple labels - use generic title
        return "Sensitive Content"
    }
    
    /// Generate a comma-separated list of friendly label names for warning text
    private var warningLabels: String {
        var allLabels: [String] = []
        
        if let labels = labels {
            allLabels.append(contentsOf: labels.map { friendlyLabelName($0.val) })
        }
        
        if let selfLabelValues = selfLabelValues {
            allLabels.append(contentsOf: selfLabelValues.map { friendlyLabelName($0) })
        }
        
        guard !allLabels.isEmpty else {
            return "sensitive material"
        }
        
        // Deduplicate
        let uniqueLabels = Array(Set(allLabels)).sorted()
        
        if uniqueLabels.count == 1 {
            return uniqueLabels[0].lowercased()
        } else if uniqueLabels.count == 2 {
            return uniqueLabels.joined(separator: " and ").lowercased()
        } else {
            let last = uniqueLabels.last!
            let rest = uniqueLabels.dropLast().joined(separator: ", ")
            return "\(rest), and \(last)".lowercased()
        }
    }
    
    private var strongBlurOverlay: some View {
        Rectangle()
            .fill(Color.black.opacity(0.95))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                VStack(spacing: 0) {
                    Image(systemName: "eye.slash.fill")
                        .appFont(AppTextRole.title2)
                        .foregroundStyle(.white)
                        .padding(.bottom, 4)

                    Text(warningTitle)
                        .appFont(AppTextRole.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.bottom, 4)

                    Text("May contain \(warningLabels)")
                        .appFont(AppTextRole.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.bottom, 12)

                    Button(action: revealContent) {
                        Text("Show Content")
                            .appFont(AppTextRole.footnote)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.gray.opacity(0.6))
                            .cornerRadius(18)
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.8))
                )
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
    }
    
    var body: some View {
        Group {
            switch contentVisibility {
            case .hide:
                // Completely hide content - show a minimal placeholder
                hiddenContentPlaceholder
                
            case .warn:
                VStack(alignment: .leading, spacing: 6) {
                    // Always show labels at the top - direct visibility
                    if summaryLabels?.isEmpty == false || !summarySelfLabels.isEmpty {
                        ContentLabelView(labels: summaryLabels, selfLabelValues: summarySelfLabels)
                            .padding(.bottom, 6)
                    }
                    
                    // Content with conditional blur
                    if isBlurred {
                        ZStack {
                            // Placeholder instead of actual content to avoid rendering videos/GIFs under overlay
                            Rectangle()
                                .fill(Color(platformColor: .platformSystemGray6))
                                .frame(minHeight: 200)

                            strongBlurOverlay
                        }
                        .onTapGesture(perform: revealContent)
                    } else {
                        // When revealed under warn, allow collapsing again to a compact placeholder
                        VStack(alignment: .leading, spacing: 6) {
                            content
                                .postRevealFade(isEnabled: true)
                                .overlay(alignment: .topTrailing) {
                                    HStack(spacing: 8) {
                                        if labels != nil && !labels!.isEmpty {
                                            // Reblur button
                                            Button {
                                                isBlurred = true
                                            } label: {
                                                Image(systemName: "eye.slash")
                                                    .appFont(AppTextRole.caption)
                                                    .frame(minWidth: 28, minHeight: 28)
                                                    .background(Color.black.opacity(0.6), in: Capsule())
                                                    .foregroundStyle(.white)
                                            }
                                        }
                                        // Collapse button
                                        Button {
                                            contentVisibility = .hide
                                        } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: "chevron.up.square")
                                                Text("Collapse")
                                            }
                                            .appFont(AppTextRole.caption)
                                            .padding(.horizontal, 10)
                                            .frame(minHeight: 28)
                                            .background(Color.black.opacity(0.6), in: Capsule())
                                            .foregroundStyle(.white)
                                        }
                                    }
                                    .padding(12)
                                }
                        }
                    }
                }
                
            case .show:
                // Show content normally with labels always visible at top
                VStack(alignment: .leading, spacing: 6) {
                    if summaryLabels?.isEmpty == false || !summarySelfLabels.isEmpty {
                        ContentLabelView(labels: summaryLabels, selfLabelValues: summarySelfLabels)
                            .padding(.bottom, 6)
                    }
                    content
                }
            }
        }
        .task(id: appState.userDID) {
            // Update visibility immediately when view appears and after account changes.
            await updateContentVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FeedPreferencesChanged"))) { notification in
            if let account = notification.userInfo?["accountDID"] as? String, account != appState.userDID { return }
            Task { await updateContentVisibility() }
        }
    }

    private func revealContent() {
        guard isBlurred else { return }
        isBlurred = false
        onReveal?()
    }
    
    private var hiddenContentPlaceholder: some View {
        VStack(spacing: 8) {
            // Show labels at the top so users know why content was hidden
            if summaryLabels?.isEmpty == false || !summarySelfLabels.isEmpty {
                ContentLabelView(labels: summaryLabels, selfLabelValues: summarySelfLabels)
                    .padding(.bottom, 8)
            }
            
            Image(systemName: "eye.slash.fill")
                .appFont(AppTextRole.title2)
                .foregroundStyle(.secondary)
            
            Text("Content Hidden")
                .appFont(AppTextRole.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            
            // Use a @State variable to track if user is minor for UI updates
            SettingsHiddenText(contentType: contentType)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 140)
        .background(Color(platformColor: .platformSystemGray6))
        .cornerRadius(12)
    }
    
    private func updateContentVisibility() async {
        let request = UUID()
        visibilityRequest = request
        let account = appState.userDID
        let client = appState.atProtoClient
        // Consider both canonical labels and any self-applied label values.
        let visibility: ContentVisibility
        if let visibilityResolver {
            visibility = await visibilityResolver(labels ?? [], selfLabelValues ?? [])
        } else {
            visibility = await getEffectiveContentVisibility(for: labels ?? [], selfLabelValues: selfLabelValues ?? [])
        }
        guard !Task.isCancelled, visibilityRequest == request, appState.userDID == account,
              appState.atProtoClient === client else { return }
        await MainActor.run {
            // Retain a user's reveal when a refresh produces the same warning policy.
            if self.contentVisibility != visibility {
                self.contentVisibility = visibility
                self.isBlurred = (visibility == .warn)
            }
        }
    }

    private func getEffectiveContentVisibility(for labels: [ComAtprotoLabelDefs.Label], selfLabelValues: [String]) async -> ContentVisibility {
        let visibleLabels = labels.filter {
            ContentLabels.contentWarningLabels.contains($0.val.lowercased())
              || (!$0.val.hasPrefix("!") && ReportingService.isLabelActive($0))
        }
        let visibleSelfLabels = selfLabelValues.filter { ContentLabels.contentWarningLabels.contains($0.lowercased()) }

        // If no warning-eligible labels exist, show content normally
        if visibleLabels.isEmpty && visibleSelfLabels.isEmpty {
            return .show
        }

        // Check each label and find the most restrictive setting
        var mostRestrictive: ContentVisibility = .show

        // Evaluate canonical labels
        for label in visibleLabels {
            let visibility = await getVisibilityForLabel(label)
            switch (mostRestrictive, visibility) {
            case (_, .hide):
                mostRestrictive = .hide
            case (.show, .warn):
                mostRestrictive = .warn
            default:
                break
            }
        }

        // Evaluate self-applied label values (no src)
        for value in visibleSelfLabels {
            let visibility = await getVisibilityForLabelValue(value)
            switch (mostRestrictive, visibility) {
            case (_, .hide):
                mostRestrictive = .hide
            case (.show, .warn):
                mostRestrictive = .warn
            default:
                break
            }
        }
        
        return mostRestrictive
    }

    private func getVisibilityForLabel(_ label: ComAtprotoLabelDefs.Label) async -> ContentVisibility {
        let normalizedValue = label.val.lowercased()

        // Builtin policy, including existing adult/nudity/suggestive gates, stays unchanged.
        guard ContentLabels.contentWarningLabels.contains(normalizedValue) else {
            return await getVisibilityForCustomLabel(label)
        }

        do {
            let preferences = try await appState.preferencesManager.getPreferences()

            // Map label values to preference keys
            let preferenceKey: String
            switch normalizedValue {
            case "nsfw", "porn", "sexual":
                preferenceKey = "nsfw"
            case "nudity":
                preferenceKey = "nudity"
            case "gore", "violence", "graphic", "graphic-media":
                preferenceKey = "graphic"
            case "suggestive":
                preferenceKey = "suggestive"
            default:
                preferenceKey = label.val.lowercased()
            }
            
            // If adult content is disabled, force hide NSFW content
            if preferenceKey == "nsfw" && !appState.isAdultContentEnabled {
                return .hide
            }
            
            // Get specific preference, preferring labeler-scoped when available
            let visibility = ContentFilterManager.getVisibilityForLabel(
                label: preferenceKey,
                labelerDid: label.src,
                preferences: preferences.contentLabelPrefs)
            
            return visibility
        } catch {
            // If we can't get preferences, use safe defaults
            if !appState.isAdultContentEnabled && ["nsfw", "porn", "sexual"].contains(label.val.lowercased()) {
                return .hide
            }
            return .warn
        }
    }

    private func getVisibilityForCustomLabel(_ label: ComAtprotoLabelDefs.Label) async -> ContentVisibility {
        guard ReportingService.isLabelActive(label), !label.val.hasPrefix("!") else { return .show }
        let account = appState.userDID
        let manager = appState.preferencesManager
        let client = appState.atProtoClient
        do {
            let preferences = try await manager.getPreferences()
            guard appState.userDID == account, appState.atProtoClient === client else { return .show }
            let explicitPreferences = preferences.contentLabelPrefs
            var definition: ComAtprotoLabelDefs.LabelValueDefinition?
            if let client, (try? ContentLabelDefinitionLookup.subscribedLabelerDIDs(preferences))?.contains(label.src) == true {
                do {
                    let definitions = try await ContentLabelDefinitionLookup.subscribedDefinitions(
                      appState: appState, preferences: preferences, client: client)
                    definition = definitions[label.src.didString()]?.first { $0.identifier == label.val }
                } catch {
                    // Exact stored overrides remain usable; failed metadata invents no inherited policy.
                }
            }
            guard !Task.isCancelled, appState.userDID == account, appState.atProtoClient === client else { return .show }
            return CustomContentLabelPolicy.visibility(labelValue: label.val, labelerDID: label.src,
              preferences: explicitPreferences, definition: definition, contentType: contentType,
              isActive: true) ?? .show
        } catch { return .show }
    }

    private func getVisibilityForLabelValue(_ value: String) async -> ContentVisibility {
        let normalizedValue = value.lowercased()

        // Skip labels that are not content warnings
        guard ContentLabels.contentWarningLabels.contains(normalizedValue) else {
            return .show
        }

        do {
            let preferences = try await appState.preferencesManager.getPreferences()
            // Map value to preference key
            let preferenceKey: String
            switch normalizedValue {
            case "nsfw", "porn", "sexual":
                preferenceKey = "nsfw"
            case "nudity":
                preferenceKey = "nudity"
            case "gore", "violence", "graphic", "graphic-media":
                preferenceKey = "graphic"
            case "suggestive":
                preferenceKey = "suggestive"
            default:
                preferenceKey = value.lowercased()
            }
            if preferenceKey == "nsfw" && !appState.isAdultContentEnabled { return .hide }
            let visibility = ContentFilterManager.getVisibilityForLabel(
                label: preferenceKey,
                labelerDid: nil,
                preferences: preferences.contentLabelPrefs
            )
            return visibility
        } catch {
            if !appState.isAdultContentEnabled && ["nsfw", "porn", "sexual"].contains(value.lowercased()) {
                return .hide
            }
            return .warn
        }
    }
}

// Helper text when content is hidden by settings
struct SettingsHiddenText: View {
    let contentType: String
    var body: some View {
        Text("This \(contentType) was hidden based on your content settings")
            .appFont(AppTextRole.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
    }
}

/// Fades only a newly revealed branch. Concealment removes content immediately.
/// Child media keeps its identity and receives no layout animation transaction.
private struct PostRevealFadeModifier: ViewModifier {
    let isEnabled: Bool
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var hasAppeared = false

    private var shouldFade: Bool {
        isEnabled && !voiceOverEnabled
            && (!appState.appSettings.effectiveReduceMotion || appState.appSettings.effectivePrefersCrossfade)
    }

    func body(content: Content) -> some View {
        content
            .animation(nil, value: hasAppeared)
            .opacity(shouldFade && !hasAppeared ? 0 : 1)
            .animation(shouldFade ? .easeInOut(duration: 0.18) : nil, value: hasAppeared)
            .onAppear { hasAppeared = true }
    }
}

extension View {
    func postRevealFade(isEnabled: Bool) -> some View {
        modifier(PostRevealFadeModifier(isEnabled: isEnabled))
    }
}
