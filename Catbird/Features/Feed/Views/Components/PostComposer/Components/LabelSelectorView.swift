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

  /// The self-labels an author can put on a post. All of them are offered whatever the
  /// author's own adult-content setting: they warn other viewers about the post's media.
  static let selfLabelOptions: [ComAtprotoLabelDefs.LabelValue] = [
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

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(Self.selfLabelOptions, id: \.self) { label in
            Button(action: { toggleLabel(label) }) {
              HStack {
                Text(displayName(for: label))
                  .foregroundStyle(.primary)
                Spacer()
                if selectedLabels.contains(label) {
                  Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                }
              }
            }
            .accessibilityAddTraits(selectedLabels.contains(label) ? .isSelected : [])
          }
        }
      }
      .navigationTitle("Content Labels")
      .platformInlineNavigationTitle()
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
    }
  }

  private func toggleLabel(_ label: ComAtprotoLabelDefs.LabelValue) {
    if selectedLabels.contains(label) {
      selectedLabels.remove(label)
    } else {
      selectedLabels.insert(label)
    }
  }
}

#Preview("LabelSelectorView") {
  NavigationStack {
    LabelSelectorView(selectedLabels: .constant([]))
  }
  .previewWithAuthenticatedState()
}
