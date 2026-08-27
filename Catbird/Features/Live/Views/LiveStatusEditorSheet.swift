import SwiftUI
import Petrel

public struct LiveStatusEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var streamURLString: String = ""
    @State private var selectedDuration: Int = 60
    @State private var previewCard: URLCardResponse?
    @State private var isLoadingCard = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showingStopConfirmation = false

    private let durations = [30, 60, 120, 240]

    public init(initialURL: String? = nil, initialDuration: Int? = nil) {
        _streamURLString = State(initialValue: initialURL ?? "")
        _selectedDuration = State(initialValue: initialDuration ?? 60)
    }

    private var isLive: Bool {
        appState.liveStatusManager.hasActiveLiveStatus
    }

    private var validation: (isValid: Bool, error: String?, apexDomain: String?) {
        LiveStatusManager.validateStreamURL(streamURLString)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://twitch.tv/...", text: $streamURLString)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .onChange(of: streamURLString) { _, newValue in
                            loadPreviewDebounced(for: newValue)
                        }

                    if !streamURLString.isEmpty && !validation.isValid {
                        Text(validation.error ?? "Invalid URL")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                } header: {
                    Text("Stream URL")
                } footer: {
                    Text("Allowed hosts: Twitch, YouTube, Streamplace, Bluecast, Substack, Beehiiv, Skylight, ESPN, NBA.")
                        .font(.caption)
                }

                if let card = previewCard {
                    Section("Preview") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(card.title.isEmpty ? (validation.apexDomain ?? "Live Stream") : card.title)
                                .font(.headline)
                            if !card.description.isEmpty {
                                Text(card.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Duration") {
                    Picker("Active for", selection: $selectedDuration) {
                        ForEach(durations, id: \.self) { duration in
                            Text(LiveStatusManager.displayDuration(minutes: duration))
                                .tag(duration)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                if isLive {
                    Section {
                        Button(role: .destructive) {
                            showingStopConfirmation = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("End Live Stream")
                                    .bold()
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle(isLive ? "Edit Live" : "Go Live")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isLive ? "Save" : "Go Live") {
                        Task { await submit() }
                    }
                    .bold()
                    .disabled(!validation.isValid || isSubmitting)
                }
            }
            .confirmationDialog("End Live Stream?", isPresented: $showingStopConfirmation, titleVisibility: .visible) {
                Button("End Live Stream", role: .destructive) {
                    Task { await stopLive() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove your live badge and status from your profile.")
            }
            .task {
                await initializeFromCurrentStatus()
            }
        }
    }

    private func initializeFromCurrentStatus() async {
        if let current = appState.liveStatusManager.currentStatus {
            if let duration = current.durationMinutes {
                self.selectedDuration = duration
            }
            if case .appBskyEmbedExternal(let ext) = current.embed {
                self.streamURLString = ext.external.uri.uriString()
                await loadPreview(for: streamURLString)
            }
        }
    }

    private func loadPreviewDebounced(for urlString: String) {
        guard validation.isValid else {
            previewCard = nil
            return
        }
        Task {
            await loadPreview(for: urlString)
        }
    }

    private func loadPreview(for urlString: String) async {
        guard let url = URL(string: urlString) else { return }
        isLoadingCard = true
        if let card = try? await URLCardService.fetchURLCard(for: url.absoluteString) {
            self.previewCard = card
        }
        isLoadingCard = false
    }

    private func submit() async {
        guard let url = URL(string: streamURLString) else { return }
        isSubmitting = true
        errorMessage = nil

        do {
            if isLive {
                try await appState.liveStatusManager.updateStatus(streamURL: url, durationMinutes: selectedDuration)
            } else {
                try await appState.liveStatusManager.publishStatus(streamURL: url, durationMinutes: selectedDuration)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSubmitting = false
    }

    private func stopLive() async {
        isSubmitting = true
        errorMessage = nil
        do {
            try await appState.liveStatusManager.stopLive()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSubmitting = false
    }
}
