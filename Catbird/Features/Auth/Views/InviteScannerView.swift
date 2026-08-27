import AVFoundation
import OSLog
import Petrel
import SwiftUI
#if canImport(VisionKit)
import VisionKit
#endif

/// QR code scanner view for scanning Bluesky profile invite codes (G66)
public struct InviteScannerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    
    public var onScannedProfile: ((String) -> Void)?
    
    @State private var cameraPermission: AVAuthorizationStatus = .notDetermined
    @State private var isScannerAvailable: Bool = false
    @State private var scannedPayload: String?
    @State private var errorMessage: String?
    @State private var manualHandleInput: String = ""
    @State private var showManualEntry: Bool = false
    
    private let logger = Logger(subsystem: "blue.catbird", category: "InviteScannerView")
    
    public init(onScannedProfile: ((String) -> Void)? = nil) {
        self.onScannedProfile = onScannedProfile
    }
    
    public var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                if cameraPermission == .denied || cameraPermission == .restricted {
                    permissionDeniedView
                } else if !isScannerAvailable {
                    scannerUnavailableView
                } else {
                    activeScannerView
                }
            }
            .navigationTitle("Scan QR Code")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
            .task {
                checkCameraPermissionAndAvailability()
            }
            .alert("Invalid QR Code", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("Try Again", role: .cancel) {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "This QR code does not link to a valid Bluesky profile.")
            }
        }
    }
    
    // MARK: - Active Scanner View
    
    private var activeScannerView: some View {
        ZStack {
            #if canImport(VisionKit)
            if #available(iOS 16.0, *), DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                DataScannerRepresentable { recognizedString in
                    handleScannedString(recognizedString)
                }
                .ignoresSafeArea()
            } else {
                scannerUnavailableView
            }
            #else
            scannerUnavailableView
            #endif
            
            // Scanner Overlay Reticle
            VStack {
                Spacer()
                
                ZStack {
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color.white.opacity(0.8), lineWidth: 3)
                        .frame(width: 260, height: 260)
                    
                    VStack(spacing: 8) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                
                Spacer()
                
                Text("Align the QR code within the frame")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Capsule())
                    .padding(.bottom, 40)
            }
        }
    }
    
    // MARK: - Fallback / Permission Views
    
    private var permissionDeniedView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "camera.badge.ellipsis")
                .font(.system(size: 64))
                .foregroundStyle(.white.opacity(0.8))
            
            VStack(spacing: 8) {
                Text("Camera Access Needed")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                
                Text("Please enable Camera access in iOS Settings to scan Bluesky profile QR codes.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            
            Spacer()
            
            VStack(spacing: 12) {
                Button {
                    #if os(iOS)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                    #endif
                } label: {
                    Text("Open Settings")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                
                Button("Enter Handle Manually") {
                    showManualEntry = true
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $showManualEntry) {
            manualHandleSheet
        }
    }
    
    private var scannerUnavailableView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "camera.slash.fill")
                .font(.system(size: 64))
                .foregroundStyle(.white.opacity(0.8))
            
            VStack(spacing: 8) {
                Text("Camera Scanner Unavailable")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                
                Text("QR code scanning is not supported on this device or simulator. You can enter a handle to find your friend.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            
            Spacer()
            
            VStack(spacing: 12) {
                Button {
                    showManualEntry = true
                } label: {
                    Text("Enter Handle Manually")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $showManualEntry) {
            manualHandleSheet
        }
    }
    
    private var manualHandleSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bluesky Handle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    
                    TextField("alice.bsky.social", text: $manualHandleInput)
                        .font(.body)
                        #if os(iOS)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        #endif
                        .padding(14)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                
                Spacer()
                
                Button {
                    let clean = manualHandleInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
                    if !clean.isEmpty {
                        navigateToProfile(handleOrDID: clean)
                    }
                } label: {
                    Text("Go to Profile")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(manualHandleInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .navigationTitle("Enter Handle")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showManualEntry = false
                    }
                }
            }
        }
    }
    
    // MARK: - Scanner Logic
    
    private func checkCameraPermissionAndAvailability() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        self.cameraPermission = status
        
        #if canImport(VisionKit)
        if #available(iOS 16.0, *) {
            self.isScannerAvailable = DataScannerViewController.isSupported && DataScannerViewController.isAvailable
        } else {
            self.isScannerAvailable = false
        }
        #else
        self.isScannerAvailable = false
        #endif
        
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    self.cameraPermission = granted ? .authorized : .denied
                }
            }
        }
    }
    
    private func handleScannedString(_ string: String) {
        guard let handleOrDID = InviteURLHelper.parseProfilePayload(string) else {
            logger.warning("Scanned invalid payload: \(string)")
            self.errorMessage = "The scanned QR code is not a valid Bluesky profile URL."
            return
        }
        
        logger.info("Successfully scanned Bluesky profile: \(handleOrDID)")
        navigateToProfile(handleOrDID: handleOrDID)
    }
    
    private func navigateToProfile(handleOrDID: String) {
        if let onScannedProfile {
            onScannedProfile(handleOrDID)
            dismiss()
        } else {
            // Dismiss scanner sheet and use app navigation
            dismiss()
            Task { @MainActor in
                if let url = URL(string: "https://bsky.app/profile/\(handleOrDID)") {
                    _ = appState.urlHandler.handle(url)
                }
            }
        }
    }
}

// MARK: - VisionKit Representable

#if canImport(VisionKit)
@available(iOS 16.0, *)
struct DataScannerRepresentable: UIViewControllerRepresentable {
    var onScanned: (String) -> Void
    
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }
    
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onScanned: onScanned)
    }
    
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onScanned: (String) -> Void
        private var hasFoundCode: Bool = false
        
        init(onScanned: @escaping (String) -> Void) {
            self.onScanned = onScanned
        }
        
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !hasFoundCode else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    hasFoundCode = true
                    dataScanner.stopScanning()
                    DispatchQueue.main.async {
                        self.onScanned(payload)
                    }
                    break
                }
            }
        }
    }
}
#endif
