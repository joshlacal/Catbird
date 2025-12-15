//
//  LabelSelectorView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 12/18/23.
//

import SwiftUI
import Petrel

struct LabelSelectorView: View {
  @Binding var selectedLabels: Set<ComAtprotoLabelDefs.LabelValue>
  @Environment(\.dismiss) private var dismiss
  @ObservationIgnored @Environment(AppState.self) private var appState

  // Define only the allowed self-labels
  private let allowedSelfLabels: [ComAtprotoLabelDefs.LabelValue] = [
    .exclamationnodashunauthenticated,
    .porn,
    .sexual,
    .nudity,
    ComAtprotoLabelDefs.LabelValue(rawValue: "graphic-media")  // This one isn't in predefined values
  ]
  
  // Display name mapping function
  private func displayName(for label: ComAtprotoLabelDefs.LabelValue) -> String {
    switch label.rawValue {
      case "!no-unauthenticated": return "Hide from Logged-out Users"
      case "porn": return "Adult Content"
      case "sexual": return "Sexual Content"
      case "nudity": return "Contains Nudity"
      case "graphic-media": return "Graphic Media"
      default: return label.rawValue.capitalized
    }
  }

  // Adult-only labels that require adult content enabled
  private let adultOnlyLabelValues: Set<String> = ["porn", "sexual", "nudity"]

  // Compute effective label list based on adult content setting
  private var effectiveAllowedLabels: [ComAtprotoLabelDefs.LabelValue] {
    if appState.isAdultContentEnabled { return allowedSelfLabels }
    return allowedSelfLabels.filter { !adultOnlyLabelValues.contains($0.rawValue) }
  }

  var body: some View {
    NavigationStack {
      List(effectiveAllowedLabels, id: \.self) { label in
        Button(action: { toggleLabel(label) }) {
          HStack {
            Text(displayName(for: label))
            Spacer()
            if selectedLabels.contains(label) {
              Image(systemName: "checkmark")
            }
          }
        }
      }
      .navigationTitle("Content Labels")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .overlay(alignment: .bottomLeading) {
        if !appState.isAdultContentEnabled {
          Text("Adult labels can be added after enabling adult content in the Bluesky app.")
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
            .padding([.horizontal, .bottom])
        }
      }
    }
  }

  private func toggleLabel(_ label: ComAtprotoLabelDefs.LabelValue) {
    // If adult content is disabled, disallow toggling adult-only labels
    if !appState.isAdultContentEnabled && adultOnlyLabelValues.contains(label.rawValue) {
      return
    }
    if selectedLabels.contains(label) {
      selectedLabels.remove(label)
    } else {
      selectedLabels.insert(label)
    }
  }
}
