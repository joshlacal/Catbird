//
//  ContentLabelView.swift
//  Catbird
//
//  Created by Claude on 5/12/25.
//

import SwiftUI
import Petrel
import Observation

enum PostRevealMotion {
    static func isLayoutAnimationEnabled(reduceMotion: Bool, voiceOverEnabled: Bool) -> Bool {
        !reduceMotion && !voiceOverEnabled
    }

    static func layoutAnimation(reduceMotion: Bool, voiceOverEnabled: Bool) -> Animation? {
        guard isLayoutAnimationEnabled(reduceMotion: reduceMotion, voiceOverEnabled: voiceOverEnabled) else {
            return nil
        }
        return .easeInOut(duration: 0.22)
    }
}

/// Visibility settings for different content categories
enum ContentVisibility: String, Codable, Identifiable, CaseIterable {
    case show = "ignore"  // AT Protocol uses "ignore" for showing content
    case warn = "warn"
    case hide = "hide"

    var id: String { rawValue }

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
}

/// Builtin label identifiers the trending topic preview treats as content
/// warnings. Post rendering and the settings screens use `ModerationPolicy`
/// and `ModerationPrefs` instead.
struct ContentLabels {
     static let adultContentLabels: Set<String> = ["nsfw", "porn", "sexual"]
     static let warningContentLabels: Set<String> = ["nudity", "gore", "violence", "graphic", "graphic-media", "corpse", "self-harm", "suggestive"]
     static let contentWarningLabels: Set<String> = adultContentLabels.union(warningContentLabels)
}

/// One compact, tappable row naming the alert and inform causes of a decision
/// (`PostAlerts` upstream). The causes a gate already shows are not passed in,
/// so a post never carries two warnings for the same label.
struct ContentLabelView: View {
    let causes: [ModerationCause]
    @State private var showsDetails = false

    private var names: [String] {
        var seen = Set<String>()
        return causes.map { ModerationPresentation.title(for: $0) }.filter { seen.insert($0).inserted }
    }

    var body: some View {
        if !causes.isEmpty {
            let names = self.names
            Button {
                showsDetails = true
            } label: {
                LabelChipFlowLayout {
                    ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                        LabelChip(title: name, systemImage: index == 0 ? "tag" : nil)
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The button stays the accessibility element, so VoiceOver announces a button and
            // activating it opens the details; a replacement element would drop both.
            .accessibilityLabel(Text("Post labels: \(names.joined(separator: ", "))"))
            .accessibilityHint("Shows label descriptions and who applied them")
            .accessibilityIdentifier("postLabelSummary")
            .sheet(isPresented: $showsDetails) {
                ModerationCauseDetailsView(causes: causes)
            }
        }
    }
}

/// Name, description and issuer of each cause. Labeler display names are
/// looked up only while the sheet is open.
struct ModerationCauseDetailsView: View {
    let causes: [ModerationCause]
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var services: ContentLabelDefinitionLookup.Services = [:]
    @State private var accountDID = ""

    var body: some View {
        NavigationStack {
            List(causes, id: \.key) { cause in
                VStack(alignment: .leading, spacing: 8) {
                    Text(ModerationPresentation.title(for: cause)).appFont(AppTextRole.headline)
                    let description = ModerationPresentation.description(for: cause.definition)
                    if !description.isEmpty {
                        Text(description).appFont(AppTextRole.body)
                    }
                    Text(attribution(for: cause))
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            .navigationTitle(String(localized: "Post Labels"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .task { await loadIssuerNames() }
            .onChange(of: appState.userDID) { _, value in
                if value != accountDID { dismiss() }
            }
        }
    }

    private func attribution(for cause: ModerationCause) -> String {
        switch cause.source {
        case .user:
            return String(localized: "Self-applied by the author")
        case .labeler(let did):
            if let creator = services[did]?.creator {
                let name = creator.displayName.flatMap { $0.isEmpty ? nil : $0 }
                return String(localized: "Issued by \(name.map { "\($0) (@\(creator.handle))" } ?? "@\(creator.handle)")")
            }
            return String(localized: "Issued by \(did)")
        }
    }

    @MainActor
    private func loadIssuerNames() async {
        accountDID = appState.userDID
        let account = appState.userDID
        guard let client = appState.atProtoClient else { return }
        let manager = appState.preferencesManager
        do {
            guard let preferences = try manager.confirmedFeedFilterPreferences() ?? manager.retainedLocalFeedFilterPreferences(),
                  preferences.accountDID == account else { return }
            let loaded = try await ContentLabelDefinitionLookup.subscribedServices(
                appState: appState, preferences: preferences, client: client)
            guard !Task.isCancelled, appState.userDID == account else { return }
            services = loaded
        } catch {
            // The DID stays as the attribution when display metadata is unavailable.
        }
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
        if !shouldFade {
            content
        } else {
            content
                .compositingGroup()
                .opacity(!hasAppeared ? 0 : 1)
                .onAppear {
                    guard !hasAppeared else { return }
                    #if os(iOS)
                    if CollectionViewCellResizeAnchor.isPerformingResize {
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                hasAppeared = true
                            }
                        }
                        return
                    }
                    #endif
                    withAnimation(.easeInOut(duration: 0.18)) {
                        hasAppeared = true
                    }
                }
        }
    }
}

extension View {
    @ViewBuilder
    func postRevealFade(isEnabled: Bool) -> some View {
        if isEnabled {
            modifier(PostRevealFadeModifier(isEnabled: isEnabled))
        } else {
            self
        }
    }
}
