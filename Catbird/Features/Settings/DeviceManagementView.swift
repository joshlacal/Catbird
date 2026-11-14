import SwiftUI
import Petrel
import PetrelCatbird
import OSLog
import CatbirdMLSCore

@available(iOS 18.0, macOS 13.0, *)
struct DeviceManagementView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = DeviceManagementViewModel()

    var body: some View {
        List {
            if viewModel.isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else if let error = viewModel.error {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Error Loading Devices")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Text(error.localizedDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Try Again") {
                            Task {
                                await viewModel.loadDevices()
                            }
                        }
                    }
                }
            } else if viewModel.devices.isEmpty {
                Section {
                    VStack(alignment: .center, spacing: 8) {
                        Image(systemName: "iphone.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No Devices Found")
                            .font(.headline)
                        Text("Register a device to enable MLS messaging")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
            } else {
                Section {
                    ForEach(viewModel.devices, id: \.deviceId) { device in
                        DeviceRow(
                            device: device,
                            isCurrentDevice: device.isCurrentDevice(currentDeviceId: viewModel.currentDeviceId),
                            onDelete: {
                                guard device.canRevoke(currentDeviceId: viewModel.currentDeviceId) else { return }
                                viewModel.deviceToDelete = device
                                viewModel.showDeleteConfirmation = true
                            }
                        )
                    }
                }
            }
        }
        .navigationTitle("Devices")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                let otherDevices = viewModel.devices.filter { $0.canRevoke(currentDeviceId: viewModel.currentDeviceId) }
                if !otherDevices.isEmpty {
                    Button(role: .destructive) {
                        viewModel.showClearAllConfirmation = true
                    } label: {
                        Text("Revoke Other Devices")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .task {
            await viewModel.initialize(appState: appState)
            await viewModel.loadDevices()
        }
        .alert("Revoke Device", isPresented: $viewModel.showDeleteConfirmation, presenting: viewModel.deviceToDelete) { device in
            Button("Cancel", role: .cancel) {}
            Button("Revoke", role: .destructive) {
                Task {
                    await viewModel.deleteDevice(device)
                }
            }
        } message: { device in
            Text("Revoke “\(device.deviceName)”? This removes its MLS key packages and rotates your encrypted backup epoch.")
        }
        .alert("Revoke All Other Devices", isPresented: $viewModel.showClearAllConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Revoke Others", role: .destructive) {
                Task {
                    await viewModel.clearAllOtherDevices()
                }
            }
        } message: {
            Text("Are you sure you want to revoke all other authorized devices? This device will remain active.")
        }
        .alert("Couldn’t Delete Device", isPresented: Binding(get: { viewModel.deleteError != nil }, set: { if !$0 { viewModel.deleteError = nil } })) {
            Button("OK") {
                viewModel.deleteError = nil
            }
        } message: {
            if let error = viewModel.deleteError {
                Text(error.localizedDescription)
            }
        }
    }
}

enum MLSDeviceActivityState: String, Equatable, Sendable {
    case active
    case dormant
    case pendingApproval = "pending_approval"
    case revoked

    /// Matches the 48-hour dormant threshold for multi-device ack-driven pruning.
    static let dormancyThresholdSeconds: TimeInterval = 48 * 3600

    var badgeTitle: String {
        switch self {
        case .active: "Active"
        case .dormant: "Dormant"
        case .pendingApproval: "Pending Approval"
        case .revoked: "Revoked"
        }
    }

    var badgeTint: Color {
        switch self {
        case .active: .green
        case .dormant: .orange
        case .pendingApproval: .yellow
        case .revoked: .secondary
        }
    }
}

private struct ForwardCompatibleDeviceMetadata: Decodable {
    let deviceId: String?
    let deviceName: String?
    let status: String?
    let updatedAt: String?
    let lastActiveAt: String?
    let dormantAt: String?
    let availablePackageCount: Int?
}

struct DeviceRowModel: Identifiable, Equatable, Sendable {
    let deviceId: String
    let deviceName: String
    let deviceUUID: String?
    let lastSeenAt: Date
    let keyPackageCount: Int
    let activityState: MLSDeviceActivityState

    var id: String { deviceId }

    /// Parses `#canonicalDatetime` (`YYYY-MM-DDTHH:MM:SS.sssZ`) as well as standard ISO-8601 strings.
    static func parseISO8601(_ raw: String?) -> Date? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: trimmed) {
            return parsed
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let parsed = plain.date(from: trimmed) {
            return parsed
        }
        return ATProtocolDate(iso8601String: trimmed)?.date
    }

    init(
        deviceId: String,
        deviceName: String? = nil,
        deviceUUID: String? = nil,
        lastSeenAt: Date = Date(),
        keyPackageCount: Int = 0,
        activityState: MLSDeviceActivityState? = nil,
        currentDeviceId: String? = nil,
        now: Date = Date()
    ) {
        let normalizedId = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let isCurrent = Self.matchesDeviceID(normalizedId, currentDeviceId)
        self.deviceId = normalizedId
        let trimmedName = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty {
            self.deviceName = String(trimmedName.prefix(128))
        } else if isCurrent {
            self.deviceName = AppState.localMLSDeviceDisplayName(shortDeviceId: normalizedId)
        } else {
            self.deviceName = "Device \(normalizedId.prefix(8))"
        }
        self.deviceUUID = deviceUUID
        self.lastSeenAt = lastSeenAt
        self.keyPackageCount = keyPackageCount
        if let activityState {
            self.activityState = activityState
        } else if isCurrent {
            self.activityState = .active
        } else if now.timeIntervalSince(lastSeenAt) >= MLSDeviceActivityState.dormancyThresholdSeconds {
            self.activityState = .dormant
        } else {
            self.activityState = .active
        }
    }

    init?(
        wireDeviceJSON: Data,
        fallbackDevice: BlueCatbirdChatDefs.DeviceView? = nil,
        currentDeviceId: String? = nil,
        now: Date = Date()
    ) {
        let extra = try? JSONDecoder().decode(ForwardCompatibleDeviceMetadata.self, from: wireDeviceJSON)
        guard let rawId = fallbackDevice?.deviceId ?? extra?.deviceId,
              !rawId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        let isCurrent = Self.matchesDeviceID(rawId, currentDeviceId)
        let parsedLastActive = Self.parseISO8601(extra?.lastActiveAt)
        let fallbackUpdated = fallbackDevice?.updatedAt.date
            ?? Self.parseISO8601(extra?.updatedAt)
            ?? now
        let effectiveLastSeen = parsedLastActive ?? fallbackUpdated
        let parsedDormantAt = Self.parseISO8601(extra?.dormantAt)

        let resolvedState: MLSDeviceActivityState
        if fallbackDevice?.status == .value_revoked || extra?.status == "revoked" {
            resolvedState = .revoked
        } else if extra?.status == "pending_approval" {
            resolvedState = .pendingApproval
        } else if isCurrent {
            resolvedState = .active
        } else if parsedDormantAt != nil
            || now.timeIntervalSince(effectiveLastSeen) >= MLSDeviceActivityState.dormancyThresholdSeconds
        {
            resolvedState = .dormant
        } else {
            resolvedState = .active
        }

        self.init(
            deviceId: rawId,
            deviceName: extra?.deviceName,
            deviceUUID: nil,
            lastSeenAt: effectiveLastSeen,
            keyPackageCount: fallbackDevice?.availablePackageCount ?? extra?.availablePackageCount ?? 0,
            activityState: resolvedState,
            currentDeviceId: currentDeviceId,
            now: now
        )
    }

    init(
        _ ownDevice: BlueCatbirdChatDefs.OwnDeviceView,
        currentDeviceId: String? = nil,
        now: Date = Date()
    ) {
        let encoded = (try? JSONEncoder().encode(ownDevice.device)) ?? Data("{}".utf8)
        if let decoded = DeviceRowModel(
            wireDeviceJSON: encoded,
            fallbackDevice: ownDevice.device,
            currentDeviceId: currentDeviceId,
            now: now
        ) {
            self = decoded
        } else {
            self.init(
                deviceId: ownDevice.device.deviceId,
                deviceName: nil,
                deviceUUID: nil,
                lastSeenAt: ownDevice.device.updatedAt.date,
                keyPackageCount: ownDevice.device.availablePackageCount,
                activityState: ownDevice.device.status == .value_revoked ? .revoked : nil,
                currentDeviceId: currentDeviceId,
                now: now
            )
        }
    }

    static func matchesDeviceID(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = lhs?.trimmingCharacters(in: .whitespacesAndNewlines),
              let rhs = rhs?.trimmingCharacters(in: .whitespacesAndNewlines),
              !lhs.isEmpty,
              !rhs.isEmpty
        else {
            return false
        }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    func isCurrentDevice(currentDeviceId: String?) -> Bool {
        Self.matchesDeviceID(deviceId, currentDeviceId)
    }

    func canRevoke(currentDeviceId: String?) -> Bool {
        !isCurrentDevice(currentDeviceId: currentDeviceId) && activityState != .revoked
    }
}

struct DeviceRow: View {
    let device: DeviceRowModel
    let isCurrentDevice: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(device.deviceName)
                            .font(.headline)
                        if isCurrentDevice {
                            Text("This Device")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.18))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                                .accessibilityIdentifier("device-this-device-badge")
                        }
                        Text(device.activityState.badgeTitle)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(device.activityState.badgeTint.opacity(0.16))
                            .foregroundStyle(device.activityState.badgeTint)
                            .clipShape(Capsule())
                            .accessibilityIdentifier("device-status-badge-\(device.activityState.rawValue)")
                    }

                    Text("\(device.deviceId.prefix(8))… · \(formatDate(device.lastSeenAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if isCurrentDevice {
                        Text("Sign out in Account & Security to remove this device.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Label {
                        Text("\(device.keyPackageCount)")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "key.fill")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            if let deviceUUID = device.deviceUUID {
                Text("UUID: \(deviceUUID.prefix(8))…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            if !isCurrentDevice && device.activityState != .revoked {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Revoke", systemImage: "trash")
                }
            }
        }
        .contextMenu {
            if !isCurrentDevice && device.activityState != .revoked {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Revoke Device", systemImage: "trash")
                }
            }

            Button {
                #if os(iOS)
                UIPasteboard.general.string = device.deviceId
                #elseif os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(device.deviceId, forType: .string)
                #endif
            } label: {
                Label("Copy Device ID", systemImage: "doc.on.doc")
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let now = Date()
        let components = Calendar.current.dateComponents([.day, .hour, .minute], from: date, to: now)

        if let days = components.day, days > 0 {
            return days == 1 ? "Last seen 1 day ago" : "Last seen \(days) days ago"
        } else if let hours = components.hour, hours > 0 {
            return hours == 1 ? "Last seen 1 hour ago" : "Last seen \(hours) hours ago"
        } else if let minutes = components.minute, minutes > 0 {
            return minutes == 1 ? "Last seen 1 minute ago" : "Last seen \(minutes) minutes ago"
        } else {
            return "Last seen just now"
        }
    }
}

@available(iOS 18.0, macOS 13.0, *)
@Observable
final class DeviceManagementViewModel {
    private let logger = Logger(subsystem: "blue.catbird", category: "DeviceManagement")

    var devices: [DeviceRowModel] = []
    var isLoading = false
    var error: Error?
    var deleteError: Error?
    var showDeleteConfirmation = false
    var showClearAllConfirmation = false
    var deviceToDelete: DeviceRowModel?
    var currentDeviceId: String?
    var customRevokerForTesting: (@MainActor (_ targetDeviceId: String) async throws -> Void)?

    private var appState: AppState?

    @MainActor
    func initialize(appState: AppState) async {
        self.appState = appState
        self.currentDeviceId = appState.resolvedMLSDeviceID()
    }

    @MainActor
    func clearAllOtherDevices() async {
        guard let currentId = currentDeviceId else {
            logger.error("Cannot clear other devices: current device ID is unknown")
            return
        }

        isLoading = true
        let otherDevices = devices.filter { $0.canRevoke(currentDeviceId: currentId) }
        for device in otherDevices {
            await deleteDevice(device)
        }
        isLoading = false
    }

    @MainActor
    func loadDevices() async {
        guard appState?.client != nil,
              let appState
        else {
            logger.error("No authenticated client available")
            return
        }

        isLoading = true
        error = nil

        do {
            logger.info("Loading devices...")
            let actorDeviceId = currentDeviceId ?? appState.resolvedMLSDeviceID()
            currentDeviceId = actorDeviceId
            guard let mlsClient = await appState.getMLSAPIClient() else {
                devices = []
                isLoading = false
                return
            }
            let output = try await mlsClient.getOwnDevices(actorDeviceId: actorDeviceId)
            let loaded = output?.items.map { DeviceRowModel($0, currentDeviceId: actorDeviceId) } ?? []
            devices = loaded.sorted { lhs, rhs in
                let lhsCurrent = lhs.isCurrentDevice(currentDeviceId: actorDeviceId)
                let rhsCurrent = rhs.isCurrentDevice(currentDeviceId: actorDeviceId)
                if lhsCurrent != rhsCurrent { return lhsCurrent }
                return lhs.lastSeenAt > rhs.lastSeenAt
            }
            logger.info("Loaded \(self.devices.count) devices")
        } catch {
            logger.error("Failed to load devices: \(error.localizedDescription)")
            self.error = error
        }

        isLoading = false
    }

    static let selfRevokeBlockedMessage =
        "You cannot revoke the device you are currently using. Sign out in Account & Security to remove this device."
    static let coordinatorUnavailableMessage =
        "Encrypted chat coordinator is unavailable. Open Messages and try revoking this device again."

    @MainActor
    func deleteDevice(_ device: DeviceRowModel) async {
        let activeCurrentId = currentDeviceId ?? appState?.resolvedMLSDeviceID()
        guard device.canRevoke(currentDeviceId: activeCurrentId) else {
            logger.warning("Blocked attempt to self-revoke or re-revoke device \(device.deviceId)")
            deleteError = NSError(
                domain: "DeviceManagement",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: Self.selfRevokeBlockedMessage]
            )
            return
        }

        do {
            logger.info("Revoking device: \(device.deviceId)")
            if let customRevoker = customRevokerForTesting {
                try await customRevoker(device.deviceId)
            } else {
                guard let appState else {
                    throw NSError(
                        domain: "DeviceManagement",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "No authenticated account session is active."]
                    )
                }
                guard let coordinator = await appState.getOrOpenMLSCoordinator() else {
                    throw NSError(
                        domain: "DeviceManagement",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: Self.coordinatorUnavailableMessage]
                    )
                }
                _ = try await coordinator.revokeLabyrinthDevice(targetDeviceId: device.deviceId)
                if let repo = try? ATIdentifier(string: appState.userDID),
                   let collection = try? NSID(nsidString: "blue.catbird.chat.device"),
                   let rkey = try? RecordKey(keyString: device.deviceId)
                {
                    _ = try? await appState.client.com.atproto.repo.deleteRecord(
                        input: .init(repo: repo, collection: collection, rkey: rkey)
                    )
                }
            }
            devices.removeAll { DeviceRowModel.matchesDeviceID($0.deviceId, device.deviceId) }
            deleteError = nil
        } catch {
            logger.error("Failed to revoke device: \(error.localizedDescription)")
            deleteError = error
        }
    }
}

#Preview("DeviceManagementView") {
  NavigationStack {
    DeviceManagementView()
  }
  .previewWithAuthenticatedState()
}
