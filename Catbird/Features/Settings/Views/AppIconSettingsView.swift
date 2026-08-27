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
                                .font(.body)
                                .foregroundStyle(.primary)
                            
                            Spacer()
                            
                            if currentIconChoice == choice {
                                Image(systemName: "checkmark")
                                    .font(.headline)
                                    .foregroundStyle(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSettingIcon)
                }
            } header: {
                Text("Choose App Icon")
            } footer: {
                Text("Select an alternate icon for your device Home Screen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("App Icon")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            updateCurrentIcon()
        }
        .alert("App Icon", isPresented: $showErrorAlert) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }
    
    @ViewBuilder
    private func iconPreview(for choice: AppIconChoice) -> some View {
        Image("catbird head square")
            .resizable()
            .scaledToFit()
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
    }
    
    @MainActor
    private func updateCurrentIcon() {
        #if os(iOS)
        if let alternateName = UIApplication.shared.alternateIconName {
            currentIconChoice = AppIconChoice(rawValue: alternateName) ?? .classic
        } else {
            currentIconChoice = .default
        }
        #endif
    }
    
    @MainActor
    private func setIcon(_ choice: AppIconChoice) {
        #if os(iOS)
        guard UIApplication.shared.supportsAlternateIcons else {
            errorMessage = "Alternate icons are not supported on this device."
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
                errorMessage = error.localizedDescription
                showErrorAlert = true
            }
        }
        #endif
    }
}
