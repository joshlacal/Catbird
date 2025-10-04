import SwiftUI
import NukeUI
import Nuke

struct AsyncProfileImage: View {
    let url: URL?
    let size: CGFloat
    
    // Build a Nuke request that decodes at the exact pixel size to avoid large decode/scale costs
    private func resizedRequest(for url: URL?, sizeInPoints: CGFloat) -> ImageRequest? {
        guard let url = url else { return nil }
        let scale = PlatformScreenInfo.scale
        let pixelSize = CGSize(width: sizeInPoints * scale, height: sizeInPoints * scale)
        let processors: [any ImageProcessing] = [
            ImageProcessors.Resize(size: pixelSize, unit: .pixels, contentMode: .aspectFill)
        ]
        return ImageRequest(url: url, processors: processors)
    }
    
    var body: some View {
        ZStack {
            // Background placeholder
            Circle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: size, height: size)
            
            if let request = resizedRequest(for: url, sizeInPoints: size) {
                // Using NukeUI's LazyImage with a resized ImageRequest
                LazyImage(request: request) { state in
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
