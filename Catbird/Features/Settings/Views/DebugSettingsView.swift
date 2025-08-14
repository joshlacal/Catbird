//
//  DebugSettingsView.swift
//  Catbird
//
//  Debug and developer settings for troubleshooting and validation
//

import SwiftUI
import UniformTypeIdentifiers

struct DebugSettingsView: View {
  @Environment(AppState.self) private var appState
  @State private var showingValidationReport = false
  @State private var validationReport = ""
  @State private var isGeneratingReport = false
  
  var body: some View {
    List {
      Section("Height Validation") {
        Toggle("Enable Height Validation", isOn: Binding(
          get: { appState.appSettings.enableHeightValidation },
          set: { appState.appSettings.enableHeightValidation = $0 }
        ))
        .onChange(of: appState.appSettings.enableHeightValidation) { _, newValue in
          if newValue {
            // Reset validation data when enabling
            // This will be handled by the controller
          }
        }
        
        if appState.appSettings.enableHeightValidation {
          Toggle("Show Visual Indicators", isOn: Binding(
            get: { appState.appSettings.showHeightValidationOverlay },
            set: { appState.appSettings.showHeightValidationOverlay = $0 }
          ))
          .help("Shows red overlay on posts with height calculation errors")
          
          Button("Generate Validation Report") {
            generateValidationReport()
          }
          .disabled(isGeneratingReport)
          
          Button("Clear Validation Data") {
            // This would need to be implemented via a notification or callback
            NotificationCenter.default.post(name: NSNotification.Name("ClearValidationData"), object: nil)
          }
          .foregroundColor(.red)
        }
      }
      
      Section("Validation Report", footer: Text("Shows accuracy statistics for PostHeightCalculator estimates vs actual rendered heights.")) {
        if !validationReport.isEmpty {
          ScrollView {
            Text(validationReport)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 300)
          
          Button("Share Report") {
            shareReport()
          }
          .buttonStyle(.borderedProminent)
        } else {
          Text("No validation data available")
            .foregroundColor(.secondary)
            .italic()
        }
      }
      
      Section("Information") {
        VStack(alignment: .leading, spacing: 8) {
          Text("Height validation compares PostHeightCalculator estimates with actual rendered cell heights.")
          Text("Enable validation to collect accuracy data during normal app usage.")
          Text("Visual indicators help identify posts with significant height calculation errors.")
        }
        .font(.caption)
        .foregroundColor(.secondary)
      }
    }
    .navigationTitle("Debug Settings")
    .navigationBarTitleDisplayMode(.large)
    .sheet(isPresented: $showingValidationReport) {
      NavigationStack {
        ScrollView {
          Text(validationReport)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding()
        }
        .navigationTitle("Validation Report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .navigationBarTrailing) {
            Button("Done") {
              showingValidationReport = false
            }
          }
          
          ToolbarItem(placement: .navigationBarLeading) {
            ShareLink("Share", item: validationReport)
          }
        }
      }
    }
    .onAppear {
      // Load initial report if validation is enabled
      if appState.appSettings.enableHeightValidation {
        generateValidationReport()
      }
    }
  }
  
  private func generateValidationReport() {
    isGeneratingReport = true
    
    // Post notification to request report generation
    // The controller will handle this and post back the report
    NotificationCenter.default.post(name: NSNotification.Name("GenerateValidationReport"), object: nil)
    
    // Listen for the report
    let observer = NotificationCenter.default.addObserver(
      forName: NSNotification.Name("ValidationReportGenerated"),
      object: nil,
      queue: .main
    ) { notification in
      if let report = notification.object as? String {
        validationReport = report
      }
      isGeneratingReport = false
    }
    
    // Clean up observer after a delay
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
      NotificationCenter.default.removeObserver(observer)
      isGeneratingReport = false
    }
  }
  
  private func shareReport() {
    guard !validationReport.isEmpty else { return }
    
    let activityController = UIActivityViewController(
      activityItems: [validationReport],
      applicationActivities: nil
    )
    
    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let window = windowScene.windows.first {
      window.rootViewController?.present(activityController, animated: true)
    }
  }
}

#Preview {
  NavigationStack {
    DebugSettingsView()
      .environment(AppState.shared)
  }
}