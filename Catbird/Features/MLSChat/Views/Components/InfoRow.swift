import SwiftUI

#if os(iOS)

    extension MLSConversationDetailView {
        struct InfoRow: View {
            let label: String
            let value: String

            var body: some View {
                HStack {
                    Text(label)
                        .designFootnote()
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(value)
                        .designFootnote()
                        .foregroundColor(.primary)
                }
            }
        }
    }

#endif
