import SwiftUI
import OSLog

struct BirthDateSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    
    @State private var currentBirthDate: Date?
    @State private var selectedDate = Calendar.current.date(byAdding: .year, value: -20, to: Date()) ?? Date()
    @State private var isLoading = true
    @State private var isUpdating = false
    @State private var errorMessage: String?
    @State private var showingDeleteConfirmation = false
    
    private let logger = Logger(subsystem: "blue.catbird", category: "BirthDateSettingsView")
    
    // Date constraints
    private var minimumDate: Date {
        Calendar.current.date(byAdding: .year, value: -120, to: Date()) ?? Date()
    }
    
    private var maximumDate: Date {
        Date() // Today
    }
    
    // Calculate age for display
    private var calculatedAge: Int? {
        let birthDate = currentBirthDate ?? selectedDate
        let calendar = Calendar.current
        let ageComponents = calendar.dateComponents([.year], from: birthDate, to: Date())
        return ageComponents.year
    }
    
    // Check if date has changed
    private var hasChanges: Bool {
        guard let currentBirthDate = currentBirthDate else { return true }
        return !Calendar.current.isDate(selectedDate, inSameDayAs: currentBirthDate)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    Section {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .listRowBackground(Color.clear)
                    }
                } else {
                    headerSection
                    datePickerSection
                    ageGroupInfoSection
                    privacySection
                    
                    if let error = errorMessage {
                        errorSection(error)
                    }
                    
                    if currentBirthDate != nil {
                        dangerSection
                    }
                }
            }
            .navigationTitle("Birth Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if hasChanges {
                        Button("Save") {
                            updateBirthDate()
                        }
                        .disabled(isUpdating)
                        .fontWeight(.semibold)
                    }
                }
                
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isUpdating)
                }
            }
        }
        .appDisplayScale(appState: appState)
        .contrastAwareBackground(appState: appState, defaultColor: Color.systemBackground)
        .task {
            await loadCurrentBirthDate()
        }
    }
    
    // MARK: - Sections
    
    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "calendar")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Birth Date Settings")
                            .font(.headline)
                            .fontWeight(.semibold)
                        
                        Text("Manage your age verification information")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .listRowBackground(Color.clear)
    }
    @ViewBuilder
    private var datePickerSection: some View {
        Section {
            DatePicker(
                "Birth Date",
                selection: $selectedDate,
                in: minimumDate...maximumDate,
                displayedComponents: .date
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            
            if let age = calculatedAge {
                HStack {
                    Text("Current Age")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(age) years old")
                        .fontWeight(.medium)
                }
                .font(.callout)
                .padding(.top, 8)
            }
        } header: {
            Text("Birth Date")
        } footer: {
            if currentBirthDate == nil {
                Text("Setting your birth date enables age-appropriate content filtering.")
            } else if hasChanges {
                Text("Changes will update your content filtering settings immediately.")
            }
        }
    }
    
    private var ageGroupInfoSection: some View {
        Section {
            if let age = calculatedAge {
                VStack(alignment: .leading, spacing: 12) {
                    ageGroupIndicator(age: age)
                    contentAccessInfo(age: age)
                }
            }
        } header: {
            Text("Content Access")
        }
    }
    
    private func ageGroupIndicator(age: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: age >= 18 ? "checkmark.circle.fill" : age >= 13 ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                .foregroundStyle(age >= 18 ? .green : age >= 13 ? .orange : .red)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(age >= 18 ? "Full Access" : age >= 13 ? "Restricted Access" : "Limited Access")
                    .fontWeight(.medium)
                
                Text(ageGroupDescription(age: age))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private func contentAccessInfo(age: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if age >= 18 {
                accessItem(icon: "checkmark.circle", text: "Adult content available", color: .green)
                accessItem(icon: "checkmark.circle", text: "Full moderation controls", color: .green)
            } else if age >= 13 {
                accessItem(icon: "xmark.circle", text: "Adult content restricted", color: .red)
                accessItem(icon: "checkmark.circle", text: "Basic moderation controls", color: .green)
                accessItem(icon: "info.circle", text: "Some content automatically filtered", color: .blue)
            } else {
                accessItem(icon: "xmark.circle", text: "Adult content blocked", color: .red)
                accessItem(icon: "xmark.circle", text: "Suggestive content blocked", color: .red)
                accessItem(icon: "exclamationmark.triangle", text: "Parental consent may be required", color: .orange)
            }
        }
    }
    
    private func accessItem(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.caption)
                .frame(width: 16)
            
            Text(text)
                .font(.caption)
        }
    }
    
    private var privacySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.blue)
                        .font(.caption)
                    
                    Text("Your birth date is stored privately and never shared with other users")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                HStack(spacing: 8) {
                    Image(systemName: "shield.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    
                    Text("Used only for age-appropriate content filtering and App Store compliance")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Privacy")
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
    
    @ViewBuilder
    private var dangerSection: some View {
        Section {
            Button("Remove Birth Date", role: .destructive) {
                showingDeleteConfirmation = true
            }
            .disabled(isUpdating)
        } header: {
            Text("Advanced")
        } footer: {
            Text("Removing your birth date will restrict access to adult content until re-verified.")
        }
        .confirmationDialog("Remove Birth Date", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                removeBirthDate()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will restrict your content access and may require re-verification later.")
        }
    }
    
    // MARK: - Helper Methods
    
    private func ageGroupDescription(age: Int) -> String {
        if age >= 18 {
            return "You have access to all content with full user controls"
        } else if age >= 13 {
            return "Some content is automatically filtered for your safety"
        } else {
            return "Restricted access with enhanced safety protections"
        }
    }
    
    // MARK: - Actions
    
    private func loadCurrentBirthDate() async {
        logger.info("Loading current birth date")
        
        do {
            let preferences = try await appState.preferencesManager.getPreferences()
            
            await MainActor.run {
                if let birthDate = preferences.birthDate {
                    currentBirthDate = birthDate
                    selectedDate = birthDate
                    logger.debug("Loaded birth date: \(birthDate)")
                } else {
                    logger.debug("No birth date found")
                }
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to load birth date: \(error.localizedDescription)"
                isLoading = false
            }
            logger.error("Failed to load birth date: \(error.localizedDescription)")
        }
    }
    
    private func updateBirthDate() {
        logger.info("Updating birth date")
        
        isUpdating = true
        errorMessage = nil
        
        Task {
            let success = await appState.ageVerificationManager.completeAgeVerification(birthDate: selectedDate)
            
            await MainActor.run {
                isUpdating = false
                
                if success {
                    logger.info("Birth date updated successfully")
                    currentBirthDate = selectedDate
                    
                    // Optionally dismiss after successful update
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        dismiss()
                    }
                } else {
                    errorMessage = "Failed to update birth date. Please try again."
                    logger.error("Failed to update birth date")
                }
            }
        }
    }
    
    private func removeBirthDate() {
        logger.info("Removing birth date")
        
        isUpdating = true
        errorMessage = nil
        
        Task {
            do {
                try await appState.preferencesManager.setBirthDate(nil)
                
                await MainActor.run {
                    isUpdating = false
                    logger.info("Birth date removed successfully")
                    
                    // Update age verification status
                    Task {
                        await appState.ageVerificationManager.checkAgeVerificationStatus()
                    }
                    
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isUpdating = false
                    errorMessage = "Failed to remove birth date: \(error.localizedDescription)"
                    logger.error("Failed to remove birth date: \(error.localizedDescription)")
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        BirthDateSettingsView()
            .environment(AppState.shared)
    }
}
