import SwiftUI

struct SmartFiltersSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var rules: [FeedFilterRule] = []

    var body: some View {
        List {
            if rules.isEmpty {
                ContentUnavailableView(
                    "No Smart Filters",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Create one from a person's profile. Rules are private, account-specific, and apply only to Home.")
                )
            } else {
                ForEach(rules) { rule in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: toggleBinding(for: rule)) {
                            Text(rule.rawText)
                                .appFont(AppTextRole.body)
                        }
                        Text(SmartFilterRuleCompiler.confirmationSummary(for: rule, actorName: rule.targetActorDID))
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            Task {
                                try? await SmartFilterRuleStore.shared.remove(
                                    id: rule.id,
                                    accountDID: appState.userDID
                                )
                                await reload()
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Smart Filters")
        .task { await reload() }
    }

    private func toggleBinding(for rule: FeedFilterRule) -> Binding<Bool> {
        Binding(
            get: { rules.first(where: { $0.id == rule.id })?.isEnabled ?? false },
            set: { enabled in
                guard var updated = rules.first(where: { $0.id == rule.id }) else { return }
                updated.isEnabled = enabled
                Task {
                    try? await SmartFilterRuleStore.shared.save(updated)
                    await reload()
                }
            }
        )
    }

    @MainActor
    private func reload() async {
        rules = await SmartFilterRuleStore.shared.rules(for: appState.userDID)
            .sorted { $0.createdAt > $1.createdAt }
    }
}
