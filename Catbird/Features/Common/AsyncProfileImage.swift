import SwiftUI
import NukeUI

struct AsyncProfileImage: View {
    let url: URL?
    let size: CGFloat
    
    var body: some View {
        ZStack {
            // Background placeholder
            Circle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: size, height: size)
            
            if let url = url {
                // Using NukeUI's LazyImage instead of AsyncImage
                LazyImage(url: url) { state in
                    if state.isLoading {
                        // Loading state
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.7)
                    } else if let image = state.image {
                        // Success state
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        // Failure state
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .foregroundColor(.accentColor.opacity(0.5))
                    }
                }
                .priority(.high)
                .frame(width: size, height: size)
                .clipShape(Circle())
            } else {
                // No URL provided
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .foregroundColor(.accentColor.opacity(0.5))
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        AsyncProfileImage(url: URL(string: "https://example.com/missing.jpg"), size: 40)
        AsyncProfileImage(url: URL(string: "https://avatars.githubusercontent.com/u/1?v=4"), size: 60)
        AsyncProfileImage(url: nil, size: 80)
    }
    .padding()
}
