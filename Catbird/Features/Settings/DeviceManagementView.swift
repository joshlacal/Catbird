import SwiftUI
import Petrel
import OSLog

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
                        Button("Retry") {
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
                            isCurrentDevice: device.deviceId == viewModel.currentDeviceId,
                            onDelete: {
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
        .task {
            await viewModel.initialize(appState: appState)
            await viewModel.loadDevices()
        }
        .alert("Delete Device", isPresented: $viewModel.showDeleteConfirmation, presenting: viewModel.deviceToDelete) { device in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteDevice(device)
                }
            }
        } message: { device in
            Text("Are you sure you want to delete '\(device.deviceName)'? This will remove all key packages associated with this device.")
        }
        .alert("Error", isPresented: .constant(viewModel.deleteError != nil)) {
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

struct DeviceRow: View {
    let device: BlueCatbirdMlsListDevices.DeviceInfo
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
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.2))
                                .foregroundStyle(.blue)
                                .cornerRadius(4)
                        }
                    }

                    Text(formatDate(device.lastSeenAt.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                Text("UUID: \(deviceUUID.prefix(8))...")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Device", systemImage: "trash")
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

    var devices: [BlueCatbirdMlsListDevices.DeviceInfo] = []
    var isLoading = false
    var error: Error?
    var deleteError: Error?
    var showDeleteConfirmation = false
    var deviceToDelete: BlueCatbirdMlsListDevices.DeviceInfo?
    var currentDeviceId: String?

    private var appState: AppState?

    func initialize(appState: AppState) async {
        self.appState = appState
        // MLSDeviceManager is created internally by MLSAPIClient
        // We'll get the device ID from loaded devices instead
    }

    @MainActor
    func loadDevices() async {
        guard let client = appState?.client else {
            logger.error("No authenticated client available")
            return
        }

        isLoading = true
        error = nil

        do {
            logger.info("Loading devices...")
            let (_, output) = try await client.blue.catbird.mls.listDevices(input: .init())
            devices = output?.devices ?? []
            logger.info("Loaded \(self.devices.count) devices")
        } catch {
            logger.error("Failed to load devices: \(error.localizedDescription)")
            self.error = error
        }

        isLoading = false
    }

    @MainActor
    func deleteDevice(_ device: BlueCatbirdMlsListDevices.DeviceInfo) async {
        guard let client = appState?.client else {
            logger.error("No authenticated client available")
            return
        }

        do {
            logger.info("Deleting device: \(device.deviceId)")

            let input = BlueCatbirdMlsDeleteDevice.Input(deviceId: device.deviceId)
            let (_, output) = try await client.blue.catbird.mls.deleteDevice(input: input)

            let deleted = output?.deleted ?? false
            let packagesDeleted = output?.keyPackagesDeleted ?? 0
            logger.info("Device deleted: \(deleted), key packages deleted: \(packagesDeleted)")

            // Remove from local list
            devices.removeAll { $0.deviceId == device.deviceId }
        } catch {
            logger.error("Failed to delete device: \(error.localizedDescription)")
            deleteError = error
        }
    }
}

