import SwiftUI

/// Lightweight static noise texture overlay for visual interest without performance cost
struct NoiseTextureView: View {
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        Canvas { context, size in
            // Create a subtle noise pattern
            for _ in 0..<200 {
                let x = CGFloat.random(in: 0...size.width)
                let y = CGFloat.random(in: 0...size.height)
                let opacity = Double.random(in: 0.01...0.03)
                let radius = CGFloat.random(in: 0.5...1.5)
                
                context.opacity = opacity
                context.fill(
                    Circle().path(in: CGRect(x: x, y: y, width: radius, height: radius)),
                    with: .color(colorScheme == .dark ? .white : .black)
                )
            }
        }
        .allowsHitTesting(false)
        .drawingGroup() // Renders once and caches the result
    }
}

/// Diagonal pattern overlay for additional texture
struct PatternOverlay: View {
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let spacing: CGFloat = 40
                
                // Create diagonal lines pattern
                for x in stride(from: -geometry.size.height, to: geometry.size.width + geometry.size.height, by: spacing) {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x + geometry.size.height, y: geometry.size.height))
                }
            }
            .stroke(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.02 : 0.04),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.5
            )
        }
        .allowsHitTesting(false)
    }
}
