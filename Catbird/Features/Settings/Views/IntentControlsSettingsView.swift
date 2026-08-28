//
//  IntentControlsSettingsView.swift
//  Catbird
//
//  Created for Catbird on-device intent controls.
//

import SwiftUI

struct IntentControlsSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var rules: [IntentRule] = []
    @State private var isIntentControlsEnabled = IntelligenceFeatureFlags.intentControlsEnabled
    @State private var editingRule: IntentRule? = nil
    @State private var isAddingNewRule = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: $isIntentControlsEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Intent Controls")
                                .appFont(AppTextRole.headline)
                            Text("Beta")
                                .appFont(AppTextRole.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.15))
                                .foregroundStyle(.purple)
                                .clipShape(Capsule())
                        }
                        Text("On-device AI evaluates your natural language intent rules and adjusts timeline posts without sending data to servers.")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: isIntentControlsEnabled) { _, newValue in
                    IntelligenceFeatureFlags.intentControlsEnabled = newValue
                }
            }

            if isIntentControlsEnabled {
                Section {
                    if rules.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "brain.head.profile")
                                .appFont(AppTextRole.largeTitle)
                                .foregroundStyle(.purple)
                                .padding(.top, 8)
                            Text("No Intent Rules Yet")
                                .appFont(AppTextRole.headline)
                            Text("Add rules in plain English like 'less outrage', 'fewer political arguments', or 'more science' to customize your feed on-device.")
                                .appFont(AppTextRole.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                            Button {
                                isAddingNewRule = true
                            } label: {
                                Label("Add First Rule", systemImage: "plus")
                                    .padding(.horizontal, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                            .padding(.bottom, 8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    } else {
                        ForEach(rules) { rule in
                            Button {
                                editingRule = rule
                            } label: {
                                HStack(alignment: .center, spacing: 12) {
                                    Image(systemName: rule.action.systemImage)
                                        .foregroundStyle(rule.action == .hide ? .orange : .blue)
                                        .frame(width: 24)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(rule.text)
                                            .appFont(AppTextRole.body.weight(.medium))
                                            .foregroundStyle(rule.isEnabled ? .primary : .secondary)

                                        HStack(spacing: 8) {
                                            Text(rule.action.displayName)
                                                .appFont(AppTextRole.caption2.weight(.semibold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(
                                                    (rule.action == .hide ? Color.orange : Color.blue).opacity(0.12)
                                                )
                                                .foregroundStyle(rule.action == .hide ? .orange : .blue)
                                                .clipShape(RoundedRectangle(cornerRadius: 4))

                                            Text(rule.createdAt.formatted(date: .abbreviated, time: .omitted))
                                                .appFont(AppTextRole.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }

                                    Spacer()

                                    Toggle("", isOn: toggleBinding(for: rule))
                                        .labelsHidden()
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    delete(rule: rule)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }

                                Button {
                                    editingRule = rule
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.indigo)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Active Rules")
                        Spacer()
                        if !rules.isEmpty {
                            Button {
                                isAddingNewRule = true
                            } label: {
                                Label("Add Rule", systemImage: "plus")
                                    .appFont(AppTextRole.caption.weight(.semibold))
                            }
                        }
                    }
                } footer: {
                    if !rules.isEmpty {
                        Text("Rules are evaluated on-device during timeline hydration. Hidden posts show a placeholder row; demoted posts are placed toward the end of each loaded page.")
                    }
                }
            }
        }
        .navigationTitle("Intent Controls")
        .task { await reload() }
        .sheet(isPresented: $isAddingNewRule) {
            IntentRuleEditorSheet(accountDID: appState.userDID) { newRule in
                Task {
                    try? await IntentRuleStore.shared.save(newRule)
                    await reload()
                }
            }
        }
        .sheet(item: $editingRule) { rule in
            IntentRuleEditorSheet(existingRule: rule, accountDID: appState.userDID) { updatedRule in
                Task {
                    try? await IntentRuleStore.shared.save(updatedRule)
                    await reload()
                }
            }
        }
    }

    private func toggleBinding(for rule: IntentRule) -> Binding<Bool> {
        Binding(
            get: { rules.first(where: { $0.id == rule.id })?.isEnabled ?? false },
            set: { enabled in
                guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
                rules[idx].isEnabled = enabled
                Task {
                    try? await IntentRuleStore.shared.toggle(id: rule.id, accountDID: appState.userDID, isEnabled: enabled)
                    await reload()
                }
            }
        )
    }

    private func delete(rule: IntentRule) {
        rules.removeAll { $0.id == rule.id }
        Task {
            try? await IntentRuleStore.shared.remove(id: rule.id, accountDID: appState.userDID)
            await reload()
        }
    }

    @MainActor
    private func reload() async {
        rules = await IntentRuleStore.shared.rules(for: appState.userDID)
            .sorted { $0.createdAt > $1.createdAt }
    }
}

/// Sheet for creating or editing an intent rule.
struct IntentRuleEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    var existingRule: IntentRule?
    var accountDID: String
    var onSave: (IntentRule) -> Void

    @State private var ruleText: String = ""
    @State private var action: IntentRuleAction = .hide
    @State private var isEnabled: Bool = true

    init(
        existingRule: IntentRule? = nil,
        accountDID: String,
        onSave: @escaping (IntentRule) -> Void
    ) {
        self.existingRule = existingRule
        self.accountDID = accountDID
        self.onSave = onSave
        _ruleText = State(initialValue: existingRule?.text ?? "")
        _action = State(initialValue: existingRule?.action ?? .hide)
        _isEnabled = State(initialValue: existingRule?.isEnabled ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Intent Rule") {
                    TextField("e.g. less outrage, no crypto scams, more astronomy", text: $ruleText, axis: .vertical)
                        .lineLimit(2...4)

                    Text("Describe what you want to see less or more of in plain language. Apple Intelligence evaluates posts on-device.")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Action") {
                    Picker("Action", selection: $action) {
                        ForEach(IntentRuleAction.allCases) { item in
                            Label(item.displayName, systemImage: item.systemImage)
                                .tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(action.explanation)
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Rule Enabled", isOn: $isEnabled)
                }
            }
            .navigationTitle(existingRule == nil ? "New Intent Rule" : "Edit Intent Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(ruleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        let trimmed = ruleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let rule = IntentRule(
            id: existingRule?.id ?? UUID(),
            text: trimmed,
            action: action,
            isEnabled: isEnabled,
            createdAt: existingRule?.createdAt ?? Date(),
            accountDID: accountDID
        )
        onSave(rule)
        dismiss()
    }
}
