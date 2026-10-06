import SwiftUI
#if os(iOS)
import UIKit
#endif
import OSLog

public enum AppIconChoice: String, CaseIterable, Identifiable {
    case `default` = "Default"
    case classic = "CatbirdClassic"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .default: return "Default"
        case .classic: return "Classic"
        }
    }
    
    public var alternateIconName: String? {
        switch self {
        case .default: return nil
        case .classic: return "CatbirdClassic"
        }
    }

    /// An image set that shows what the icon looks like; app icon sets can't be loaded as images.
    var previewImageName: String {
        switch self {
        case .default: return "CatbirdIcon"
        case .classic: return "AppIconPreviewClassic"
        }
    }

    /// The choice matching the icon currently on the Home Screen.
    @MainActor static var current: AppIconChoice {
        #if os(iOS)
        guard let alternateName = UIApplication.shared.alternateIconName else { return .default }
        return AppIconChoice(rawValue: alternateName) ?? .classic
        #else
        return .default
        #endif
    }
}

struct AppIconSettingsView: View {
    @State private var currentIconChoice: AppIconChoice = .default
    @State private var errorMessage: String?
    @State private var showErrorAlert = false
    @State private var isSettingIcon = false
    
    private let logger = Logger(subsystem: "blue.catbird", category: "AppIconSettings")
    
    var body: some View {
        Form {
            Section {
                ForEach(AppIconChoice.allCases) { choice in
                    Button {
                        setIcon(choice)
                    } label: {
                        HStack(spacing: 16) {
                            iconPreview(for: choice)
                            
                            Text(choice.displayName)
                                .appFont(AppTextRole.body)
                                .foregroundStyle(Color.primary)
                            
                            Spacer()
                            
                            if currentIconChoice == choice {
                                Image(systemName: "checkmark")
                                    .appFont(AppTextRole.headline)
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSettingIcon)
                    .accessibilityLabel(choice.displayName)
                    .accessibilityAddTraits(currentIconChoice == choice ? .isSelected : [])
                }
            } header: {
                Text("Choose App Icon")
            } footer: {
                Text("Choose the icon Catbird uses on this device’s Home Screen.")
            }
        }
        .navigationTitle("App Icon")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            updateCurrentIcon()
        }
        .alert("Couldn’t Change App Icon", isPresented: $showErrorAlert) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? "Try again.")
        }
    }
    
    @ViewBuilder
    private func iconPreview(for choice: AppIconChoice) -> some View {
        Image(choice.previewImageName)
            .resizable()
            .scaledToFit()
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
    
    @MainActor
    private func updateCurrentIcon() {
        currentIconChoice = AppIconChoice.current
    }
    
    @MainActor
    private func setIcon(_ choice: AppIconChoice) {
        #if os(iOS)
        guard UIApplication.shared.supportsAlternateIcons else {
            errorMessage = "This device doesn’t support changing the app icon."
            showErrorAlert = true
            return
        }
        
        guard choice != currentIconChoice else { return }
        let previousChoice = currentIconChoice
        isSettingIcon = true
        
        Task { @MainActor in
            defer { isSettingIcon = false }
            do {
                try await UIApplication.shared.setAlternateIconName(choice.alternateIconName)
                currentIconChoice = choice
                logger.info("Successfully changed alternate app icon to \(choice.rawValue)")
            } catch {
                logger.error("Failed to change alternate app icon: \(error.localizedDescription)")
                currentIconChoice = previousChoice
                errorMessage = "Catbird couldn’t change the app icon. Try again."
                showErrorAlert = true
            }
        }
        #endif
    }
}
