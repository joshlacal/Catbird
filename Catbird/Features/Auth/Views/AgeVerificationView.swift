import SwiftUI
import OSLog

struct AgeVerificationView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedDate = Calendar.current.date(byAdding: .year, value: -20, to: Date()) ?? Date()
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingError = false
    
    private let logger = Logger(subsystem: "blue.catbird", category: "AgeVerificationView")
    
    // Date constraints
    private var minimumDate: Date {
        Calendar.current.date(byAdding: .year, value: -120, to: Date()) ?? Date()
    }
    
    private var maximumDate: Date {
        Date() // Today
    }
    
    // Calculate age for validation
    private var calculatedAge: Int? {
        let calendar = Calendar.current
        let ageComponents = calendar.dateComponents([.year], from: selectedDate, to: Date())
        return ageComponents.year
    }
    
    var body: some View {
        NavigationStack {
            Form {
                headerSection
                datePickerSection
                privacySection
                
                if let error = errorMessage {
                    errorSection(error)
                }
            }
            .navigationTitle("Age Verification")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Continue") {
                        submitAgeVerification()
                    }
                    .disabled(isLoading || !isValidAge)
                    .fontWeight(.semibold)
                }
                
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", systemImage: "xmark") {
                        dismiss()
                    }
                    .disabled(isLoading)
                }
            }
        }
        .interactiveDismissDisabled(true) // Prevent dismissing without completing
        .appDisplayScale(appState: appState)
        .contrastAwareBackground(appState: appState, defaultColor: Color.systemBackground)
    }
    
    // MARK: - Sections
    
    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "person.badge.shield.checkmark.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Age Verification Required")
                            .font(.headline)
                            .fontWeight(.semibold)
                        
                        Text("Help us provide age-appropriate content")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                }
                
                Text("To comply with App Store guidelines and provide appropriate content filtering, we need to verify your age. This information is private and used only for content moderation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(.vertical, 8)
        }
        .listRowBackground(Color.clear)
    }
    
    private var datePickerSection: some View {
        Section("Birth Date") {
            DatePicker(
                "Select your birth date",
                selection: $selectedDate,
                in: minimumDate...maximumDate,
                displayedComponents: .date
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            
            if let age = calculatedAge {
                HStack {
                    Text("Age")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(age) years old")
                        .fontWeight(.medium)
                }
                .font(.callout)
                .padding(.top, 8)
            }
            
            if !isValidAge {
                Text("Please select a valid birth date")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
    
    private var privacySection: some View {
        Section("Privacy Information") {
            VStack(alignment: .leading, spacing: 12) {
                privacyPoint(
                    icon: "lock.fill",
                    title: "Private & Secure",
                    description: "Your birth date is stored privately and never shared with other users"
                )
                
                privacyPoint(
                    icon: "eye.slash.fill",
                    title: "Content Filtering Only",
                    description: "This information is used exclusively to provide age-appropriate content filtering"
                )
                
                privacyPoint(
                    icon: "gear",
                    title: "You Control Settings",
                    description: "You can update your birth date and content preferences anytime in Settings"
                )
                
                if let age = calculatedAge {
                    if age < 13 {
                        Text("⚠️ Users under 13 require parental consent under COPPA regulations")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.top, 8)
                    } else if age < 18 {
                        Text("ℹ️ Some content will be restricted until you turn 18")
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .padding(.top, 8)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
    
    private func privacyPoint(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.blue)
                .frame(width: 16)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout)
                    .fontWeight(.medium)
                
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private func errorSection(_ error: String) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            .padding(.vertical, 4)
        }
    }
    
    // MARK: - Validation
    
    private var isValidAge: Bool {
        guard let age = calculatedAge else { return false }
        return age >= 0 && age <= 120 && selectedDate <= Date()
    }
    
    // MARK: - Actions
    
    private func submitAgeVerification() {
        guard isValidAge else {
            errorMessage = "Please select a valid birth date"
            return
        }
        
        guard let age = calculatedAge else {
            errorMessage = "Unable to calculate age from selected date"
            return
        }
        
        // Handle users under 13 (COPPA requirements)
        if age < 13 {
            errorMessage = "Users under 13 require parental consent. Please contact support for assistance."
            return
        }
        
        logger.info("Submitting age verification for user aged \(age)")
        
        isLoading = true
        errorMessage = nil
        
        Task {
            let success = await appState.ageVerificationManager.completeAgeVerification(birthDate: selectedDate)
            
            await MainActor.run {
                isLoading = false
                
                if success {
                    logger.info("Age verification completed successfully")
                    dismiss()
                } else {
                    // Get the specific error from the verification state
                    if case .failed(let error) = appState.ageVerificationManager.verificationState {
                        errorMessage = error
                    } else {
                        errorMessage = "Failed to verify age. Please try again."
                    }
                    logger.error("Age verification failed: \(errorMessage ?? "unknown error")")
                }
            }
        }
    }
}

// MARK: - Presentation Modifier

struct AgeVerificationModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @State private var showingAgeVerification = false
    
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingAgeVerification) {
                AgeVerificationView()
            }
            .onAppear {
                // Check initial state when view appears
                checkAndShowAgeVerification()
            }
            .onChange(of: appState.ageVerificationManager.needsAgeVerification) { _, needsVerification in
                checkAndShowAgeVerification()
            }
            .onChange(of: appState.ageVerificationManager.verificationState) { _, state in
                if case .completed = state {
                    showingAgeVerification = false
                } else {
                    checkAndShowAgeVerification()
                }
            }
    }
    
    private func checkAndShowAgeVerification() {
        let needsVerification = appState.ageVerificationManager.needsAgeVerification
        let isRequired = appState.ageVerificationManager.verificationState == .required
        
        // Only show modal if verification is needed and state is required
        if needsVerification && isRequired && !showingAgeVerification {
            showingAgeVerification = true
        }
    }
}

extension View {
    func ageVerification() -> some View {
        self.modifier(AgeVerificationModifier())
    }
}

#Preview {
    NavigationStack {
        AgeVerificationView()
            .environment(AppState.shared)
    }
}
