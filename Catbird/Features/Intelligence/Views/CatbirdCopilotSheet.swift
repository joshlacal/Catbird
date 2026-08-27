import SwiftUI
import Petrel
import CatbirdMLSCore

struct CatbirdCopilotSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let context: CopilotContext
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
    @State private var showingCloudConsent: Bool = false
    @State private var exactContextConversations: [CopilotConversation] = []
    @State private var navigationPath = NavigationPath()
    @State private var selectedTab: Int = 0
    @State private var successMessage: String? = nil
    init(
        context: CopilotContext,
        onConfirmedAction: ((CopilotProposal) async throws -> Void)? = nil,
        onDedicatedAction: ((CopilotProposal) -> Void)? = nil
    ) {
        self.context = context
        self.onConfirmedAction = onConfirmedAction
        self.onDedicatedAction = onDedicatedAction
    }

    private var messageAdapters: [CopilotMessageAdapter] {
        turns.map { turn in
            let isActiveStreamingAssistant = (turn.role == .assistant && turn.id == streamingAssistantTurnID)
            let displayText: String
            if isActiveStreamingAssistant && turn.text.isEmpty {
                displayText = "…"
            } else {
                displayText = turn.text
            }
            return CopilotMessageAdapter(
                id: turn.id.uuidString,
                text: displayText,
                senderID: turn.role == .user ? conversationAccountDID : "catbird.copilot",
                senderDisplayName: turn.role == .user ? nil : "Catbird",
                sentAt: turn.createdAt,
                isFromCurrentUser: turn.role == .user,
                sendState: isActiveStreamingAssistant ? .sending : .sent
            )
        }
    }

    private var hasUnresolvedProposal: Bool {
        turns.contains { $0.proposal != nil }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                chromeHeader

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            if turns.isEmpty && !isResponding {
                                ContentUnavailableView(
                                    "Ask about this",
                                    systemImage: "sparkles",
                                    description: Text("Catbird can inspect Bluesky, answer questions, and propose actions for you to confirm.")
                                )
                                .padding(.top, 40)
                            } else {
                                ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                                    let adapter = messageAdapters[index]
                                    VStack(alignment: turn.role == .user ? .trailing : .leading, spacing: 6) {
                                        UnifiedMessageBubble(
                                            message: adapter,
                                            navigationPath: $navigationPath,
                                            showSenderInfo: false,
                                            groupPosition: UnifiedMessageGrouping.groupPosition(for: index, in: messageAdapters)
                                        )
                                        .id(turn.id.uuidString)
                                        .accessibilityLabel(
                                            (turn.role == .assistant && turn.id == streamingAssistantTurnID && turn.text.isEmpty)
                                                ? "Catbird is responding"
                                                : (turn.role == .assistant ? "Catbird: \(turn.text)" : "You: \(turn.text)")
                                        )
                                        if turn.role == .assistant {
                                            if let sources = turn.sources, !sources.isEmpty {
                                                sourcesView(sources)
                                            }

                                            if let proposal = turn.proposal {
                                                proposalCard(proposal: proposal, forTurnID: turn.id)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .onChange(of: turns.count) { _, _ in
                        if let lastID = turns.last?.id.uuidString {
                            withAnimation {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: turns.last?.text) { _, _ in
                        if let lastID = turns.last?.id.uuidString {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
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

                if isResponding {
                    HStack {
                        Spacer()
                        Button {
                            stopGeneration()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "stop.fill")
                                Text("Stop generating")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                UnifiedInputBar(
                    text: $prompt,
                    onSend: { text in
                        Task { await send(promptText: text) }
                    },
                    placeholder: "Ask Catbird…",
                    isDisabled: isResponding || hasUnresolvedProposal
                )
            }
            .navigationTitle("Ask Catbird")
            .navigationBarTitleDisplayMode(.inline)
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
                    HStack(spacing: 12) {
                        historyMenu
                        routeMenu
                    }
                }
            }
            .task(id: appState.userDID) {
                stopGeneration()
                let did = appState.userDID
                conversationID = UUID()
                conversationAccountDID = did
                turns = []
                exactContextConversations = []
                errorMessage = nil
                successMessage = nil
                contextTrimmedNotice = nil
                await loadInitialConversation(for: did)
            }
            .onDisappear {
                stopGeneration()
            }
            .alert("Use Private Cloud Compute?", isPresented: $showingCloudConsent) {
                Button("Cancel", role: .cancel) {}
                Button("Use Private Cloud Compute") {
                    UserDefaults.standard.set(true, forKey: cloudConsentKey)
                    route = .privateCloudCompute
                }
            } message: {
                Text("The request and its Catbird context will be sent to Apple's Private Cloud Compute. This choice is remembered for this account.")
            }
        }
    }

    // MARK: - Chrome

    private var chromeHeader: some View {
        HStack(spacing: 8) {
            contextCard
            routeBadge
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var contextCard: some View {
        Label(contextLabel, systemImage: "scope")
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var routeBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: route == .onDevice ? "iphone" : "cloud")
            Text(route == .onDevice ? "On Device" : "Private Cloud")
        }
        .font(.caption2)
        .fontWeight(.medium)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .fixedSize(horizontal: true, vertical: true)
    }

    private var contextLabel: String {
        context.promptDescription.components(separatedBy: "\n").first ?? "Current context"
    }

    private var routeLabel: String {
        route == .onDevice ? "On Device" : "Private Cloud"
    }

    private var cloudConsentKey: String { "copilot.pccConsent.\(appState.userDID)" }

    private func requestCloudRoute() {
        if UserDefaults.standard.bool(forKey: cloudConsentKey) {
            route = .privateCloudCompute
        } else {
            showingCloudConsent = true
        }
    }

    // MARK: - Menus

    private var routeMenu: some View {
        Menu {
            Button {
                route = .onDevice
            } label: {
                Label("On Device", systemImage: route == .onDevice ? "checkmark" : "iphone")
            }
            Button {
                requestCloudRoute()
            } label: {
                Label("Private Cloud Compute", systemImage: route == .privateCloudCompute ? "checkmark" : "cloud")
            }
        } label: {
            Image(systemName: route == .onDevice ? "iphone" : "cloud")
        }
        .accessibilityLabel("Model Route")
        .accessibilityValue(routeLabel)
    }

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
                    Task { await clearAllHistory() }
                } label: {
                    Label("Clear All Copilot History", systemImage: "trash.fill")
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
    }

    // MARK: - Sources & Proposals

    @ViewBuilder
    private func sourcesView(_ sources: [CopilotSource]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(sources, id: \.self) { source in
                    Button {
                        routeSource(source)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption2)
                            Text(source.label)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Source: \(source.label)")
                    .accessibilityHint(source.uri != nil ? "Opens source details" : "")
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func proposalCard(proposal: CopilotProposal, forTurnID turnID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                Text("Proposed Action")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }

            Text(CopilotProposalCoordinator.confirmationText(for: proposal, context: context))
                .font(.subheadline)
                .foregroundStyle(.primary)

            HStack(spacing: 10) {
                switch proposal.disposition {
                case .inlineConfirmation:
                    Button("Confirm") {
                        Task { await confirmProposal(proposal, turnID: turnID) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isExecutingProposal || isResponding)

                case .dedicatedFlow:
                    Button("Continue") {
                        continueDedicatedProposal(proposal, turnID: turnID)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isExecutingProposal || isResponding)

                }
                Button("Cancel", role: .cancel) {
                    cancelProposal(turnID: turnID)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isExecutingProposal || isResponding)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func noticeBanner(text: String, icon: String, color: Color, onDismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: icon)
            Text(text)
                .lineLimit(3)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .foregroundStyle(color)
        .padding(8)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
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

        let priorHistory = turns
        let userTurn = CopilotStoredTurn(id: UUID(), role: .user, text: trimmed, createdAt: Date())
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

        activeStreamTask = Task { @MainActor in
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) {
                let stream = await appState.blueskyAgent.streamTurn(
                    conversationID: targetConversationID,
                    accountDID: accountDID,
                    prompt: trimmed,
                    context: currentContext,
                    history: priorHistory,
                    route: chosenRoute
                )

                do {
                    for try await event in stream {
                        guard !Task.isCancelled else { break }
                        guard streamingAssistantTurnID == assistantTurnID else { break }
                        guard let turnIndex = turns.firstIndex(where: { $0.id == assistantTurnID }) else { break }

                        switch event {
                        case .textDelta(let delta):
                            turns[turnIndex].text.append(delta)

                        case .responseReset:
                            turns[turnIndex].text = ""
                            turns[turnIndex].sources = nil
                            turns[turnIndex].proposal = nil

                        case .source(let source):
                            var currentSources = turns[turnIndex].sources ?? []
                            if !currentSources.contains(source) {
                                currentSources.append(source)
                            }
                            turns[turnIndex].sources = currentSources

                        case .proposal(let proposal):
                            turns[turnIndex].proposal = proposal

                        case .route(let modelRoute):
                            turns[turnIndex].route = modelRoute
                            self.route = modelRoute

                        case .contextTrimmed(let removedTurnCount):
                            contextTrimmedNotice = "Earlier turns were trimmed (\(removedTurnCount)) to fit model context."

                        case .completed:
                            isResponding = false
                            activeStreamTask = nil
                            streamingAssistantTurnID = nil
                            streamingUserTurnID = nil
                            await persistCurrentConversation()

                        case .failed(let failure):
                            removeInFlightTurnPair()
                            isResponding = false
                            activeStreamTask = nil
                            errorMessage = failure
                        }
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
                errorMessage = "Catbird Copilot requires iOS 26 or later."
            }
            #else
            removeInFlightTurnPair()
            isResponding = false
            activeStreamTask = nil
            errorMessage = "Catbird Copilot is not supported on this platform."
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
        isExecutingProposal = true
        errorMessage = nil
        defer { isExecutingProposal = false }

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
            successMessage = "Action completed: \(CopilotProposalCoordinator.confirmationText(for: proposal, context: context))"
            if let idx = turns.firstIndex(where: { $0.id == turnID }) {
                turns[idx].proposal = nil
                await persistCurrentConversation()
            }
        } catch {
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
            if let idx = turns.firstIndex(where: { $0.id == turnID }) {
                turns[idx].proposal = nil
                Task { await persistCurrentConversation() }
            }
            if let onDedicatedAction {
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
            errorMessage = "Source '\(source.label)' does not have a valid link."
            return
        }

        if uriString.hasPrefix("did:") {
            navigationPath.append(NavigationDestination.profile(uriString))
            return
        }

        if uriString.hasPrefix("at://") {
            guard let atURI = try? ATProtocolURI(uriString: uriString) else {
                errorMessage = "Unsupported or invalid AT protocol URI: \(uriString)"
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
                errorMessage = "Unsupported source collection: \(atURI.collection ?? "unknown")"
            }
            return
        }

        if uriString.hasPrefix("http://") || uriString.hasPrefix("https://") {
            if let url = URL(string: uriString) {
                _ = appState.urlHandler.handle(url)
            } else {
                errorMessage = "Invalid URL: \(uriString)"
            }
            return
        }

        errorMessage = "Unsupported source link: \(uriString)"
    }

    private func startNewChat() {
        stopGeneration()
        conversationID = UUID()
        conversationAccountDID = appState.userDID
        turns = []
        errorMessage = nil
        successMessage = nil
        contextTrimmedNotice = nil
    }

    @MainActor
    private func loadConversation(_ conversation: CopilotConversation) async {
        guard conversation.accountDID == appState.userDID, conversation.accountDID == conversationAccountDID else {
            errorMessage = "Cannot load conversation from a different account."
            return
        }
        stopGeneration()
        conversationID = conversation.id
        conversationAccountDID = conversation.accountDID
        turns = conversation.turns
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
            do {
                try await CopilotHistoryStore.shared.save(migrated)
                let all = try await CopilotHistoryStore.shared.conversations(for: conversationAccountDID)
                exactContextConversations = all.filter { $0.context.matchesHistoryContext(context) }
            } catch {
                errorMessage = "Failed to migrate conversation: \(error.localizedDescription)"
            }
        }
    }

    @MainActor
    private func deleteCurrentConversation() async {
        guard !conversationAccountDID.isEmpty, conversationAccountDID == appState.userDID else {
            errorMessage = "The active account changed."
            return
        }
        stopGeneration()
        let targetConvID = conversationID
        let targetDID = conversationAccountDID
        do {
            try await CopilotHistoryStore.shared.delete(conversationID: targetConvID, accountDID: targetDID)
            let all = try await CopilotHistoryStore.shared.conversations(for: targetDID)
            exactContextConversations = all.filter { $0.context.matchesHistoryContext(context) }
        } catch {
            errorMessage = "Failed to delete conversation: \(error.localizedDescription)"
        }
        startNewChat()
    }

    @MainActor
    private func clearAllHistory() async {
        guard !conversationAccountDID.isEmpty, conversationAccountDID == appState.userDID else {
            errorMessage = "The active account changed."
            return
        }
        stopGeneration()
        let targetDID = conversationAccountDID
        await CopilotHistoryStore.shared.clear(accountDID: targetDID)
        exactContextConversations = []
        startNewChat()
    }

    @MainActor
    private func loadInitialConversation(for accountDID: String) async {
        guard !accountDID.isEmpty else { return }
        do {
            let all = try await CopilotHistoryStore.shared.conversations(for: accountDID)
            guard accountDID == appState.userDID, accountDID == conversationAccountDID else { return }
            exactContextConversations = all.filter { $0.context.matchesHistoryContext(context) }
            if turns.isEmpty, let latest = exactContextConversations.first {
                await loadConversation(latest)
            }
        } catch {
            guard accountDID == appState.userDID, accountDID == conversationAccountDID else { return }
            errorMessage = "Failed to load history: \(error.localizedDescription)"
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
        guard !conversationAccountDID.isEmpty, conversationAccountDID == appState.userDID else { return }
        guard isValidConversationForPersistence(turns) else { return }
        let conversation = CopilotConversation(
            id: conversationID,
            accountDID: conversationAccountDID,
            context: context,
            turns: turns,
            updatedAt: Date()
        )
        do {
            try await CopilotHistoryStore.shared.save(conversation)
            exactContextConversations = try await CopilotHistoryStore.shared.conversations(for: conversationAccountDID).filter { $0.context.matchesHistoryContext(context) }
        } catch {
            errorMessage = "Failed to save conversation: \(error.localizedDescription)"
        }
    }

    private func conversationTitle(for conversation: CopilotConversation) -> String {
        if let firstUserTurn = conversation.turns.first(where: { $0.role == .user }), !firstUserTurn.text.isEmpty {
            return String(firstUserTurn.text.prefix(30))
        }
        return conversation.updatedAt.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - CopilotMessageAdapter

private struct CopilotMessageAdapter: UnifiedChatMessage, Identifiable, Hashable, Sendable {
    let id: String
    let text: String
    let senderID: String
    let senderDisplayName: String?
    let senderAvatarURL: URL? = nil
    let sentAt: Date
    let isFromCurrentUser: Bool
    let reactions: [UnifiedReaction] = []
    let embed: UnifiedEmbed? = nil
    let sendState: MessageSendState
}
