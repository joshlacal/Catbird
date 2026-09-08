import Petrel
import SwiftUI

struct ProfileImageViewerView: View {
    let avatar: URI?
    @Binding var isPresented: Bool
    var namespace: Namespace.ID
    @State private var currentIndex = 0

    var body: some View {
        if let avatar {
            let image = AppBskyEmbedImages.ViewImage(thumb: avatar, fullsize: avatar, alt: "")
            NavigationStack {
                EnhancedImageViewer(
                    images: [image],
                    initialImageId: image.id,
                    currentIndex: $currentIndex,
                    isPresented: $isPresented,
                    namespace: namespace
                )
            }
            .ignoresSafeArea()
        } else {
            VStack {
                Text("No image available")
                Button("Close") {
                    isPresented = false
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
        }
    }
}
