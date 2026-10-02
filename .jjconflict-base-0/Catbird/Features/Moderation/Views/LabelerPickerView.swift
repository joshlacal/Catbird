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
                                let displayName = labeler.creator.handle.description == "moderation.bsky.app"
                                    ? "Official Bluesky Moderation"
                                    : (labeler.creator.displayName ?? labeler.creator.handle.description)
                                Text(displayName)
                                    .appFont(AppTextRole.headline)
                                
                                Text("@\(labeler.creator.handle.description)")
                                    .appFont(AppTextRole.subheadline)
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
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        dismiss()
                    }
                }
            }
        }
    }
}
