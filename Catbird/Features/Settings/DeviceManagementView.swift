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
            if viewModel.recoveryNeedsAttention && viewModel.revocationReceipt == nil {
                Section {
                    Label(
                        !viewModel.hasCurrentRecoveryCode
                            ? "Encrypted-backup recovery rotated, but the one-time replacement details are no longer available on this device. Open Labyrinth Backup & Recovery and generate a new recovery code. Recovery remains not ready until you save and confirm it."
                            : "A replacement recovery code is stored securely on this device. Open Labyrinth Backup & Recovery to save and confirm it before recovery can become ready.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("device-management-unavailable-recovery-material-warning")
                }
            }
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
                            .appFont(AppTextRole.headline)
                            .foregroundStyle(.red)
                        Text(error.localizedDescription)
                            .appFont(AppTextRole.caption)
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
                            .appFont(AppTextRole.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No Devices Found")
                            .appFont(AppTextRole.headline)
                        Text("Register a device to enable MLS messaging")
                            .appFont(AppTextRole.caption)
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
                            onApprove: device.activityState == .pendingApproval
                                && !device.isCurrentDevice(currentDeviceId: viewModel.currentDeviceId)
                                ? {
                                    Task {
                                        await viewModel.approveDevice(device)
                                    }
                                }
                                : nil,
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
        .onChange(of: appState.pendingMLSDeviceRevocationReceipt) { _, _ in
            Task { await viewModel.refreshRecoveryMaterial() }
        }
        .onChange(of: appState.pendingMLSRecoveryCodeReceipt) { _, _ in
            Task { await viewModel.refreshRecoveryMaterial() }
        }
        .onChange(of: appState.mlsCoordinator?.changeRevision) { _, _ in
            if case .labyrinthStatusChanged = appState.mlsCoordinator?.lastChangeEvent {
                Task { await viewModel.refreshRecoveryMaterial() }
            }
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
        .alert("Couldn’t Revoke Device", isPresented: Binding(get: { viewModel.deleteError != nil }, set: { if !$0 { viewModel.deleteError = nil } })) {
            Button("OK") {
                viewModel.deleteError = nil
            }
        } message: {
            if let error = viewModel.deleteError {
                Text(error.localizedDescription)
            }
        }
        .sheet(item: $viewModel.revocationReceipt) { receipt in
            DeviceRevocationReceiptSheet(receipt: receipt) {
                guard let generation = receipt.recoveryGeneration, generation > 0,
                      let coordinator = await appState.getOrOpenMLSCoordinator() else {
                    return false
                }
                guard await appState.acknowledgePendingMLSDeviceRevocationReceipt(
                    expected: receipt, nativeAcknowledger: {
                        _ = try await coordinator.acknowledgeRecoveryGeneration(expectedGeneration: generation)
                    }
                ) else {
                    return false
                }
                viewModel.revocationReceipt = nil
                await viewModel.refreshRecoveryMaterial()
                return true
            }
        }
    }
}

struct DeviceRevocationReceiptSheet: View {
    let receipt: AppState.PendingMLSDeviceRevocationReceipt
    let acknowledge: @MainActor () async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var confirmedLostDeviceRemoved = false
    @State private var acknowledgementError = false
    @State private var isAcknowledging = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(
                        receipt.dsRevoked
                            ? (receipt.replacementRecoveryCode == nil
                                ? "The device was revoked. Review this report before leaving the screen."
                                : "The device was revoked. Save the replacement recovery code before leaving this screen.")
                            : "The revocation report is incomplete. Review every result and retry from the device list.",
                        systemImage: receipt.dsRevoked
                            ? "checkmark.shield.fill"
                            : "exclamationmark.shield.fill"
                    )
                    .foregroundStyle(receipt.dsRevoked ? .green : .orange)
                    LabeledContent("Revoked Device") {
                        Text(receipt.targetDeviceId)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Directory Revoked", value: receipt.dsRevoked ? "Yes" : "No")
                    LabeledContent("Groups Updated", value: "\(receipt.groupsUpdated)")
                    LabeledContent("Backup Rotated", value: receipt.labyrinthRotated ? "Yes" : "No")
                    if let epoch = receipt.newEpochSeq {
                        LabeledContent("New Backup Epoch", value: "\(epoch)")
                    }
                    LabeledContent("Device Record Removed", value: receipt.pdsRecordDeleted ? "Yes" : "No")
                    LabeledContent("Passkey Recovery Bundles Re-keyed", value: "\(receipt.rekeyedPasskeyCount)")
                } header: {
                    Text("Revocation Report")
                }

                if let code = receipt.replacementRecoveryCode {
                    Section {
                        Text(code)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("device-revocation-replacement-recovery-code")
                    } header: {
                        Text("Replacement Recovery Code")
                    } footer: {
                        Text("Your previous recovery code no longer works. Store this replacement in your password manager.")
                    }
                }

                if receipt.dsRevoked {
                    Section {
                        Toggle(
                            "I removed or secured the revoked device in my Apple or Google account",
                            isOn: $confirmedLostDeviceRemoved
                        )
                        .accessibilityIdentifier("device-revocation-confirm-account-device-removed")
                    } header: {
                        Text("Before Registering Another Passkey")
                    } footer: {
                        Text("Catbird invalidated the revoked device’s remote recovery bundles. Before registering a replacement passkey, remove or secure the device in its Apple or Google account so a synced passkey cannot return to an unsafe device.")
                    }
                }

                if acknowledgementError {
                    Section {
                        Label(
                            "Catbird couldn’t save your acknowledgement. The securely stored report remains available; try again.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(receipt.replacementRecoveryCode == nil ? "Acknowledge Report" : "I Saved This Code") {
                        guard !isAcknowledging else { return }
                        isAcknowledging = true
                        Task { @MainActor in
                            defer { isAcknowledging = false }
                            if await acknowledge() {
                                dismiss()
                            } else {
                                acknowledgementError = true
                            }
                        }
                    }
                    .disabled(
                        isAcknowledging
                            || (receipt.dsRevoked && !confirmedLostDeviceRemoved)
                    )
                    .accessibilityIdentifier("device-revocation-acknowledge-report")
                }
            }
            .navigationTitle("Device Revocation Report")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .interactiveDismissDisabled()
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
        case .active: String(localized: "Active", comment: "MLS device status badge.")
        case .dormant: String(localized: "Dormant", comment: "MLS device status badge.")
        case .pendingApproval: String(localized: "Pending Approval", comment: "MLS device status badge.")
        case .revoked: String(localized: "Revoked", comment: "MLS device status badge.")
        }
    }

    var badgeTone: CatbirdBadgeTone {
        switch self {
        case .active: .success
        case .dormant, .pendingApproval: .warning
        case .revoked: .neutral
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

    init(
        _ registered: RegisteredDeviceInfo,
        keyPackageCount: Int = 0,
        currentDeviceId: String? = nil,
        now: Date = Date()
    ) {
        let isCurrent = registered.isCurrentDevice || Self.matchesDeviceID(registered.deviceId, currentDeviceId)
        let parsedLastActive = Self.parseISO8601(registered.lastActiveAt)
        let parsedCreated = Self.parseISO8601(registered.createdAt) ?? now
        let effectiveLastSeen = parsedLastActive ?? parsedCreated
        let parsedDormantAt = Self.parseISO8601(registered.dormantAt)

        let resolvedState: MLSDeviceActivityState
        switch registered.status {
        case "revoked":
            resolvedState = .revoked
        case "pending_approval":
            resolvedState = .pendingApproval
        case "dormant":
            resolvedState = isCurrent ? .active : .dormant
        default:
            if isCurrent {
                resolvedState = .active
            } else if parsedDormantAt != nil
                || now.timeIntervalSince(effectiveLastSeen) >= MLSDeviceActivityState.dormancyThresholdSeconds
            {
                resolvedState = .dormant
            } else {
                resolvedState = .active
            }
        }

        self.init(
            deviceId: registered.deviceId,
            deviceName: registered.deviceName,
            deviceUUID: nil,
            lastSeenAt: effectiveLastSeen,
            keyPackageCount: keyPackageCount,
            activityState: resolvedState,
            currentDeviceId: isCurrent ? registered.deviceId : currentDeviceId,
            now: now
        )
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
    var onApprove: (() -> Void)? = nil
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(device.deviceName)
                            .appFont(AppTextRole.headline)
                        if isCurrentDevice {
                            CatbirdBadge("This Device", tone: .accent)
                                .accessibilityIdentifier("device-this-device-badge")
                        }
                        CatbirdBadge(Text(device.activityState.badgeTitle), tone: device.activityState.badgeTone)
                            .accessibilityIdentifier("device-status-badge-\(device.activityState.rawValue)")
                    }

                    Text(verbatim: "\(device.deviceId.prefix(8))… · \(formatDate(device.lastSeenAt))")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)

                    if isCurrentDevice {
                        Text("Sign out in Account & Security to remove this device.")
                            .appFont(AppTextRole.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    if let onApprove {
                        Button("Approve") {
                            onApprove()
                        }
                        .buttonStyle(.catbird(.primary, size: .sm))
                        .accessibilityIdentifier("device-approve-\(device.deviceId)")
                    }
                    Label {
                        Text(device.keyPackageCount, format: .number)
                            .appFont(AppTextRole.caption)
                    } icon: {
                        Image(systemName: "key.fill")
                            .appFont(AppTextRole.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            if let deviceUUID = device.deviceUUID {
                Text(verbatim: "UUID: \(deviceUUID.prefix(8))…")
                    .appFont(AppTextRole.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            if let onApprove {
                Button {
                    onApprove()
                } label: {
                    Label("Approve", systemImage: "checkmark.shield")
                }
                .tint(.green)
            }
            if !isCurrentDevice && device.activityState != .revoked {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Revoke", systemImage: "trash")
                }
            }
        }
        .contextMenu {
            if let onApprove {
                Button {
                    onApprove()
                } label: {
                    Label("Approve Device", systemImage: "checkmark.shield")
                }
            }
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
            return String(localized: "Last seen \(days) days ago", comment: "Relative timestamp showing how many days ago a device was last active.")
        } else if let hours = components.hour, hours > 0 {
            return String(localized: "Last seen \(hours) hours ago", comment: "Relative timestamp showing how many hours ago a device was last active.")
        } else if let minutes = components.minute, minutes > 0 {
            return String(localized: "Last seen \(minutes) minutes ago", comment: "Relative timestamp showing how many minutes ago a device was last active.")
        } else {
            return String(localized: "Last seen just now", comment: "Relative timestamp showing a device was active moments ago.")
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
    var revocationReceipt: AppState.PendingMLSDeviceRevocationReceipt?
    var recoveryNeedsAttention = false
    var hasCurrentRecoveryCode = false
    var currentDeviceId: String?
    private var latestRecoveryGeneration: UInt64 = 0
    var customRevokerForTesting:
        (@MainActor (_ targetDeviceId: String) async throws -> AppState.PendingMLSDeviceRevocationReceipt?)?

    private var appState: AppState?

    @MainActor
    func initialize(appState: AppState) async {
        if self.appState?.userDID != appState.userDID {
            latestRecoveryGeneration = 0
            revocationReceipt = nil
            hasCurrentRecoveryCode = false
        }
        self.appState = appState
        self.currentDeviceId = appState.resolvedMLSDeviceID()
    }

    @MainActor
    func refreshRecoveryMaterial() async {
        guard let appState, let coordinator = await appState.getOrOpenMLSCoordinator(),
              let status = try? await coordinator.labyrinthStatus() else {
            recoveryNeedsAttention = true
            hasCurrentRecoveryCode = false
            revocationReceipt = nil
            return
        }
        applyRecoveryStatus(status, appState: appState)
    }

    @MainActor
    private func applyRecoveryStatus(_ status: LabyrinthBackupStatus, appState: AppState) {
        guard self.appState === appState, status.recoveryGeneration >= latestRecoveryGeneration else { return }
        latestRecoveryGeneration = status.recoveryGeneration
        hasCurrentRecoveryCode = appState.pendingMLSRecoveryCodeReceipt?.isCurrent(for: status) == true
        revocationReceipt = appState.pendingMLSDeviceRevocationReceipt.flatMap { $0.isCurrent(for: status) ? $0 : nil }
        recoveryNeedsAttention = status.recoveryNeedsAttention || hasCurrentRecoveryCode || revocationReceipt != nil
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
            let coordinator = await appState.getOrOpenMLSCoordinator()
            if let coordinator,
               let backupStatus = try? await coordinator.labyrinthStatus()
            {
                applyRecoveryStatus(backupStatus, appState: appState)
            }

            var keyPackagesByDeviceID: [String: Int] = [:]
            var fallbackOwnDevices: [BlueCatbirdChatDefs.OwnDeviceView] = []
            if let mlsClient = await appState.getMLSAPIClient(),
               let output = try? await mlsClient.getOwnDevices(actorDeviceId: actorDeviceId)
            {
                fallbackOwnDevices = output.items
                for item in output.items {
                    keyPackagesByDeviceID[item.device.deviceId.lowercased()] = item.device.availablePackageCount
                }
            }

            let loaded: [DeviceRowModel]
            if let coordinator,
               let registered = try? await coordinator.listDevices(),
               !registered.isEmpty
            {
                loaded = registered.map { reg in
                    let pkgCount = keyPackagesByDeviceID[reg.deviceId.lowercased()] ?? 0
                    return DeviceRowModel(
                        reg,
                        keyPackageCount: pkgCount,
                        currentDeviceId: actorDeviceId
                    )
                }
            } else if !fallbackOwnDevices.isEmpty {
                loaded = fallbackOwnDevices.map { DeviceRowModel($0, currentDeviceId: actorDeviceId) }
            } else {
                guard let mlsClient = await appState.getMLSAPIClient() else {
                    devices = []
                    isLoading = false
                    return
                }
                let output = try await mlsClient.getOwnDevices(actorDeviceId: actorDeviceId)
                loaded = output?.items.map { DeviceRowModel($0, currentDeviceId: actorDeviceId) } ?? []
            }

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

    @MainActor
    func approveDevice(_ device: DeviceRowModel) async {
        guard let appState else { return }
        do {
            guard let coordinator = await appState.getOrOpenMLSCoordinator() else {
                throw NSError(
                    domain: "DeviceManagement",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: Self.coordinatorUnavailableMessage]
                )
            }
            try await coordinator.approveDevice(targetDeviceId: device.deviceId)
            deleteError = nil
            await loadDevices()
        } catch {
            logger.error("Failed to approve device \(device.deviceId): \(error.localizedDescription)")
            deleteError = error
        }
    }

    static let selfRevokeBlockedMessage =
        "You cannot revoke the device you are currently using. Sign out in Account & Security to remove this device."
    static let coordinatorUnavailableMessage =
        "Encrypted chat coordinator is unavailable. Open Messages and try revoking this device again."
    static let incompleteRevocationMessage =
        "The server returned an incomplete device revocation report. The device remains listed so you can retry."

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
            var receiptPersistenceError: Error?
            if let customRevoker = customRevokerForTesting {
                revocationReceipt = try await customRevoker(device.deviceId)
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
                let report = try await coordinator.revokeDevice(targetDeviceId: device.deviceId)
                do {
                    _ = try appState.retainDeviceRevocationReport(report)
                } catch {
                    // The report remains visible in memory; surface the storage failure as well so
                    // the user does not mistake it for a durable save.
                    receiptPersistenceError = error
                }
                await refreshRecoveryMaterial()
                guard report.dsRevoked else {
                    throw NSError(domain: "DeviceManagement", code: 4, userInfo: [NSLocalizedDescriptionKey: Self.incompleteRevocationMessage])
                }
            }
            if revocationReceipt?.labyrinthRotated == true {
                recoveryNeedsAttention = true
            }
            guard revocationReceipt?.dsRevoked != false else {
                throw NSError(
                    domain: "DeviceManagement",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: Self.incompleteRevocationMessage]
                )
            }
            devices.removeAll { DeviceRowModel.matchesDeviceID($0.deviceId, device.deviceId) }
            deleteError = receiptPersistenceError
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
