//
//  QuickFilterSheet.swift
//  Catbird
//
//  Lightweight filter sheet for quick feed filtering
//

import SwiftUI

/// Quick filter sheet for lightweight feed filtering
struct QuickFilterSheet: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 20) {
          // Quick toggle filters
          VStack(spacing: 12) {
            filterChip(name: "Hide Reposts", icon: "arrow.2.squarepath")
            filterChip(name: "Hide Replies", icon: "bubble.left")
            filterChip(name: "Hide Quote Posts", icon: "quote.bubble")
            filterChip(name: "Hide Link Posts", icon: "link")
          }
          
          Divider()
            .padding(.vertical, 4)
          
          // Exclusive filters
          VStack(spacing: 12) {
            Text("Show Only")
              .font(.caption)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
            
            exclusiveFilterChip(name: "Only Text Posts", icon: "text.alignleft")
            exclusiveFilterChip(name: "Only Media Posts", icon: "photo")
          }
        }
        .padding()
      }
      .navigationTitle("Quick Filters")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Clear") {
            clearAllQuickFilters()
          }
          .disabled(!hasAnyQuickFilterEnabled)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
          .fontWeight(.semibold)
        }
      }
    }
    .presentationDetents([.medium])
    .presentationDragIndicator(.visible)
  }
  
  @ViewBuilder
  private func filterChip(name: String, icon: String) -> some View {
    let isEnabled = appState.feedFilterSettings.isFilterEnabled(name: name)
    
    Button {
      appState.feedFilterSettings.toggleFilter(id: name)
      // Notify feed to reapply filters
      NotificationCenter.default.post(name: NSNotification.Name("FeedFiltersChanged"), object: nil)
    } label: {
      HStack(spacing: 12) {
        Image(systemName: icon)
          .font(.body)
          .foregroundStyle(isEnabled ? .white : .primary)
          .frame(width: 24)
        
        Text(name)
          .font(.body)
          .foregroundStyle(isEnabled ? .white : .primary)
        
        Spacer()
        
        if isEnabled {
          Image(systemName: "checkmark.circle.fill")
            .font(.body)
            .foregroundStyle(.white)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
      .background {
        RoundedRectangle(cornerRadius: 12)
          .fill(isEnabled ? Color.accentColor : Color(.systemGray6))
      }
    }
    .buttonStyle(.plain)
  }
  
  @ViewBuilder
  private func exclusiveFilterChip(name: String, icon: String) -> some View {
    let isEnabled = appState.feedFilterSettings.isFilterEnabled(name: name)
    
    Button {
      if isEnabled {
        appState.feedFilterSettings.toggleFilter(id: name)
      } else {
        // Disable the other exclusive filter first
        let exclusiveFilters = ["Only Text Posts", "Only Media Posts"]
        for filterName in exclusiveFilters where filterName != name {
          if appState.feedFilterSettings.isFilterEnabled(name: filterName) {
            appState.feedFilterSettings.toggleFilter(id: filterName)
          }
        }
        // Now enable this one
        appState.feedFilterSettings.toggleFilter(id: name)
      }
      // Notify feed to reapply filters
      NotificationCenter.default.post(name: NSNotification.Name("FeedFiltersChanged"), object: nil)
    } label: {
      HStack(spacing: 12) {
        Image(systemName: icon)
          .font(.body)
          .foregroundStyle(isEnabled ? .white : .primary)
          .frame(width: 24)
        
        Text(name)
          .font(.body)
          .foregroundStyle(isEnabled ? .white : .primary)
        
        Spacer()
        
        if isEnabled {
          Image(systemName: "checkmark.circle.fill")
            .font(.body)
            .foregroundStyle(.white)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
      .background {
        RoundedRectangle(cornerRadius: 12)
          .fill(isEnabled ? Color.accentColor : Color(.systemGray6))
      }
    }
    .buttonStyle(.plain)
  }
  
  private var hasAnyQuickFilterEnabled: Bool {
    let quickFilters = [
      "Only Text Posts",
      "Only Media Posts",
      "Hide Reposts",
      "Hide Replies",
      "Hide Quote Posts",
      "Hide Link Posts"
    ]
    return quickFilters.contains { appState.feedFilterSettings.isFilterEnabled(name: $0) }
  }
  
  private func clearAllQuickFilters() {
    let quickFilters = [
      "Only Text Posts",
      "Only Media Posts",
      "Hide Reposts",
      "Hide Replies",
      "Hide Quote Posts",
      "Hide Link Posts"
    ]
    
    for filterName in quickFilters {
      if appState.feedFilterSettings.isFilterEnabled(name: filterName) {
        appState.feedFilterSettings.toggleFilter(id: filterName)
      }
    }
    
    // Notify feed to reapply filters
    NotificationCenter.default.post(name: NSNotification.Name("FeedFiltersChanged"), object: nil)
  }
}

#Preview {
    @Previewable @Environment(AppState.self) var appState
  QuickFilterSheet()
    .environment(AppStateManager.shared)
}
