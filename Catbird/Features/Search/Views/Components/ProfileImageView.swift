import SwiftUI
import Petrel
import NukeUI

struct ProfileImageView: View {
    let url: URL?
    let size: CGFloat
    @Environment(\.displayScale) private var displayScale
    
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: size, height: size)
            
            if let url = url {
                LazyImage(request: ImageRequestFactory.avatar(url, pointSize: size, scale: displayScale)) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
            }
        }
    }
}
