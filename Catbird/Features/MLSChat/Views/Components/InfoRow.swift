import SwiftUI

#if os(iOS)

    extension MLSOrdinaryConversationDetailView {
        struct InfoRow: View {
            let label: LocalizedStringKey
            let value: String

            var body: some View {
                HStack {
                    Text(label)
                        .designFootnote()
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(verbatim: value)
                        .designFootnote()
                        .foregroundColor(.primary)
                }
            }
        }
    }

#endif
