import SwiftUI
import OSLog

/// Welcome onboarding sheet shown to new users after first login
struct WelcomeOnboardingView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  
  @State private var currentStep = 0
  @State private var showSecondScreen = false
  
  private let logger = Logger(subsystem: "blue.catbird", category: "WelcomeOnboarding")
  
  // Onboarding steps for the welcome flow
  private let steps = [
    OnboardingContent.welcome,
    OnboardingContent.feedDiscovery,
    OnboardingContent.postCreation,
    OnboardingContent.profileSetup
  ]
  
  var body: some View {
    NavigationStack {
      GeometryReader { geometry in
        VStack(spacing: 0) {
          // Main content area
          ScrollView {
            VStack(spacing: 32) {
              Spacer(minLength: 40)
              
              // App icon or step illustration
              if currentStep == 0 {
                // Catbird app icon for welcome
                Image("CatbirdIcon")
                  .resizable()
                  .frame(width: 120, height: 120)
                  .clipShape(RoundedRectangle(cornerRadius: 27))
                  .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
              } else {
                // System icons for other steps
                Image(systemName: steps[currentStep].imageName ?? "star.fill")
                  .font(.system(size: 64))
                  .foregroundStyle(.accent)
                  .symbolEffect(.pulse.wholeSymbol, options: .repeat(1))
              }
              
              // Title and description
              VStack(spacing: 16) {
                Text(steps[currentStep].title)
                  .font(.largeTitle)
                  .fontWeight(.bold)
                  .multilineTextAlignment(.center)
                
                Text(steps[currentStep].description)
                  .font(.body)
                  .foregroundStyle(.secondary)
                  .multilineTextAlignment(.center)
                  .lineLimit(nil)
              }
              .padding(.horizontal, 32)
              
              Spacer(minLength: 60)
            }
          }
          
          // Bottom action area
          VStack(spacing: 16) {
            // Progress indicator
            if steps.count > 1 {
              HStack(spacing: 8) {
                ForEach(0..<steps.count, id: \.self) { index in
                  RoundedRectangle(cornerRadius: 2)
                    .fill(index <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: index == currentStep ? 24 : 8, height: 4)
                    .animation(.easeInOut(duration: 0.3), value: currentStep)
                }
              }
              .padding(.bottom, 8)
            }
            
            // Action buttons
            VStack(spacing: 12) {
              // Primary button
              Button(action: primaryButtonAction) {
                Text(steps[currentStep].primaryButtonTitle)
                  .font(.headline)
                  .foregroundColor(.white)
                  .frame(maxWidth: .infinity)
                  .frame(height: 50)
                  .background(Color.accentColor)
                  .clipShape(RoundedRectangle(cornerRadius: 25))
              }
              
              // Secondary button (if available)
              if let secondaryTitle = steps[currentStep].secondaryButtonTitle {
                Button(action: secondaryButtonAction) {
                  Text(secondaryTitle)
                    .font(.body)
                    .foregroundColor(.secondary)
                }
              }
              
              // Skip button (if enabled)
              if steps[currentStep].showSkipButton && currentStep > 0 {
                Button("Skip for now") {
                  completeOnboarding()
                }
                .font(.caption)
                .foregroundColor(.secondary)
              }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, bottomPadding(for: geometry))
          }
          .background(.ultraThinMaterial)
        }
      }
      .modifier(PlatformNavigationModifier())
    }
    .modifier(PlatformPresentationModifier())
  }
  
  // MARK: - Platform Helpers
  
  private func bottomPadding(for geometry: GeometryProxy) -> CGFloat {
    #if os(iOS)
    max(geometry.safeAreaInsets.bottom, 24)
    #else
    24
    #endif
  }
  
  // MARK: - Actions
  
  private func primaryButtonAction() {
    logger.debug("Primary button tapped for step \(currentStep)")
    
    switch currentStep {
    case 0, 1, 2:
      // Navigate to next step
      withAnimation(.easeInOut(duration: 0.4)) {
        currentStep += 1
      }
    case 3:
      // Profile setup step - navigate to profile editing
      completeOnboarding()
      navigateToProfile()
    default:
      completeOnboarding()
    }
  }
  
  private func secondaryButtonAction() {
    logger.debug("Secondary button tapped for step \(currentStep)")
    
    // Usually "Maybe Later" - complete onboarding without action
    completeOnboarding()
  }
  
  private func completeOnboarding() {
    logger.info("Welcome onboarding completed")
    appState.onboardingManager.completeWelcomeOnboarding()
    dismiss()
  }
  
  private func navigateToProfile() {
    // Navigate to profile tab after dismissing onboarding
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    let currentUserDID = appState.userDID
      appState.navigationManager.navigate(to: .profile(currentUserDID), in: 3) // Profile tab
    }
  }
}

// MARK: - Platform-Specific ViewModifiers

private struct PlatformNavigationModifier: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
    content
      .toolbar(.hidden, for: .navigationBar)
    #elseif os(macOS)
    content
    #endif
  }
}

private struct PlatformPresentationModifier: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
    content
      .interactiveDismissDisabled()
    #elseif os(macOS)
    content
      .frame(minWidth: 480, minHeight: 600)
      .frame(maxWidth: 600, maxHeight: 800)
    #else
    content
    #endif
  }
}

// MARK: - Preview

#Preview {
    @Previewable @Environment(AppState.self) var appState
  WelcomeOnboardingView()
    .applyAppStateEnvironment(appState)
}
