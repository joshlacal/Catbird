import CoreImage.CIFilterBuiltins
import OSLog
import Petrel
import SwiftUI

/// Six visual themes for the QR invite card
public enum InviteTheme: String, CaseIterable, Identifiable, Sendable {
    case dawn = "Dawn"
    case sunlight = "Sunlight"
    case day = "Day"
    case dusk = "Dusk"
    case twilight = "Twilight"
    case night = "Night"
    
    public var id: String { rawValue }
    
    public var gradientColors: [Color] {
        switch self {
        case .dawn:
            return [Color(red: 1.0, green: 0.88, blue: 0.88), Color(red: 0.98, green: 0.70, blue: 0.70)]
        case .sunlight:
            return [Color(red: 1.0, green: 0.95, blue: 0.75), Color(red: 1.0, green: 0.78, blue: 0.38)]
        case .day:
            return [Color(red: 0.85, green: 0.93, blue: 1.0), Color(red: 0.58, green: 0.80, blue: 0.98)]
        case .dusk:
            return [Color(red: 0.95, green: 0.55, blue: 0.40), Color(red: 0.58, green: 0.28, blue: 0.65)]
        case .twilight:
            return [Color(red: 0.35, green: 0.25, blue: 0.60), Color(red: 0.15, green: 0.15, blue: 0.40)]
        case .night:
            return [Color(red: 0.15, green: 0.18, blue: 0.25), Color(red: 0.08, green: 0.09, blue: 0.14)]
        }
    }
    
    public var isDark: Bool {
        switch self {
        case .dawn, .sunlight, .day:
            return false
        case .dusk, .twilight, .night:
            return true
        }
    }
    
    public var foregroundColor: Color {
        isDark ? .white : .black
    }
    
    public var secondaryForegroundColor: Color {
        isDark ? Color.white.opacity(0.8) : Color.black.opacity(0.7)
    }
    
    public var qrBackgroundColor: Color {
        .white
    }
    
    public var qrForegroundColor: Color {
        .black
    }
    
    public var borderColor: Color {
        isDark ? Color.white.opacity(0.2) : Color.black.opacity(0.1)
    }
}

/// Helper for generating canonical invite URLs and QR codes
public enum InviteURLHelper {
    public static func canonicalInviteURL(for handle: String) -> URL? {
        let clean = handle.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !clean.isEmpty else { return nil }
        return URL(string: "https://bsky.app/profile/\(clean)")
    }
    
    public static func parseProfilePayload(_ payload: String) -> String? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        let urlString: String
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            urlString = "https://\(trimmed)"
        } else {
            urlString = trimmed
        }
        
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased(),
              host == "bsky.app" || host == "www.bsky.app" else {
            return nil
        }
        
        let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard components.count >= 2, components[0].lowercased() == "profile" else {
            return nil
        }
        
        let handleOrDID = components[1].trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !handleOrDID.isEmpty else { return nil }
        return handleOrDID
    }
    
    public static func generateQRCode(from string: String, size: CGFloat = 200) -> UIImage? {
        guard let data = string.data(using: .utf8) else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        
        guard let outputImage = filter.outputImage else { return nil }
        
        let scaleX = size / outputImage.extent.size.width
        let scaleY = size / outputImage.extent.size.height
        let transformedImage = outputImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(transformedImage, from: transformedImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

/// Themed QR code card and invite sharing view (G66)
public struct InviteFriendsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedTheme: InviteTheme = .day
    @State private var showScanner: Bool = false
    @State private var copiedToClipboard: Bool = false

    private let logger = Logger(subsystem: "blue.catbird", category: "InviteFriendsView")
    
    public init() {}
    
    private var currentHandle: String {
        appState.currentUserProfile?.handle.description ?? "user.bsky.social"
    }
    
    private var currentDisplayName: String {
        appState.currentUserProfile?.displayName ?? currentHandle
    }
    
    private var currentAvatarURL: URL? {
        guard let avatar = appState.currentUserProfile?.avatar else { return nil }
        return URL(string: avatar.uriString())
    }
    
    private var inviteURL: URL {
        InviteURLHelper.canonicalInviteURL(for: currentHandle) ?? URL(string: "https://bsky.app")!
    }
    
    private var storageKey: String {
        let did = appState.userDID
        return "invite.theme.\(did)"
    }
    
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Top Description
                    VStack(spacing: 6) {
                        Text("Invite Friends")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        Text("Share your personal QR code or invite link to connect on Bluesky.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .padding(.top, 8)
                    
                    // Themed QR Card View
                    qrCardView
                        .padding(.horizontal, 24)
                    
                    // Theme Selector Chips
                    themeSelector
                        .padding(.horizontal, 16)
                    
                    // Action Buttons
                    VStack(spacing: 12) {
                        // Share Card Link / Image
                        ShareLink(
                            item: inviteURL,
                            subject: Text("Connect with me on Bluesky"),
                            message: Text("Find me on Bluesky @\(currentHandle): \(inviteURL.absoluteString)")
                        ) {
                            HStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.up")
                                Text("Share Invite Link")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        
                        // Copy Link Button
                        Button {
                            handleCopyLink()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: copiedToClipboard ? "checkmark" : "doc.on.doc")
                                Text(copiedToClipboard ? "Link Copied!" : "Copy Link")
                                    .fontWeight(.medium)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color(uiColor: .secondarySystemGroupedBackground))
                            .foregroundColor(copiedToClipboard ? .green : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        
                        // Scan QR Code Button
                        Button {
                            showScanner = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "qrcode.viewfinder")
                                Text("Scan a QR Code")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                            .foregroundStyle(Color.accentColor)
                            .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Invite Friends")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showScanner) {
                InviteScannerView()
            }
            .onAppear {
                loadSavedTheme()
            }
        }
    }
    
    // MARK: - Themed QR Card View
    
    private var qrCardView: some View {
        VStack(spacing: 18) {
            // Profile Header
            HStack(spacing: 12) {
                if let currentAvatarURL {
                    AsyncImage(url: currentAvatarURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Circle().fill(Color.white.opacity(0.3))
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(selectedTheme.foregroundColor.opacity(0.2), lineWidth: 1.5))
                } else {
                    Circle()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 48, height: 48)
                        .overlay {
                            Text(String(currentDisplayName.prefix(1)).uppercased())
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundStyle(selectedTheme.foregroundColor)
                        }
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentDisplayName)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(selectedTheme.foregroundColor)
                        .lineLimit(1)
                    
                    Text("@\(currentHandle)")
                        .font(.subheadline)
                        .foregroundStyle(selectedTheme.secondaryForegroundColor)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Image(systemName: "butterfly.fill")
                    .font(.title2)
                    .foregroundStyle(selectedTheme.foregroundColor.opacity(0.8))
            }
            .padding(.horizontal, 4)
            
            // Generated QR Code
            if let qrImage = InviteURLHelper.generateQRCode(from: inviteURL.absoluteString, size: 220) {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .padding(14)
                    .background(selectedTheme.qrBackgroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
            } else {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.white)
                    .frame(width: 200, height: 200)
                    .overlay {
                        ProgressView()
                    }
            }
            
            // Footer URL label
            Text(inviteURL.absoluteString)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(selectedTheme.secondaryForegroundColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(22)
        .background(
            LinearGradient(
                colors: selectedTheme.gradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(selectedTheme.borderColor, lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 6)
    }
    
    // MARK: - Theme Selector
    
    private var themeSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Card Theme")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 8)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(InviteTheme.allCases) { theme in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedTheme = theme
                                saveTheme(theme)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: theme.gradientColors,
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 18, height: 18)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                                    )
                                
                                Text(theme.rawValue)
                                    .font(.subheadline)
                                    .fontWeight(selectedTheme == theme ? .semibold : .regular)
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                selectedTheme == theme
                                    ? Color(uiColor: .tertiarySystemGroupedBackground)
                                    : Color(uiColor: .secondarySystemGroupedBackground)
                            )
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(
                                        selectedTheme == theme ? Color.accentColor : Color.clear,
                                        lineWidth: 1.5
                                    )
                            )
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }
    
    // MARK: - Actions
    
    private func handleCopyLink() {
        #if os(iOS)
        UIPasteboard.general.string = inviteURL.absoluteString
        #endif
        copiedToClipboard = true
        
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copiedToClipboard = false
        }
    }
    
    private func loadSavedTheme() {
        if let savedName = UserDefaults.standard.string(forKey: storageKey),
           let theme = InviteTheme(rawValue: savedName) {
            selectedTheme = theme
        }
    }
    
    private func saveTheme(_ theme: InviteTheme) {
        UserDefaults.standard.set(theme.rawValue, forKey: storageKey)
    }
}
