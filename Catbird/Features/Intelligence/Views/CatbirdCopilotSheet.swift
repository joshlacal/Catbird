import SwiftUI

struct CatbirdCopilotSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let context: CopilotContext

    @State private var prompt = ""
    @State private var response = ""
    @State private var isResponding = false
    @State private var errorMessage: String?
    @State private var route: CopilotModelRoute = .onDevice
    @State private var showingCloudConsent = false
    @State private var pendingProposal: CopilotProposal?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                contextCard

                ScrollView {
                    if response.isEmpty && !isResponding {
                        ContentUnavailableView(
                            "Ask about this",
                            systemImage: "sparkles",
                            description: Text("Catbird can inspect Bluesky with read-only tools and explain what it finds.")
                        )
                    } else {
                        Text(response)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .appFont(AppTextRole.caption)
                }

                HStack(alignment: .bottom) {
                    TextField("Ask Catbird…", text: $prompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                    Button {
                        Task { await submit() }
                    } label: {
                        if isResponding { ProgressView() } else { Image(systemName: "arrow.up.circle.fill") }
                    }
                    .buttonStyle(.borderless)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResponding)
                }
            }
            .padding()
            .navigationTitle("Ask Catbird")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
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
                        Label(routeLabel, systemImage: route == .onDevice ? "iphone" : "cloud")
                    }
                }
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
            .alert("Confirm Catbird Action", isPresented: proposalAlertBinding) {
                Button("Cancel", role: .cancel) { pendingProposal = nil }
                Button("Confirm") { Task { await executePendingProposal() } }
            } message: {
                if let pendingProposal {
                    Text(CopilotProposalCoordinator.confirmationText(for: pendingProposal))
                }
            }
        }
    }

    private var contextCard: some View {
        Label(contextLabel, systemImage: "scope")
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var contextLabel: String {
        context.promptDescription.components(separatedBy: "\n").first ?? "Current context"
    }

    private var routeLabel: String {
        route == .onDevice ? "On Device" : "Private Cloud"
    }

    private var cloudConsentKey: String { "copilot.pccConsent.\(appState.userDID)" }

    private var proposalAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingProposal != nil },
            set: { if !$0 { pendingProposal = nil } }
        )
    }

    private func requestCloudRoute() {
        if UserDefaults.standard.bool(forKey: cloudConsentKey) {
            route = .privateCloudCompute
        } else {
            showingCloudConsent = true
        }
    }

    @MainActor
    private func submit() async {
        let userPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userPrompt.isEmpty else { return }
        prompt = ""
        response = ""
        errorMessage = nil
        isResponding = true
        defer { isResponding = false }

        if let proposal = CopilotProposalCoordinator.proposal(for: userPrompt, context: context) {
            response = "Catbird prepared an action for your review. Nothing changes until you confirm it."
            pendingProposal = proposal
            return
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            do {
                response = try await appState.blueskyAgent.respond(
                    to: userPrompt,
                    context: context,
                    route: route
                )
                let conversation = CopilotConversation(
                    id: UUID(),
                    accountDID: appState.userDID,
                    context: context,
                    turns: [
                        CopilotStoredTurn(id: UUID(), role: .user, text: userPrompt, createdAt: Date()),
                        CopilotStoredTurn(id: UUID(), role: .assistant, text: response, createdAt: Date()),
                    ],
                    updatedAt: Date()
                )
                try? await CopilotHistoryStore.shared.save(conversation)
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            errorMessage = "Ask Catbird requires Apple Intelligence."
        }
        #else
        errorMessage = "Ask Catbird is unavailable on this platform."
        #endif
    }

    @MainActor
    private func executePendingProposal() async {
        guard let proposal = pendingProposal else { return }
        pendingProposal = nil
        do {
            try await CopilotProposalCoordinator.executeConfirmed(proposal, appState: appState)
            response = "Done. Catbird applied the action you confirmed."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
