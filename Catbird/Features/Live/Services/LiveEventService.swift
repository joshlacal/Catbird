import Foundation
import Observation
import OSLog
import Petrel
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct LiveEventFeedLayout: Codable, Sendable, Equatable, Hashable {
    let title: String
    let overlayColor: String?
    let textColor: String?
    let image: String?
    let blurhash: String?

    init(
        title: String,
        overlayColor: String? = nil,
        textColor: String? = nil,
        image: String? = nil,
        blurhash: String? = nil
    ) {
        self.title = title
        self.overlayColor = overlayColor
        self.textColor = textColor
        self.image = image
        self.blurhash = blurhash
    }
}

struct LiveEventFeed: Codable, Sendable, Equatable, Hashable, Identifiable {
    let id: String
    let preview: Bool
    let title: String
    let url: String
    let layouts: [String: LiveEventFeedLayout]?

    init(
        id: String,
        preview: Bool = false,
        title: String,
        url: String,
        layouts: [String: LiveEventFeedLayout]? = nil
    ) {
        self.id = id
        self.preview = preview
        self.title = title
        self.url = url
        self.layouts = layouts
    }

    var wideLayout: LiveEventFeedLayout? {
        layouts?["wide"]
    }

    var compactLayout: LiveEventFeedLayout? {
        layouts?["compact"]
    }
}

struct LiveEventsWorkerResponse: Codable, Sendable {
    let feeds: [LiveEventFeed]

    init(feeds: [LiveEventFeed] = []) {
        self.feeds = feeds
    }
}

@Observable
@MainActor
final class LiveEventService {
    private let logger = Logger(subsystem: "blue.catbird", category: "LiveEventService")

    static let shared = LiveEventService()

    private(set) var rawFeeds: [LiveEventFeed] = []
    private(set) var hiddenFeedIds: Set<String> = []
    private(set) var hideAllFeeds: Bool = false
    private(set) var isLoading: Bool = false
    private(set) var lastFetchDate: Date?

    private var previousHiddenFeedIds: Set<String>?
    private var previousHideAllFeeds: Bool?
    nonisolated(unsafe) private var foregroundObserver: (any NSObjectProtocol)?

    private let endpointURL: URL
    private let urlSession: URLSession
    private weak var appState: AppState?

    var canUndo: Bool {
        previousHiddenFeedIds != nil || previousHideAllFeeds != nil
    }

    init(
        endpointURL: URL = URL(string: "https://live-events.workers.bsky.app/config")!,
        urlSession: URLSession = .shared,
        appState: AppState? = nil
    ) {
        self.endpointURL = endpointURL
        self.urlSession = urlSession
        self.appState = appState
    }

    deinit {
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func configure(with appState: AppState) {
        self.appState = appState
        self.previousHiddenFeedIds = nil
        self.previousHideAllFeeds = nil
        if foregroundObserver == nil {
            #if os(iOS)
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handleAppForeground()
                }
            }
            #elseif os(macOS)
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handleAppForeground()
                }
            }
            #endif
        }

        Task {
            await loadPreferences()
            await fetchLiveEvents()
        }
    }

    func handleAppForeground() async {
        logger.debug("App returned to foreground; checking live events")
        await fetchLiveEvents(force: false)
    }

    var activeEvents: [LiveEventFeed] {
        guard !hideAllFeeds else { return [] }

        let mutedWords = (try? appState?.preferencesManager.getLocalPreferences())?.mutedWords.map { $0.value.lowercased() } ?? []
        return rawFeeds.filter { feed in
            // Filter out preview events for non-preview accounts
            if feed.preview { return false }

            // Filter out hidden feed ids
            if hiddenFeedIds.contains(feed.id) { return false }

            // Filter out muted words in title or layouts
            let lowerTitle = feed.title.lowercased()
            for muted in mutedWords where !muted.isEmpty {
                if lowerTitle.contains(muted) { return false }
                if let wide = feed.wideLayout, wide.title.lowercased().contains(muted) { return false }
                if let compact = feed.compactLayout, compact.title.lowercased().contains(muted) { return false }
            }

            return true
        }
    }

    func fetchLiveEvents(force: Bool = false) async {
        if !force, let last = lastFetchDate, Date().timeIntervalSince(last) < 300 {
            logger.debug("Skipping fetch; cooldown active")
            return
        }

        isLoading = true
        defer { isLoading = false }

        let previousActiveEventIds = activeEvents.map(\.id)

        do {
            var request = URLRequest(url: endpointURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 10.0
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                logger.warning("Live events worker returned non-2xx response")
                return
            }

            let decoded = try JSONDecoder().decode(LiveEventsWorkerResponse.self, from: data)
            self.rawFeeds = decoded.feeds
            self.lastFetchDate = Date()
            logger.info("Fetched \(decoded.feeds.count) live events from worker")

            let newActiveEventIds = activeEvents.map(\.id)
            if previousActiveEventIds != newActiveEventIds {
                notifyActiveEventsChanged()
            }
        } catch {
            logger.warning("Live events fetch failed: \(error.localizedDescription); retaining previous cached response")
        }
    }

    func loadPreferences() async {
        guard let client = appState?.atProtoClient else {
            self.hiddenFeedIds = []
            self.hideAllFeeds = false
            self.previousHiddenFeedIds = nil
            self.previousHideAllFeeds = nil
            return
        }
        let previousActiveEventIds = activeEvents.map(\.id)
        do {
            let (_, prefs) = try await client.app.bsky.actor.getPreferences(input: .init())
            var loadedHidden = Set<String>()
            var loadedHideAll = false
            if let items = prefs?.preferences.items {
                for item in items {
                    if case .liveEventPreferences(let livePref) = item {
                        loadedHidden = Set(livePref.hiddenFeedIds ?? [])
                        loadedHideAll = livePref.hideAllFeeds ?? false
                    }
                }
            }
            self.hiddenFeedIds = loadedHidden
            self.hideAllFeeds = loadedHideAll
            self.previousHiddenFeedIds = nil
            self.previousHideAllFeeds = nil
            let newActiveEventIds = activeEvents.map(\.id)
            if previousActiveEventIds != newActiveEventIds {
                notifyActiveEventsChanged()
            }
        } catch {
            logger.warning("Failed to load live event preferences: \(error.localizedDescription)")
        }
    }

    func hideEvent(id: String) async throws {
        try await applyPreferences { hiddenFeedIds.insert(id) }
    }

    func hideAllEvents() async throws {
        try await applyPreferences { hideAllFeeds = true }
    }

    func undoLastHide() async throws {
        guard previousHiddenFeedIds != nil || previousHideAllFeeds != nil else { return }
        let previous = (hiddenFeedIds, hideAllFeeds)
        let target = (
            previousHiddenFeedIds ?? hiddenFeedIds,
            previousHideAllFeeds ?? hideAllFeeds
        )
        hiddenFeedIds = target.0
        hideAllFeeds = target.1
        previousHiddenFeedIds = nil
        previousHideAllFeeds = nil

        do {
            try await syncPreferences()
            notifyActiveEventsChanged()
        } catch {
            hiddenFeedIds = previous.0
            hideAllFeeds = previous.1
            previousHiddenFeedIds = target.0
            previousHideAllFeeds = target.1
            throw error
        }
    }

    /// Mutates the current hide state, persists it, and restores the previous
    /// state (dropping the undo snapshot) if syncing fails.
    private func applyPreferences(_ mutation: () -> Void) async throws {
        let prevHidden = hiddenFeedIds
        let prevHideAll = hideAllFeeds
        previousHiddenFeedIds = prevHidden
        previousHideAllFeeds = prevHideAll

        mutation()

        do {
            try await syncPreferences()
            notifyActiveEventsChanged()
        } catch {
            hiddenFeedIds = prevHidden
            hideAllFeeds = prevHideAll
            previousHiddenFeedIds = nil
            previousHideAllFeeds = nil
            throw error
        }
    }

    private func notifyActiveEventsChanged() {
        appState?.stateInvalidationBus.notifyFeedUpdated(.timeline)
        appState?.stateInvalidationBus.notify(.feedListChanged)
    }

    private func syncPreferences() async throws {
        guard let client = appState?.atProtoClient else { return }
        let livePref = AppBskyActorDefs.LiveEventPreferences(
            hiddenFeedIds: Array(hiddenFeedIds),
            hideAllFeeds: hideAllFeeds
        )
        let liveUnion = AppBskyActorDefs.PreferencesForUnionArray.liveEventPreferences(livePref)

        let (_, currentPrefs) = try await client.app.bsky.actor.getPreferences(input: .init())
        var updatedList = currentPrefs?.preferences.items.filter { pref in
            if case .liveEventPreferences = pref { return false }
            return true
        } ?? []

        updatedList.append(liveUnion)

        let input = AppBskyActorPutPreferences.Input(preferences: AppBskyActorDefs.Preferences(items: updatedList))
        _ = try await client.app.bsky.actor.putPreferences(input: input)
        logger.info("Successfully synced live event preferences")
    }
}
