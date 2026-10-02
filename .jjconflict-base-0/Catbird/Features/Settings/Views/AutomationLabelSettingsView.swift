import SwiftUI
import Petrel
import OSLog

public enum AutomationBotSelfLabels {
    public static let botLabel = "bot"
    
    public static func isBotLabeled(_ labels: [String]) -> Bool {
        labels.contains(botLabel)
    }
    
    public static func isBotLabeled(_ labels: [ComAtprotoLabelDefs.SelfLabel]?) -> Bool {
        guard let labels else { return false }
        return labels.contains { $0.val == botLabel }
    }
    
    public static func isBotLabeled(_ labels: [ComAtprotoLabelDefs.Label]?) -> Bool {
        guard let labels else { return false }
        return labels.contains { $0.val == botLabel }
    }
    
    public static func reconciled(_ currentValues: [String], isBot: Bool) -> [String] {
        var updated = currentValues
        if isBot {
            if !updated.contains(botLabel) {
                updated.append(botLabel)
            }
        } else {
            updated.removeAll { $0 == botLabel }
        }
        return updated
    }
}

struct AutomationLabelSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppStateManager.self) private var appStateManager
    
    @State private var isBot: Bool = false
    @State private var isLoading: Bool = true
    @State private var isUpdating: Bool = false
    @State private var errorMessage: String?
    @State private var showErrorAlert: Bool = false
    @State private var profileDetailed: AppBskyActorDefs.ProfileViewDetailed?
    @State private var profileRecord: (cid: CID?, profile: AppBskyActorProfile)?
    
    @State private var loadTask: Task<Void, Never>?
    @State private var updateTask: Task<Void, Never>?
    
    private let logger = Logger(subsystem: "blue.catbird", category: "AutomationLabelSettings")
    
    var body: some View {
        Form {
            Section {
                profilePreview
            } header: {
                Text("Preview")
            } footer: {
                Text("When enabled, a Bot badge is displayed on your profile and posts to let others know this account is automated.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            Section {
                Toggle("Automated Account (Bot)", isOn: Binding(
                    get: { isBot },
                    set: { newValue in
                        updateBotLabel(to: newValue)
                    }
                ))
                .disabled(isLoading || isUpdating)
            } footer: {
                Text("Self-labeling as a bot helps people and algorithms understand automated activity from your account.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Automation Label")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await loadProfileData()
        }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
            updateTask?.cancel()
            updateTask = nil
        }
    }
    
    @ViewBuilder
    private var profilePreview: some View {
        HStack(spacing: 12) {
            if let avatarURL = profileDetailed?.avatar?.url {
                AsyncImage(url: avatarURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Circle().fill(Color.gray.opacity(0.3))
                }
                .frame(width: 50, height: 50)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .frame(width: 50, height: 50)
                    .foregroundStyle(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profileDetailed?.displayName ?? profileDetailed?.handle.description ?? "User")
                        .font(.headline)
                        .lineLimit(1)
                    
                    if isBot {
                        Text("BOT")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                    }
                }
                
                Text("@\(profileDetailed?.handle.description ?? "")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
    
    @MainActor
    private func loadProfileData() async {
        isLoading = true
        defer { isLoading = false }
        
        guard let client = appState.atProtoClient else { return }
        let userDID = appState.userDID
        
        do {
            let (profCode, profData) = try await client.app.bsky.actor.getProfile(
                input: .init(actor: try ATIdentifier(string: userDID))
            )
            guard !Task.isCancelled else { return }
            if profCode == 200, let profile = profData {
                self.profileDetailed = profile
            }
            
            let (recCode, recData) = try await client.com.atproto.repo.getRecord(
                input: .init(
                    repo: try ATIdentifier(string: userDID),
                    collection: try NSID(nsidString: "app.bsky.actor.profile"),
                    rkey: try RecordKey(keyString: "self")
                )
            )
            guard !Task.isCancelled else { return }
            
            if recCode == 200, let record = recData,
               case let .knownType(profileValue) = record.value,
               let profile = profileValue as? AppBskyActorProfile {
                self.profileRecord = (cid: record.cid, profile: profile)
                self.isBot = Self.hasBotLabel(profile.labels)
            } else if recCode == 400 || recCode == 404 {
                self.profileRecord = nil
                self.isBot = false
            }
        } catch ComAtprotoRepoGetRecord.Error.recordNotFound {
            guard !Task.isCancelled else { return }
            self.profileRecord = nil
            self.isBot = false
        } catch is CancellationError {
            // Task was cancelled
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("Failed to load profile record for bot label: \(error)")
        }
    }
    
    @MainActor
    private func updateBotLabel(to newValue: Bool) {
        let previousValue = isBot
        isBot = newValue
        isUpdating = true
        
        updateTask?.cancel()
        updateTask = Task { @MainActor in
            defer { isUpdating = false }
            
            guard let client = appState.atProtoClient else {
                revert(to: previousValue, message: "Client not initialized.")
                return
            }
            
            do {
                if let record = profileRecord {
                    guard let cid = record.cid else {
                        throw NSError(
                            domain: "AutomationLabelSettings",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Missing record CID for profile update."]
                        )
                    }
                    try await putProfileBotLabel(newValue, record: (cid: cid, profile: record.profile), client: client)
                } else {
                    try await createProfileBotLabel(newValue, client: client)
                }
                appState.stateInvalidationBus.notify(.profileUpdated(did: appState.userDID))
                await loadProfileData()
            } catch is CancellationError {
                // Task was cancelled
            } catch {
                logger.error("Failed to update bot label: \(error)")
                revert(to: previousValue, message: error.localizedDescription)
            }
        }
    }
    
    private func putProfileBotLabel(
        _ isBot: Bool,
        record: (cid: CID, profile: AppBskyActorProfile),
        client: ATProtoClient
    ) async throws {
        let profile = record.profile
        let updatedProfile = AppBskyActorProfile(
            displayName: profile.displayName,
            description: profile.description,
            pronouns: profile.pronouns,
            website: profile.website,
            avatar: profile.avatar,
            banner: profile.banner,
            labels: try Self.updatedLabels(profile.labels, isBot: isBot),
            joinedViaStarterPack: profile.joinedViaStarterPack,
            pinnedPost: profile.pinnedPost,
            createdAt: profile.createdAt
        )
        let input = ComAtprotoRepoPutRecord.Input(
            repo: try ATIdentifier(string: appState.userDID),
            collection: try NSID(nsidString: "app.bsky.actor.profile"),
            rkey: try RecordKey(keyString: "self"),
            record: .knownType(updatedProfile),
            swapRecord: record.cid
        )
        let (code, _) = try await client.com.atproto.repo.putRecord(input: input)
        guard code == 200 else {
            throw NSError(domain: "AutomationLabelSettings", code: code, userInfo: [NSLocalizedDescriptionKey: "Profile update failed (\(code))."])
        }
    }
    
    private func createProfileBotLabel(_ isBot: Bool, client: ATProtoClient) async throws {
        let profile = AppBskyActorProfile(
            displayName: nil,
            description: nil,
            pronouns: nil,
            website: nil,
            avatar: nil,
            banner: nil,
            labels: try Self.updatedLabels(nil, isBot: isBot),
            joinedViaStarterPack: nil,
            pinnedPost: nil,
            createdAt: ATProtocolDate(date: Date())
        )
        let input = ComAtprotoRepoCreateRecord.Input(
            repo: try ATIdentifier(string: appState.userDID),
            collection: try NSID(nsidString: "app.bsky.actor.profile"),
            rkey: try RecordKey(keyString: "self"),
            record: .knownType(profile)
        )
        let (code, _) = try await client.com.atproto.repo.createRecord(input: input)
        guard code == 200 else {
            throw NSError(domain: "AutomationLabelSettings", code: code, userInfo: [NSLocalizedDescriptionKey: "Profile creation failed (\(code))."])
        }
    }
    
    private static func hasBotLabel(_ labels: AppBskyActorProfile.AppBskyActorProfileLabelsUnion?) -> Bool {
        guard case let .comAtprotoLabelDefsSelfLabels(selfLabels) = labels else { return false }
        return selfLabels.values.contains { $0.val == AutomationBotSelfLabels.botLabel }
    }
    
    public static func updatedLabels(
        _ labels: AppBskyActorProfile.AppBskyActorProfileLabelsUnion?,
        isBot: Bool
    ) throws -> AppBskyActorProfile.AppBskyActorProfileLabelsUnion? {
        let sourceValues: [ComAtprotoLabelDefs.SelfLabel]
        switch labels {
        case .comAtprotoLabelDefsSelfLabels(let selfLabels):
            sourceValues = selfLabels.values
        case .unexpected:
            throw NSError(domain: "AutomationLabelSettings", code: 400, userInfo: [NSLocalizedDescriptionKey: "Unsupported profile label format."])
        case nil:
            sourceValues = []
        }
        let values = AutomationBotSelfLabels
            .reconciled(sourceValues.map(\.val), isBot: isBot)
            .map { ComAtprotoLabelDefs.SelfLabel(val: $0) }
        guard !values.isEmpty else { return nil }
        return .comAtprotoLabelDefsSelfLabels(.init(values: values))
    }
    
    @MainActor
    private func revert(to value: Bool, message: String) {
        isBot = value
        errorMessage = message
        showErrorAlert = true
    }
}
