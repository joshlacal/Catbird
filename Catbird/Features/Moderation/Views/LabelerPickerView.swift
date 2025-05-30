import Foundation
import SwiftUI
import Petrel

/// View for selecting a labeler (moderation service) when reporting content
struct LabelerPickerView: View {
    let availableLabelers: [AppBskyLabelerDefs.LabelerViewDetailed]
    @Binding var selectedLabeler: AppBskyLabelerDefs.LabelerViewDetailed?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(availableLabelers, id: \.uri) { labeler in
                    Button {
                        selectedLabeler = labeler
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(labeler.creator.displayName ?? labeler.creator.handle.description)
                                    .font(.headline)
                                
                                Text("@\(labeler.creator.handle.description)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                            
                            if selectedLabeler?.uri == labeler.uri {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
            }
            .navigationTitle("Select Moderation Service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}
