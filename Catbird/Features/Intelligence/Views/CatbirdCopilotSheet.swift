import SwiftUI
import Petrel

struct CatbirdCopilotSheet: View {
  @Environment(SceneNavigationContext.self) private var sceneContext
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let context: CopilotContext
    let imageModerationSource: CopilotImageModerationSource?
    var onConfirmedAction: ((CopilotProposal) async throws -> Void)?
    var onDedicatedAction: ((CopilotProposal) -> Void)?

    @State private var conversationID: UUID = UUID()
    @State private var conversationAccountDID: String = ""
    @State private var turns: [CopilotStoredTurn] = []
    @State private var prompt: String = ""
    @State private var isResponding: Bool = false
    @State private var activeStreamTask: Task<Void, Never>? = nil
    @State private var streamingUserTurnID: UUID? = nil
    @State private var streamingAssistantTurnID: UUID? = nil
    @State private var isExecutingProposal: Bool = false
    @State private var errorMessage: String? = nil
    @State private var contextTrimmedNotice: String? = nil
    @State private var route: CopilotModelRoute = .onDevice
    @State private var confirmingClearAll: Bool = false
    @State private var exactContextConversations: [CopilotConversation] = []
    @State private var navigationPath = NavigationPath()
    @State private var selectedTab: Int = 0
    @State private var successMessage: String? = nil
    @State private var selectedImageID: String?
    @State private var imageRevealSession = CopilotImageRevealSession()
    @State private var imageUnavailableReason: String?
    @State private var historySession = AskCatbirdHistorySession()
    private var unavailableMessage: String? { CopilotAvailability.unavailableMessage }

    init(
        context: CopilotContext,
        imageModerationSource: CopilotImageModerationSource? = nil,
        onConfirmedAction: ((CopilotProposal) async throws -> Void)? = nil,
        onDedicatedAction: ((CopilotProposal) -> Void)? = nil
    ) {
        self.context = context
        self.imageModerationSource = imageModerationSource
        self.onConfirmedAction = onConfirmedAction
        self.onDedicatedAction = onDedicatedAction
    }

    private var hasUnresolvedProposal: Bool {
        turns.contains { $0.proposal != nil }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                AskCatbirdTranscript(
                    context: context,
                    turns: turns,
                    streamingTurnID: streamingAssistantTurnID,
                    unavailableMessage: unavailableMessage,
                    onRetry: refreshAvailability,
                    onSuggestion: { prompt = $0 },
                    onSource: routeSource
                ) { turn in
                    if let proposal = turn.proposal {
                        proposalCard(proposal: proposal, forTurnID: turn.id)
                    }
                }

                if let contextTrimmedNotice {
                    noticeBanner(text: contextTrimmedNotice, icon: "info.circle", color: .secondary) {
                        self.contextTrimmedNotice = nil
                    }
                }

                if let successMessage {
                    noticeBanner(text: successMessage, icon: "checkmark.circle.fill", color: .green) {
                        self.successMessage = nil
                    }
                }

                if let errorMessage {
                    noticeBanner(text: errorMessage, icon: "exclamationmark.triangle.fill", color: .red) {
                        self.errorMessage = nil
                    }
                }

                if !context.imageCandidates.isEmpty {
                    CopilotImageModerationNotice(snapshot: imageModerationSnapshot,
                        reveal: effectiveImageReveal, onReveal: revealImages, onHide: hideImages)
                }

                AskCatbirdComposer(
                    text: $prompt,
                    selectedImageID: $selectedImageID,
                    candidates: permittedImageCandidates,
                    imageUnavailableReason: imageUnavailableReason,
                    isResponding: isResponding,
                    isDisabled: hasUnresolvedProposal || unavailableMessage != nil,
                    hasUnresolvedProposal: hasUnresolvedProposal,
                    onSend: { Task { await send(promptText: prompt) } },
                    onStop: stopGeneration
                )
            }
            .modifier(AskCatbirdURLRouting(onOpenURL: { sceneContext.urlHandler.handle($0) }))
            .navigationTitle("Ask Catbird")
            .platformInlineNavigationTitle()
            .navigationDestination(for: NavigationDestination.self) { destination in
                NavigationHandler.viewForDestination(
                    destination,
                    path: $navigationPath,
                    appState: appState,
                    selectedTab: $selectedTab
                )
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }

                ToolbarItem(placement: .primaryAction) {
                    historyMenu
                }
            }
            .task(id: ContextIdentity(accountDID: appState.userDID, context: context,
                clientID: appState.atProtoClient.map(ObjectIdentifier.init))) {
                refreshAvailability()
                stopGeneration()
                prompt = ""
                selectedImageID = nil
                let did = appState.userDID
                conversationID = UUID()
                conversationAccountDID = did
                historySession.activate(accountDID: did, context: context, conversationID: conversationID)
                turns = []
                isExecutingProposal = false
                exactContextConversations = []
                errorMessage = nil
                successMessage = nil
                contextTrimmedNotice = nil
                await loadInitialConversation(for: did)
                if #available(iOS 26.0, macOS 26.0, *) {
                    await appState.blueskyAgent.prewarm(client: appState.atProtoClient)
                }
            }
            .onChange(of: imageModerationSnapshot) { _, _ in
                hideImages()
            }
            .onDisappear {
                imageRevealSession.hide()
                historySession.invalidate()
                stopGeneration()
            }
            .confirmationDialog(
                "Clear All Ask Catbird History?",
                isPresented: $confirmingClearAll,
                titleVisibility: .visible
            ) {
                Button("Clear All History", role: .destructive) {
                    Task { await clearAllHistory() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes every saved Ask Catbird conversation for this account.")
            }
        }
    }

    @MainActor
    private var imageModerationSnapshot: CopilotImageModerationSnapshot? {
        imageModerationSource?.read(context, appState.userDID)
    }

    private var effectiveImageReveal: ModerationRevealState {
        imageRevealSession.reveal(for: imageModerationSnapshot)
    }

    private var permittedImageCandidates: [CopilotImageCandidate] {
        guard imageModerationSnapshot?.allows(effectiveImageReveal) == true else { return [] }
        return context.imageCandidates
    }

    private func revealImages() {
        guard let snapshot = imageModerationSnapshot, snapshot.rowVisible,
              !snapshot.imageUI.noOverride else { return }
        imageRevealSession.show(snapshot)
    }

    private func hideImages() {
        imageRevealSession.hide()
        selectedImageID = nil
        if turns.contains(where: { $0.id == streamingUserTurnID && $0.selectedImageID != nil }) {
            stopGeneration()
        }
    }

    private struct ContextIdentity: Hashable {
        let accountDID: String
        let context: CopilotContext
        let clientID: ObjectIdentifier?
    }

    private func refreshAvailability() {
        CopilotAvailability.refresh()
        imageUnavailableReason = CopilotImageSupport.unavailableReason()
    }

    // MARK: - Menus

    private var historyMenu: some View {
        Menu {
            Button {
                startNewChat()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }

            if !exactContextConversations.isEmpty {
                Section("Conversations for this context") {
                    ForEach(exactContextConversations) { conv in
                        Button {
                            Task { await loadConversation(conv) }
                        } label: {
                            HStack {
                                Text(conversationTitle(for: conv))
                                if conv.id == conversationID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    Task { await deleteCurrentConversation() }
                } label: {
                    Label("Delete Conversation", systemImage: "trash")
                }
                .disabled(turns.isEmpty)

                Button(role: .destructive) {
                    confirmingClearAll = true
                } label: {
                    Label("Clear All History", systemImage: "trash.fill")
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .accessibilityLabel("Conversation History")
    }

    // MARK: - Sources & Proposals

    private func proposalCard(proposal: CopilotProposal, forTurnID turnID: UUID) -> some View {
        AskCatbirdProposalCard(
            confirmation: CopilotProposalCoordinator.confirmationText(for: proposal, context: context),
            isDedicatedFlow: proposal.disposition == .dedicatedFlow,
            isDisabled: isExecutingProposal || isResponding,
            onConfirm: {
                if proposal.disposition == .dedicatedFlow {
                    continueDedicatedProposal(proposal, turnID: turnID)
                } else {
                    Task { await confirmProposal(proposal, turnID: turnID) }
                }
            },
            onCancel: { cancelProposal(turnID: turnID) }
        )
    }

    private func noticeBanner(text: String, icon: String, color: Color, onDismiss: @escaping () -> Void) -> some View {
        AskCatbirdNotice(text: text, icon: icon, color: color, onDismiss: onDismiss)
    }

    // MARK: - Actions

    @MainActor
    private func send(promptText: String) async {
        let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding, !hasUnresolvedProposal else { return }
        guard !conversationAccountDID.isEmpty, conversationAccountDID == appState.userDID else {
            errorMessage = "The active account changed."
            return
        }

        refreshAvailability()
        if let unavailableMessage {
            errorMessage = unavailableMessage
            return
        }

        let priorHistory = turns
        let chosenImageID = selectedImageID
        let imageAuthorization = imageModerationSource?.authorization(
            snapshot: imageModerationSnapshot, revealSession: imageRevealSession) ?? .denied
        let userTurn = CopilotStoredTurn(id: UUID(), role: .user, text: trimmed,
            createdAt: Date(), selectedImageID: chosenImageID)
        prompt = ""
        selectedImageID = nil
        let assistantTurnID = UUID()
        let emptyAssistantTurn = CopilotStoredTurn(id: assistantTurnID, role: .assistant, text: "", createdAt: Date(), route: route)

        turns.append(userTurn)
        turns.append(emptyAssistantTurn)

        streamingUserTurnID = userTurn.id
        streamingAssistantTurnID = assistantTurnID
        isResponding = true
        errorMessage = nil
        successMessage = nil
        contextTrimmedNotice = nil
        let targetConversationID = conversationID
        let accountDID = conversationAccountDID
        let chosenRoute = route
        let currentContext = context
        let currentClient = appState.atProtoClient
        let clientID = currentClient.map(ObjectIdentifier.init)

        activeStreamTask = Task { @MainActor in
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) {
                let stream = await appState.blueskyAgent.streamTurn(
                    conversationID: targetConversationID,
                    accountDID: accountDID,
                    prompt: trimmed,
                    context: currentContext,
                    history: priorHistory,
                    route: chosenRoute,
                    selectedImageID: chosenImageID,
                    currentClient: currentClient,
                    imageAuthorization: imageAuthorization
                )

                guard !Task.isCancelled, streamingAssistantTurnID == assistantTurnID,
                    targetConversationID == conversationID, accountDID == appState.userDID,
                    clientID == appState.atProtoClient.map(ObjectIdentifier.init) else { return }
                var deltaBuffer = ""
                var lastFlush = ContinuousClock.now

                do {
                    for try await event in stream {
                        guard !Task.isCancelled else { break }
                        if chosenImageID != nil && !imageAuthorization.permits(currentContext, accountDID) {
                            stopGeneration()
                            break
                        }
                        guard streamingAssistantTurnID == assistantTurnID,
                            targetConversationID == conversationID, currentContext == context else { break }
                        guard accountDID == appState.userDID,
                            clientID == appState.atProtoClient.map(ObjectIdentifier.init) else {
                            stopGeneration()
                            break
                        }
                        guard let turnIndex = turns.firstIndex(where: { $0.id == assistantTurnID }) else { break }

                        switch event {
                        case .textDelta(let delta):
                            deltaBuffer.append(delta)
                            let now = ContinuousClock.now
                            if now - lastFlush >= .milliseconds(66) {
                                turns[turnIndex].text.append(deltaBuffer)
                                deltaBuffer = ""
                                lastFlush = now
                            }

                        case .responseReset:
                            deltaBuffer = ""
                            turns[turnIndex].text = ""
                            turns[turnIndex].sources = nil
                            turns[turnIndex].proposal = nil
                            turns[turnIndex].evidence = nil
                            turns[turnIndex].proposalOutcome = nil

                        case .source(let source):
                            if !deltaBuffer.isEmpty {
                                turns[turnIndex].text.append(deltaBuffer)
                                deltaBuffer = ""
                                lastFlush = .now
                            }
                            var currentSources = turns[turnIndex].sources ?? []
                            if !currentSources.contains(source) {
                                currentSources.append(source)
                            }
                            turns[turnIndex].sources = currentSources

                        case .evidence(let evidence):
                            if !deltaBuffer.isEmpty {
                                turns[turnIndex].text.append(deltaBuffer)
                                deltaBuffer = ""
                                lastFlush = .now
                            }
                            var retained = turns[turnIndex].evidence ?? []
                            if !retained.contains(evidence) { retained.append(evidence) }
                            turns[turnIndex].evidence = retained

                        case .proposal(let proposal):
                            if !deltaBuffer.isEmpty {
                                turns[turnIndex].text.append(deltaBuffer)
                                deltaBuffer = ""
                                lastFlush = .now
                            }
                            turns[turnIndex].proposal = proposal
                            turns[turnIndex].proposalOutcome = "Proposed for confirmation; not executed."

                        case .route(let modelRoute):
                            turns[turnIndex].route = modelRoute
                            self.route = modelRoute

                        case .contextTrimmed(let removedTurnCount):
                            contextTrimmedNotice = removedTurnCount == 1
                                ? "An earlier message was left out to keep this conversation within limits."
                                : "Some earlier messages were left out to keep this conversation within limits."

                        case .completed:
                            if !deltaBuffer.isEmpty {
                                turns[turnIndex].text.append(deltaBuffer)
                                deltaBuffer = ""
                            }
                            isResponding = false
                            activeStreamTask = nil
                            streamingAssistantTurnID = nil
                            streamingUserTurnID = nil
                            await persistCurrentConversation()

                        case .failed(let failure):
                            if !deltaBuffer.isEmpty {
                                turns[turnIndex].text.append(deltaBuffer)
                                deltaBuffer = ""
                            }
                            removeInFlightTurnPair()
                            isResponding = false
                            activeStreamTask = nil
                            errorMessage = failure
                        }
                    }
                    if !deltaBuffer.isEmpty, let turnIndex = turns.firstIndex(where: { $0.id == assistantTurnID }) {
                        turns[turnIndex].text.append(deltaBuffer)
                        deltaBuffer = ""
                    }
                } catch {
                    if streamingAssistantTurnID == assistantTurnID {
                        removeInFlightTurnPair()
                        isResponding = false
                        activeStreamTask = nil
                        if !Task.isCancelled {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            } else {
                removeInFlightTurnPair()
                isResponding = false
                activeStreamTask = nil
                errorMessage = "Ask Catbird requires iOS 26 or later."
            }
            #else
            removeInFlightTurnPair()
            isResponding = false
            activeStreamTask = nil
            errorMessage = "Ask Catbird isn’t available on this device."
            #endif
        }
    }

    @MainActor
    private func confirmProposal(_ proposal: CopilotProposal, turnID: UUID) async {
        guard !isExecutingProposal else { return }
        guard !conversationAccountDID.isEmpty, conversationAccountDID == appState.userDID else {
            errorMessage = CopilotProposalError.accountChanged.localizedDescription
            return
        }
        guard let identity = activeHistoryIdentity else { return }
        isExecutingProposal = true
        errorMessage = nil
        defer {
            if historySession.isCurrent(identity, activeAccountDID: appState.userDID) { isExecutingProposal = false }
        }

        do {
            try CopilotProposalCoordinator.validate(
                proposal,
                context: context,
                expectedAccountDID: conversationAccountDID,
                currentAccountDID: appState.userDID
            )
            if let onConfirmedAction {
                try await onConfirmedAction(proposal)
            } else {
                try await CopilotProposalCoordinator.executeConfirmed(
                    proposal,
                    context: context,
                    expectedAccountDID: conversationAccountDID,
                    appState: appState
                )
            }
            guard historySession.isCurrent(identity, activeAccountDID: appState.userDID) else { return }
            successMessage = "Action completed: \(CopilotProposalCoordinator.confirmationText(for: proposal, context: context))"
            if let idx = turns.firstIndex(where: { $0.id == turnID }) {
                turns[idx].proposal = nil
                turns[idx].proposalOutcome = "Confirmed action completed: \(CopilotProposalCoordinator.confirmationText(for: proposal, context: context))"
                await persistCurrentConversation()
            }
        } catch {
            guard historySession.isCurrent(identity, activeAccountDID: appState.userDID) else { return }
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func continueDedicatedProposal(_ proposal: CopilotProposal, turnID: UUID) {
        guard !isExecutingProposal else { return }
        guard !conversationAccountDID.isEmpty, conversationAccountDID == appState.userDID else {
            errorMessage = CopilotProposalError.accountChanged.localizedDescription
            return
        }
        isExecutingProposal = true
        errorMessage = nil

        do {
            try CopilotProposalCoordinator.validate(
                proposal,
                context: context,
                expectedAccountDID: conversationAccountDID,
                currentAccountDID: appState.userDID
            )
            if let onDedicatedAction {
                if let idx = turns.firstIndex(where: { $0.id == turnID }) {
                    turns[idx].proposal = nil
                    turns[idx].proposalOutcome = "Opened dedicated review flow; completion is unknown."
                    Task { await persistCurrentConversation() }
                }
                onDedicatedAction(proposal)
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isExecutingProposal = false
    }

    @MainActor
    private func cancelProposal(turnID: UUID) {
        guard !isExecutingProposal else { return }
        if let idx = turns.firstIndex(where: { $0.id == turnID }) {
            turns[idx].proposal = nil
            turns[idx].proposalOutcome = "Proposal cancelled; not executed."
            Task { await persistCurrentConversation() }
        }
    }

    @MainActor
    private func stopGeneration() {
        activeStreamTask?.cancel()
        activeStreamTask = nil
        removeInFlightTurnPair()
        isResponding = false
    }

    @MainActor
    private func removeInFlightTurnPair() {
        if let assistantID = streamingAssistantTurnID {
            turns.removeAll { $0.id == assistantID }
            streamingAssistantTurnID = nil
        }
        if let userID = streamingUserTurnID {
            turns.removeAll { $0.id == userID }
            streamingUserTurnID = nil
        }
    }

    @MainActor
    private func routeSource(_ source: CopilotSource) {
        guard let uriString = source.uri?.trimmingCharacters(in: .whitespacesAndNewlines), !uriString.isEmpty else {
            errorMessage = "This source does not have a valid link."
            return
        }

        if uriString.hasPrefix("did:") {
            navigationPath.append(NavigationDestination.profile(uriString))
            return
        }

        if uriString.hasPrefix("at://") {
            guard let atURI = try? ATProtocolURI(uriString: uriString) else {
                errorMessage = "This source link is invalid."
                return
            }
            switch atURI.collection {
            case "app.bsky.feed.post":
                navigationPath.append(NavigationDestination.post(atURI))
            case "app.bsky.feed.generator":
                navigationPath.append(NavigationDestination.feed(atURI))
            case "app.bsky.graph.list":
                navigationPath.append(NavigationDestination.list(atURI))
            default:
                errorMessage = "This type of source cannot be opened yet."
            }
            return
        }

        if uriString.hasPrefix("http://") || uriString.hasPrefix("https://") {
            if let url = URL(string: uriString) {
                _ = sceneContext.urlHandler.handle(url)
            } else {
                errorMessage = "This source link is invalid."
            }
            return
        }

        errorMessage = "This source link cannot be opened."
    }

    private func startNewChat() {
        stopGeneration()
        prompt = ""
        selectedImageID = nil
        conversationID = UUID()
        conversationAccountDID = appState.userDID
        historySession.activate(accountDID: conversationAccountDID, context: context, conversationID: conversationID)
        turns = []
        isExecutingProposal = false
        errorMessage = nil
        successMessage = nil
        contextTrimmedNotice = nil
    }

    @MainActor
    private func loadConversation(_ conversation: CopilotConversation) async {
        guard !Task.isCancelled, activeHistoryIdentity != nil else { return }
        guard conversation.accountDID == appState.userDID, conversation.accountDID == conversationAccountDID,
            conversation.context.matchesHistoryContext(context) else {
            errorMessage = "Cannot load conversation from a different account."
            return
        }
        stopGeneration()
        prompt = ""
        selectedImageID = nil
        conversationID = conversation.id
        conversationAccountDID = conversation.accountDID
        historySession.activate(accountDID: conversation.accountDID, context: context, conversationID: conversation.id)
        turns = conversation.turns
        isExecutingProposal = false
        errorMessage = nil
        successMessage = nil
        contextTrimmedNotice = nil

        if conversation.context != context && conversation.context.matchesHistoryContext(context) {
            let migrated = CopilotConversation(
                id: conversation.id,
                accountDID: conversation.accountDID,
                context: context,
                turns: conversation.turns,
                updatedAt: conversation.updatedAt
            )
            guard let identity = activeHistoryIdentity else { return }
            await performHistory(.save(migrated, isMigration: true), identity: identity)
        }
    }

    private var activeHistoryIdentity: AskCatbirdHistorySession.Identity? {
        guard let identity = historySession.current,
            identity.context == context, identity.conversationID == conversationID,
            identity.accountDID == conversationAccountDID,
            historySession.isCurrent(identity, activeAccountDID: appState.userDID) else { return nil }
        return identity
    }

    @MainActor
    private func performHistory(
        _ operation: AskCatbirdHistorySession.Operation,
        identity: AskCatbirdHistorySession.Identity
    ) async {
        let outcome = await historySession.perform(operation, identity: identity, store: .live,
            activeAccountDID: { appState.userDID })
        guard historySession.isCurrent(identity, activeAccountDID: appState.userDID) else { return }
        switch outcome {
        case .loaded(let conversations, let reset):
            exactContextConversations = conversations
            if reset { startNewChat() }
        case .failed(let message): errorMessage = message
        case nil: break
        }
    }

    @MainActor
    private func deleteCurrentConversation() async {
        guard let identity = activeHistoryIdentity else { return }
        stopGeneration()
        await performHistory(.delete, identity: identity)
    }

    @MainActor
    private func clearAllHistory() async {
        guard let identity = activeHistoryIdentity else { return }
        stopGeneration()
        await performHistory(.clear, identity: identity)
    }

    @MainActor
    private func loadInitialConversation(for accountDID: String) async {
        guard !accountDID.isEmpty, let identity = activeHistoryIdentity,
            identity.accountDID == accountDID else { return }
        let outcome = await historySession.perform(.load, identity: identity, store: .live,
            activeAccountDID: { appState.userDID })
        guard historySession.isCurrent(identity, activeAccountDID: appState.userDID) else { return }
        switch outcome {
        case .loaded(let conversations, _):
            exactContextConversations = conversations
            if turns.isEmpty, let latest = conversations.first { await loadConversation(latest) }
        case .failed(let message): errorMessage = message
        case nil: break
        }
    }

    @MainActor
    private func isValidConversationForPersistence(_ turns: [CopilotStoredTurn]) -> Bool {
        guard !turns.isEmpty, turns.count % 2 == 0 else { return false }
        for i in stride(from: 0, to: turns.count, by: 2) {
            let user = turns[i]
            let assistant = turns[i + 1]
            guard user.role == .user, assistant.role == .assistant else { return false }
        }
        return true
    }

    @MainActor
    private func persistCurrentConversation() async {
        guard let identity = activeHistoryIdentity, isValidConversationForPersistence(turns) else { return }
        let conversation = CopilotConversation(
            id: conversationID,
            accountDID: conversationAccountDID,
            context: context,
            turns: turns,
            updatedAt: Date()
        )
        await performHistory(.save(conversation, isMigration: false), identity: identity)
    }

    private func conversationTitle(for conversation: CopilotConversation) -> String {
        if let firstUserTurn = conversation.turns.first(where: { $0.role == .user }), !firstUserTurn.text.isEmpty {
            return String(firstUserTurn.text.prefix(30))
        }
        return conversation.updatedAt.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Presentation only: stored and streamed model text retains its original identity and offsets.
enum CopilotReferencePresentation {
    /// Older conversations can contain machine identifiers as source labels.
    /// Keep the URI for navigation, but never use it as the visible fallback.
    static func label(for source: CopilotSource) -> String {
        let label = source.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty && !label.localizedCaseInsensitiveContains("at://")
            && !label.localizedCaseInsensitiveContains("did:") {
            return label
        }
        let uri = source.uri?.trimmingCharacters(in: .whitespacesAndNewlines) ?? label
        if uri.hasPrefix("did:") { return "Profile" }
        if let atURI = try? ATProtocolURI(uriString: uri) {
            switch atURI.collection {
            case "app.bsky.feed.post": return "Post"
            case "app.bsky.feed.generator": return "Feed"
            case "app.bsky.graph.list": return "List"
            case "app.bsky.actor.profile": return "Profile"
            default: break
            }
        }
        return "Source"
    }

    static func contextLabel(_ context: CopilotContext) -> String {
        let description: String
        switch context {
        case .topic(let name, _, _): description = "Topic: \(name)"
        case .post(_, _, _, let text, _):
            let excerpt = text.trimmingCharacters(in: .whitespacesAndNewlines)
            description = excerpt.isEmpty ? "Post" : "Post: \(excerpt.prefix(100))"
        case .thread: description = "Thread"
        case .profile(_, let handle, let displayName):
            let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let readableName = name.flatMap { $0.isEmpty ? nil : $0 } ?? "@" + handle
            description = "Profile: \(readableName)"
        case .feed(_, let name): description = "Feed: \(name)"
        case .search(let query): description = "Search: \(query)"
        case .smartFilter(_, let name): description = "Smart filter: \(name)"
        }
        return String(render(description, sources: []).characters)
            .components(separatedBy: .newlines).joined(separator: " ")
    }

    private static let referencePattern: NSRegularExpression? = {
        let identifier = #"(?:at://[^\s\[\]()<>\"`]+|did:[a-z]+:[^\s\[\]()<>\"`]+)"#
        return try? NSRegularExpression(
            pattern: #"\[([^\]\n]*)\]\(("# + identifier + #")\)|\[("# + identifier
                + #")\]\((https?://[^\s()<>]+)\)|("# + identifier + ")"
        )
    }()

    private final class AttributedStringBox {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }
    private static let renderCache = NSCache<NSString, AttributedStringBox>()

    static func render(_ text: String, sources: [CopilotSource]) -> AttributedString {
        let cacheKey = "\(text.hashValue)_\(sources.count)" as NSString
        if let cached = renderCache.object(forKey: cacheKey) {
            return cached.value
        }
        
        // Match a complete Markdown reference before bare identifiers so neither
        // its brackets nor a duplicate destination leak into the visible text.
        guard let pattern = referencePattern else {
            let rendered = ChatTextRenderer.attributedString(for: text)
            renderCache.setObject(AttributedStringBox(rendered), forKey: cacheKey)
            return rendered
        }
        var result = AttributedString()
        var cursor = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let markdownURI = Range(match.range(at: 2), in: text)
            let webLabel = Range(match.range(at: 3), in: text)
            let webDestination = Range(match.range(at: 4), in: text).map { String(text[$0]) }
            let identifierRange = markdownURI ?? webLabel ?? range
            let raw = (markdownURI ?? webLabel).map { String(text[$0]) }
                ?? String(text[identifierRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            guard !raw.isEmpty else { continue }
            let referenceEnd = markdownURI != nil || webLabel != nil ? range.upperBound
                : text.index(range.lowerBound, offsetBy: raw.count)
            result.append(ChatTextRenderer.attributedString(for: String(text[cursor..<range.lowerBound])))
            let markdownLabel = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
            let source = sources.first { $0.uri == raw } ?? CopilotSource(label: markdownLabel, uri: raw)
            var reference = AttributedString(label(for: source))
            if let webDestination {
                reference.link = URL(string: webDestination)
            } else if raw.hasPrefix("at://") {
                let components = raw.dropFirst(5).split(separator: "/", omittingEmptySubsequences: false)
                if components.count == 3 {
                    let route: String?
                    switch components[1] {
                    case "app.bsky.feed.post": route = "post"
                    case "app.bsky.feed.generator": route = "feed"
                    case "app.bsky.graph.list": route = "lists"
                    default: route = nil
                    }
                    if let route {
                        reference.link = URL(string: "https://bsky.app/profile/\(components[0])/\(route)/\(components[2])")
                    }
                }
            } else if raw.hasPrefix("did:") {
                reference.link = URL(string: "https://bsky.app/profile/" + raw)
            }
            result.append(reference)
            cursor = referenceEnd
        }
        result.append(ChatTextRenderer.attributedString(for: String(text[cursor...])))
        renderCache.setObject(AttributedStringBox(result), forKey: cacheKey)
        return result
    }
}
