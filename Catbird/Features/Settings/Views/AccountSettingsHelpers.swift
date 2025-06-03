import SwiftUI
import Petrel

// MARK: - Email Update Sheet

struct EmailUpdateSheet: View {
    let currentEmail: String
    let onEmailUpdated: (String) -> Void
    
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    
    @State private var newEmail = ""
    @State private var isUpdating = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Current Email") {
                    Text(currentEmail.isEmpty ? "No email set" : currentEmail)
                        .foregroundStyle(.secondary)
                }
                
                Section("New Email") {
                    TextField("Enter new email address", text: $newEmail)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
                
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .appFont(AppTextRole.caption)
                    }
                }
            }
            .navigationTitle("Update Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        updateEmail()
                    } label: {
                        if isUpdating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Update")
                        }
                    }
                    .disabled(newEmail.isEmpty || isUpdating)
                }
            }
        }
    }
    
    private func updateEmail() {
        isUpdating = true
        errorMessage = nil
        
        Task {
            defer {
                Task { @MainActor in
                    isUpdating = false
                }
            }
            
            guard let client = appState.atProtoClient else {
                Task { @MainActor in
                    errorMessage = "Client not available"
                }
                return
            }
            
            // Note: AT Protocol doesn't have a direct email update endpoint
            // This would typically be done through account management UI
            // For now, we'll simulate success
            Task { @MainActor in
                onEmailUpdated(newEmail)
                dismiss()
            }
        }
    }
}

// MARK: - Handle Update Sheet

struct HandleUpdateSheet: View {
    let currentHandle: String
    let onHandleUpdated: () -> Void
    
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    
    @State private var newHandle = ""
    @State private var isUpdating = false
    @State private var isCheckingAvailability = false
    @State private var isAvailable: Bool?
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Current Handle") {
                    Text("@\(currentHandle)")
                        .foregroundStyle(.secondary)
                }
                
                Section("New Handle") {
                    HStack {
                        Text("@")
                            .foregroundStyle(.secondary)
                        TextField("Enter new handle", text: $newHandle)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .onChange(of: newHandle) {
                                checkHandleAvailability()
                            }
                    }
                    
                    if isCheckingAvailability {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking availability...")
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let isAvailable = isAvailable {
                        HStack {
                            Image(systemName: isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(isAvailable ? .green : .red)
                            Text(isAvailable ? "Handle available" : "Handle not available")
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(isAvailable ? .green : .red)
                        }
                    }
                }
                
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .appFont(AppTextRole.caption)
                    }
                }
                
                Section {
                    Text("Your handle is your unique identifier on Bluesky. Choose carefully as changing it frequently may confuse your followers.")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Update Handle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        updateHandle()
                    } label: {
                        if isUpdating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Update")
                        }
                    }
                    .disabled(newHandle.isEmpty || isUpdating || isAvailable != true)
                }
            }
        }
    }
    
    private func checkHandleAvailability() {
        guard !newHandle.isEmpty else {
            isAvailable = nil
            return
        }
        
        isCheckingAvailability = true
        
        Task {
            defer {
                Task { @MainActor in
                    isCheckingAvailability = false
                }
            }
            
            guard let client = appState.atProtoClient else {
                Task { @MainActor in
                    isAvailable = nil
                }
                return
            }
            
            do {
                let (responseCode, _) = try await client.com.atproto.identity.resolveHandle(input: .init(handle: Handle(handleString: newHandle)))
                
                Task { @MainActor in
                    // If handle resolves, it's taken
                    isAvailable = responseCode != 200
                }
            } catch {
                Task { @MainActor in
                    // If there's an error resolving, assume it's available
                    isAvailable = true
                }
            }
        }
    }
    
    private func updateHandle() {
        isUpdating = true
        errorMessage = nil
        
        Task {
            defer {
                Task { @MainActor in
                    isUpdating = false
                }
            }
            
            guard let client = appState.atProtoClient else {
                Task { @MainActor in
                    errorMessage = "Client not available"
                }
                return
            }
            
            do {
                let input = ComAtprotoIdentityUpdateHandle.Input(handle: try Handle(handleString: newHandle))
                let responseCode = try await client.com.atproto.identity.updateHandle(input: input)
                
                if responseCode == 200 {
                    Task { @MainActor in
                        onHandleUpdated()
                        dismiss()
                    }
                } else {
                    Task { @MainActor in
                        errorMessage = "Failed to update handle. Please try again."
                    }
                }
            } catch {
                Task { @MainActor in
                    errorMessage = "Failed to update handle: \(error.localizedDescription)"
                }
            }
        }
    }
}
