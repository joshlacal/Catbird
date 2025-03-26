import SwiftUI

/// View displaying placeholder loading rows
struct LoadingRowsView: View {
    let count: Int
    
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                loadingRow
                
                Divider()
                    .padding(.leading, 56)
            }
        }
        .redacted(reason: .placeholder)
        .shimmering()
    }
    
    private var loadingRow: some View {
        HStack(spacing: 12) {
            // Avatar placeholder
            Circle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: 44, height: 44)
            
            // Content placeholder
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 120, height: 14)
                    
                    Spacer()
                    
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 40, height: 14)
                }
                
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 180, height: 14)
                
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 14)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal)
    }
}

/// View modifier to add a shimmering effect to loading placeholders
struct ShimmeringViewModifier: ViewModifier {
    @State private var phase: CGFloat = 0
    
    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        gradient: Gradient(colors: [
                            .clear,
                            Color.white.opacity(0.2),
                            .clear
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 1.5)
                    .offset(x: -geometry.size.width + (geometry.size.width * 2.5 * phase))
                    .animation(
                        Animation.linear(duration: 1.5)
                            .repeatForever(autoreverses: false),
                        value: phase
                    )
                }
            )
            .onAppear {
                phase = 1
            }
    }
}

extension View {
    func shimmering() -> some View {
        modifier(ShimmeringViewModifier())
    }
}

