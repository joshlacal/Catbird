import SwiftUI
import Petrel
import OSLog

public enum ActivityPrivacyOption: String, CaseIterable, Identifiable {
    case followers = "followers"
    case mutuals = "mutuals"
    case none = "none"
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .followers: return "Anyone who follows me"
        case .mutuals: return "Only followers who I follow"
        case .none: return "No one"
        }
    }
    
    public var subtitle: String {
        switch self {
        case .followers: return "Anyone following your account can subscribe to receive notifications when you post."
        case .mutuals: return "Only mutual followers can subscribe to receive notifications when you post."
        case .none: return "No one can subscribe to receive notifications when you post."
        }
    }
}

struct ActivityPrivacySettingsView: View {
    @Environment(AppState.self) private var appState
    
    @State private var selectedOption: ActivityPrivacyOption = .followers
    @State private var isLoading: Bool = true
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?
    @State private var showErrorAlert: Bool = false
    
    @State private var loadTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    
    private let logger = Logger(subsystem: "blue.catbird", category: "ActivityPrivacySettings")
    
    var body: some View {
        Form {
            Section {
                ForEach(ActivityPrivacyOption.allCases) { option in
                    Button {
                        selectOption(option)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: selectedOption == option ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedOption == option ? Color.blue : Color.secondary)
                                .font(.title3)
                                .padding(.top, 2)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.title)
                                    .font(.body)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.primary)
                                
                                Text(option.subtitle)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading || isSaving)
                }
            } header: {
                Text("Who Can Subscribe to Post Notifications")
            } footer: {
                Text("Controls which users can turn on notifications for your posts. Other users may still view and interact with your public posts according to your other privacy settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Activity Privacy")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await loadDeclaration()
        }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
            saveTask?.cancel()
            saveTask = nil
        }
    }
    
    @MainActor
    private func loadDeclaration() async {
        isLoading = true
        defer { isLoading = false }
        
        guard let client = appState.atProtoClient else { return }
        let userDID = appState.userDID
        
        do {
            let (code, recordData) = try await client.com.atproto.repo.getRecord(
                input: .init(
                    repo: try ATIdentifier(string: userDID),
                    collection: try NSID(nsidString: "app.bsky.notification.declaration"),
                    rkey: try RecordKey(keyString: "self")
                )
            )
            
            guard !Task.isCancelled else { return }
            
            if code == 200, let record = recordData,
               case let .knownType(declarationValue) = record.value,
               let declaration = declarationValue as? AppBskyNotificationDeclaration {
                if let option = ActivityPrivacyOption(rawValue: declaration.allowSubscriptions) {
                    self.selectedOption = option
                } else {
                    self.selectedOption = .followers
                }
            } else if code == 400 || code == 404 {
                // Explicit record-not-found defaults to followers per ATProto lexicon
                self.selectedOption = .followers
            } else {
                throw NSError(domain: "ActivityPrivacySettings", code: code, userInfo: [NSLocalizedDescriptionKey: "Failed to load activity privacy declaration (\(code))."])
            }
        } catch ComAtprotoRepoGetRecord.Error.recordNotFound {
            guard !Task.isCancelled else { return }
            self.selectedOption = .followers
        } catch is CancellationError {
            // Task was cancelled
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("Failed to load notification declaration: \(error.localizedDescription)")
            self.errorMessage = "Failed to load activity privacy settings: \(error.localizedDescription)"
            self.showErrorAlert = true
        }
    }
    
    @MainActor
    private func selectOption(_ newOption: ActivityPrivacyOption) {
        guard newOption != selectedOption else { return }
        let previousOption = selectedOption
        selectedOption = newOption
        isSaving = true
        
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            defer { isSaving = false }
            
            guard let client = appState.atProtoClient else {
                revert(to: previousOption, message: "Client not initialized.")
                return
            }
            
            do {
                let decl = AppBskyNotificationDeclaration(allowSubscriptions: newOption.rawValue)
                let input = ComAtprotoRepoPutRecord.Input(
                    repo: try ATIdentifier(string: appState.userDID),
                    collection: try NSID(nsidString: "app.bsky.notification.declaration"),
                    rkey: try RecordKey(keyString: "self"),
                    record: .knownType(decl)
                )
                let (code, _) = try await client.com.atproto.repo.putRecord(input: input)
                guard !Task.isCancelled else { return }
                guard code == 200 else {
                    throw NSError(domain: "ActivityPrivacySettings", code: code, userInfo: [NSLocalizedDescriptionKey: "Failed to update activity privacy (\(code))."])
                }
                logger.info("Successfully updated activity privacy to \(newOption.rawValue)")
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Failed to save activity privacy: \(error.localizedDescription)")
                revert(to: previousOption, message: error.localizedDescription)
            }
        }
    }
    
    @MainActor
    private func revert(to option: ActivityPrivacyOption, message: String) {
        selectedOption = option
        errorMessage = message
        showErrorAlert = true
    }
}
