import SwiftUI

// Floating particle for ambient atmosphere
struct Particle: Identifiable {
    let id = UUID()
    var position: CGPoint
    var velocity: CGVector
    var size: CGFloat
    var opacity: Double
    var lifespan: Double
    var age: Double = 0
}

struct ParticleEffectView: View {
    @State private var particles: [Particle] = []
    @Environment(\.colorScheme) var colorScheme
    
    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, _ in
                for particle in particles {
                    let opacity = particle.opacity * (1 - particle.age / particle.lifespan)
                    
                    // Draw particle with glow effect
                    context.addFilter(.blur(radius: particle.size * 0.3))
                    
                    context.opacity = opacity
                    
                    // Outer glow
                    context.fill(
                        Circle().path(in: CGRect(
                            x: particle.position.x - particle.size * 2,
                            y: particle.position.y - particle.size * 2,
                            width: particle.size * 4,
                            height: particle.size * 4
                        )),
                        with: .color(colorScheme == .dark ? .white.opacity(0.1) : .white.opacity(0.3))
                    )
                    
                    // Inner particle
                    context.fill(
                        Circle().path(in: CGRect(
                            x: particle.position.x - particle.size / 2,
                            y: particle.position.y - particle.size / 2,
                            width: particle.size,
                            height: particle.size
                        )),
                        with: .color(colorScheme == .dark ? .white : .white)
                    )
                }
            }
            .onReceive(timer) { _ in
                updateParticles(in: geometry.size)
            }
            .onAppear {
                initializeParticles(in: geometry.size)
            }
        }
        .allowsHitTesting(false)
    }
    
    private func initializeParticles(in size: CGSize) {
        particles = (0..<20).map { _ in
            Particle(
                position: CGPoint(
                    x: Double.random(in: 0...size.width),
                    y: Double.random(in: 0...size.height)
                ),
                velocity: CGVector(
                    dx: Double.random(in: -0.5...0.5),
                    dy: Double.random(in: -0.8...(-0.3))
                ),
                size: CGFloat.random(in: 1...3),
                opacity: Double.random(in: 0.3...0.7),
                lifespan: Double.random(in: 10...20)
            )
        }
    }
    
    private func updateParticles(in size: CGSize) {
        particles = particles.compactMap { particle in
            var updated = particle
            
            // Update position
            updated.position.x += updated.velocity.dx
            updated.position.y += updated.velocity.dy
            
            // Add slight horizontal drift
            updated.velocity.dx += Double.random(in: -0.05...0.05)
            
            // Update age
            updated.age += 0.1
            
            // Remove dead particles
            if updated.age >= updated.lifespan || updated.position.y < -10 {
                return nil
            }
            
            // Wrap around horizontally
            if updated.position.x < -10 {
                updated.position.x = size.width + 10
            } else if updated.position.x > size.width + 10 {
                updated.position.x = -10
            }
            
            return updated
        }
        
        // Add new particles to maintain count
        while particles.count < 20 {
            particles.append(
                Particle(
                    position: CGPoint(
                        x: Double.random(in: 0...size.width),
                        y: size.height + 10
                    ),
                    velocity: CGVector(
                        dx: Double.random(in: -0.5...0.5),
                        dy: Double.random(in: -0.8...(-0.3))
                    ),
                    size: CGFloat.random(in: 1...3),
                    opacity: Double.random(in: 0.3...0.7),
                    lifespan: Double.random(in: 10...20)
                )
            )
        }
    }
}
