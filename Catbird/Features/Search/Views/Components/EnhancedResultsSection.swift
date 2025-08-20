/// A section container for search results
import SwiftUI

/// An enhanced results section with customizable styling
struct EnhancedResultsSection<Content: View>: View {
    let title: String
    let icon: String
    let count: Int?
    let showDivider: Bool
    let alignment: HorizontalAlignment
    @ViewBuilder let content: () -> Content
    
    init(
        title: String,
        icon: String,
        count: Int? = nil,
        showDivider: Bool = true,
        alignment: HorizontalAlignment = .leading,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.count = count
        self.showDivider = showDivider
        self.alignment = alignment
        self.content = content
    }
    
    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                    .appFont(AppTextRole.headline)
                
                Text(title)
                    .appFont(AppTextRole.headline)
                
                if let count = count {
                    Text("(\(count))")
                        .appFont(AppTextRole.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.leading, 2)
                }
                
                Spacer()
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(Color.systemBackground)
            
            if showDivider {
                Divider()
            }
            
            content()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .background(Color.systemBackground)
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 5, y: 2)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}
