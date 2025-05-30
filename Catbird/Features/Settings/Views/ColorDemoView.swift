import SwiftUI

/// Simple demonstration of the updated theme colors
struct ColorDemoView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Theme Color Comparison")
                    .font(.title)
                    .padding()
                
                HStack(spacing: 20) {
                    // Dim Mode Column
                    VStack(spacing: 12) {
                        Text("Dim Mode (Gray)")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        ColorSampleView(
                            title: "Primary",
                            color: Color(red: 0.18, green: 0.18, blue: 0.20),
                            textColor: .white
                        )
                        
                        ColorSampleView(
                            title: "Secondary", 
                            color: Color(red: 0.25, green: 0.25, blue: 0.27),
                            textColor: .white
                        )
                        
                        ColorSampleView(
                            title: "Tertiary",
                            color: Color(red: 0.32, green: 0.32, blue: 0.34),
                            textColor: .white
                        )
                        
                        ColorSampleView(
                            title: "Elevated Low",
                            color: Color(red: 0.22, green: 0.22, blue: 0.24),
                            textColor: .white
                        )
                        
                        ColorSampleView(
                            title: "Elevated High",
                            color: Color(red: 0.35, green: 0.35, blue: 0.37),
                            textColor: .white
                        )
                    }
                    .frame(maxWidth: .infinity)
                    
                    // True Black Mode Column
                    VStack(spacing: 12) {
                        Text("True Black Mode")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        ColorSampleView(
                            title: "Primary",
                            color: Color(red: 0, green: 0, blue: 0),
                            textColor: Color(white: 0.95)
                        )
                        
                        ColorSampleView(
                            title: "Secondary", 
                            color: Color(white: 0.04),
                            textColor: Color(white: 0.95)
                        )
                        
                        ColorSampleView(
                            title: "Tertiary",
                            color: Color(white: 0.06),
                            textColor: Color(white: 0.95)
                        )
                        
                        ColorSampleView(
                            title: "Elevated Low",
                            color: Color(white: 0.02),
                            textColor: Color(white: 0.95)
                        )
                        
                        ColorSampleView(
                            title: "Elevated High",
                            color: Color(white: 0.10),
                            textColor: Color(white: 0.95)
                        )
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding()
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Key Differences:")
                        .font(.headline)
                    
                    Text("• Dim Mode: Uses proper gray colors (0.18-0.37 RGB range)")
                        .font(.body)
                    
                    Text("• True Black: Uses pure black with subtle white elevations")
                        .font(.body)
                    
                    Text("• Dim Mode is now clearly gray, not black")
                        .font(.body)
                        .foregroundColor(.green)
                    
                    Text("• True Black remains OLED-optimized")
                        .font(.body)
                        .foregroundColor(.blue)
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)
                
                Spacer()
            }
        }
        .navigationTitle("Color Demo")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ColorSampleView: View {
    let title: String
    let color: Color
    let textColor: Color
    
    var body: some View {
        VStack {
            Rectangle()
                .fill(color)
                .frame(height: 60)
                .overlay(
                    Text(title)
                        .foregroundColor(textColor)
                        .font(.caption)
                        .fontWeight(.medium)
                )
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
            
            Text(colorDescription(for: color))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    private func colorDescription(for color: Color) -> String {
        // This is a simplified description
        if color == Color.black {
            return "RGB(0,0,0)"
        } else if color == Color(white: 0.04) {
            return "White 4%"
        } else if color == Color(white: 0.06) {
            return "White 6%"
        } else if color == Color(white: 0.02) {
            return "White 2%"
        } else if color == Color(white: 0.10) {
            return "White 10%"
        } else if color == Color(red: 0.18, green: 0.18, blue: 0.20) {
            return "Gray 18%"
        } else if color == Color(red: 0.25, green: 0.25, blue: 0.27) {
            return "Gray 25%"
        } else if color == Color(red: 0.32, green: 0.32, blue: 0.34) {
            return "Gray 32%"
        } else if color == Color(red: 0.22, green: 0.22, blue: 0.24) {
            return "Gray 22%"
        } else if color == Color(red: 0.35, green: 0.35, blue: 0.37) {
            return "Gray 35%"
        }
        return "Custom"
    }
}

#Preview {
    NavigationStack {
        ColorDemoView()
    }
}