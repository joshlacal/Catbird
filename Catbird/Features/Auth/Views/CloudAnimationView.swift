import SwiftUI

struct CloudAnimationView: View {
    @State private var cloudOffset1: CGFloat = -300
    @State private var cloudOffset2: CGFloat = -600
    @State private var cloudOffset3: CGFloat = -900
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Layer 1 - Slowest, furthest back
                CloudLayer(
                    cloudOffset: $cloudOffset1,
                    cloudCount: 4,
                    cloudSize: 180,
                    cloudOpacity: 0.15, // Much more visible
                    animationDuration: 60,
                    yPosition: geometry.size.height * 0.2
                )
                
                // Layer 2 - Medium speed
                CloudLayer(
                    cloudOffset: $cloudOffset2,
                    cloudCount: 3,
                    cloudSize: 220,
                    cloudOpacity: 0.2, // Much more visible
                    animationDuration: 45,
                    yPosition: geometry.size.height * 0.4
                )
                
                // Layer 3 - Fastest, closest
                CloudLayer(
                    cloudOffset: $cloudOffset3,
                    cloudCount: 3,
                    cloudSize: 150,
                    cloudOpacity: 0.1, // Much more visible
                    animationDuration: 30,
                    yPosition: geometry.size.height * 0.6
                )
            }
        }
        .allowsHitTesting(false)
    }
}

struct CloudLayer: View {
    @Binding var cloudOffset: CGFloat
    let cloudCount: Int
    let cloudSize: CGFloat
    let cloudOpacity: Double
    let animationDuration: Double
    let yPosition: CGFloat
    
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: cloudSize * 0.8) {
                ForEach(0..<cloudCount, id: \.self) { index in
                    CloudShape()
                        .fill(Color.white.opacity(cloudOpacity)) // White clouds
                        .frame(width: cloudSize, height: cloudSize * 0.6)
                        .blur(radius: 1)
                        .scaleEffect(1.0 + CGFloat(index % 2) * 0.2)
                }
            }
            .offset(x: cloudOffset)
            .position(x: geometry.size.width / 2, y: yPosition)
            .onAppear {
                startAnimation(screenWidth: geometry.size.width)
            }
        }
    }
    
    private func startAnimation(screenWidth: CGFloat) {
        // Calculate total width needed for seamless loop
        let totalWidth = CGFloat(cloudCount) * cloudSize * 1.8
        
        // Start from right side of screen
        cloudOffset = screenWidth + cloudSize
        
        // Animate to left side
        withAnimation(.linear(duration: animationDuration).repeatForever(autoreverses: false)) {
            cloudOffset = -totalWidth - cloudSize
        }
    }
}

struct CloudShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        // Create a cloud-like shape using circles
        let baseY = rect.height * 0.6
        
        // Main body of cloud
        path.addEllipse(in: CGRect(x: rect.width * 0.2, y: baseY - rect.height * 0.2, 
                                   width: rect.width * 0.6, height: rect.height * 0.4))
        
        // Left puff
        path.addEllipse(in: CGRect(x: rect.width * 0.05, y: baseY - rect.height * 0.15, 
                                   width: rect.width * 0.35, height: rect.height * 0.3))
        
        // Right puff
        path.addEllipse(in: CGRect(x: rect.width * 0.6, y: baseY - rect.height * 0.15, 
                                   width: rect.width * 0.35, height: rect.height * 0.3))
        
        // Top puff
        path.addEllipse(in: CGRect(x: rect.width * 0.3, y: baseY - rect.height * 0.35, 
                                   width: rect.width * 0.4, height: rect.height * 0.35))
        
        // Small detail puffs
        path.addEllipse(in: CGRect(x: rect.width * 0.15, y: baseY - rect.height * 0.25, 
                                   width: rect.width * 0.25, height: rect.height * 0.2))
        
        path.addEllipse(in: CGRect(x: rect.width * 0.55, y: baseY - rect.height * 0.28, 
                                   width: rect.width * 0.3, height: rect.height * 0.25))
        
        return path
    }
}

#Preview {
    ZStack {
        LinearGradient(colors: [.blue.opacity(0.6), .cyan.opacity(0.4)], 
                      startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        
        CloudAnimationView()
    }
}
