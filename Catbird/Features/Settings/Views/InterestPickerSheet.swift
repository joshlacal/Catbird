//
//  InterestPickerSheet.swift
//  Catbird
//
//  Extracted from SmartFeedDiscoveryView for reuse across settings, discovery, and onboarding.
//

import SwiftUI

struct InterestPickerSheet: View {
  let currentInterests: [String]
  let onSave: ([String]) async -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var selectedInterests: Set<String>
  @State private var isSaving = false

  // Bluesky's canonical interest tags; selections store the tag, not the display name
  private let availableInterests = BlueskyInterest.allCases.sorted { $0.displayName < $1.displayName }

  init(currentInterests: [String], onSave: @escaping ([String]) async -> Void) {
    self.currentInterests = currentInterests
    self.onSave = onSave
    // Older Catbird builds saved display words; keep the ones Bluesky recognizes as canonical tags
    self._selectedInterests = State(initialValue: Set(currentInterests.compactMap { BlueskyInterest.normalize($0)?.rawValue }))
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 16) {
          Text("Select topics you're interested in to get better feed recommendations")
            .appFont(AppTextRole.body)
            .foregroundColor(.secondary)

          FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(availableInterests) { interest in
              InterestTag(
                interest: interest.displayName,
                isSelected: selectedInterests.contains(interest.rawValue),
                onTap: {
                  if selectedInterests.contains(interest.rawValue) {
                    selectedInterests.remove(interest.rawValue)
                  } else {
                    selectedInterests.insert(interest.rawValue)
                  }
                }
              )
            }
          }
        }
        .padding()
      }
      .navigationTitle("Your Interests")
      #if os(iOS)
      .toolbarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", systemImage: "xmark") {
            dismiss()
          }
        }

        ToolbarItem(placement: .primaryAction) {
          Button("Save") {
            Task {
              isSaving = true
              await onSave(Array(selectedInterests))
              dismiss()
            }
          }
          .disabled(isSaving)
        }
      }
    }
  }
}

struct InterestTag: View {
  let interest: String
  let isSelected: Bool
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      Text(interest)
        .appFont(AppTextRole.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor : Color(platformColor: .platformSecondarySystemBackground))
        .foregroundColor(isSelected ? .white : .primary)
        .clipShape(Capsule())
    }
  }
}
