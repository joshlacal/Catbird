import SwiftUI

struct SmartFilterEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let targetActorDID: String
    let actorName: String

    @State private var ruleText = ""
    @State private var proposal: FeedFilterRule?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Filter posts from \(actorName)") {
                    TextField("e.g. Collapse angry posts from this person", text: $ruleText, axis: .vertical)
                        .lineLimit(2...5)
                    Text("Supported: replies, reposts, quote posts, topics, expressed tones, insults, conflict, sarcasm, and solicitation. Smart Filters apply only to Home.")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                }

                if let proposal {
                    Section("Catbird understood") {
                        Text(SmartFilterRuleCompiler.confirmationSummary(for: proposal, actorName: actorName))
                        Button("Save Filter") {
                            Task {
                                try? await SmartFilterRuleStore.shared.save(proposal)
                                dismiss()
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Smart Filter")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Interpret") { compile() }
                        .disabled(ruleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func compile() {
        do {
            proposal = try SmartFilterRuleCompiler.compileDeterministically(
                ruleText,
                accountDID: appState.userDID,
                targetActorDID: targetActorDID
            )
            errorMessage = nil
        } catch {
            proposal = nil
            errorMessage = error.localizedDescription
        }
    }
}
