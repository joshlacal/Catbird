import NukeUI
import Petrel
import SwiftUI
#if os(iOS)
import LazyPager
#endif

struct ProfileImageViewerView: View {
    let avatar: URI?
    @Binding var isPresented: Bool
    var namespace: Namespace.ID
    @State private var opacity: CGFloat = 1.0
    
    var body: some View {
        ZStack {
            Color.black
                .opacity(opacity)
                .ignoresSafeArea()
            
            if let avatarURI = avatar {
                let imageUrl = avatarURI.uriString()
                
#if os(iOS)
                LazyPager(data: [imageUrl]) { image in
                    GeometryReader { geometry in
                        LazyImage(request: ImageLoadingManager.imageRequest(
                            for: URL(string: image) ?? URL(string: "about:blank")!,
                            targetSize: CGSize(width: geometry.size.width, height: geometry.size.height)
                        )) { state in
                            if let fullImage = state.image {
                                fullImage
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                                    .id(image)
                                    .matchedTransitionSource(id: image, in: namespace)

                            } else if state.error != nil {
                                Image(systemName: "exclamationmark.triangle")
                                    .appFont(AppTextRole.largeTitle)
                                    .foregroundColor(.white)
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                            } else {
                                ProgressView()
                                    .tint(.white)
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                            }
                        }
                        .pipeline(ImageLoadingManager.shared.pipeline)
                    }
                }
                .zoomable(min: 1.0, max: 3.0, doubleTapGesture: .scale(2.0))
                .onDismiss(backgroundOpacity: $opacity) {
                    isPresented = false
                }
                .settings { config in
                    config.dismissVelocity = 1.5
                    config.dismissTriggerOffset = 0.2
                    config.dismissAnimationLength = 0.3
                    config.fullFadeOnDragAt = 0.3
                    config.pinchGestureEnableOffset = 15
                    config.shouldCancelSwiftUIAnimationsOnDismiss = false
                }
                .id("pager-\(imageUrl)")
#else
                // macOS: Simple image viewer without LazyPager
                GeometryReader { geometry in
                    LazyImage(request: ImageLoadingManager.imageRequest(
                        for: URL(string: imageUrl) ?? URL(string: "about:blank")!,
                        targetSize: CGSize(width: geometry.size.width, height: geometry.size.height)
                    )) { state in
                        if let fullImage = state.image {
                            fullImage
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                                .id(imageUrl)
                                .matchedTransitionSource(id: imageUrl, in: namespace)
                        } else if state.error != nil {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundColor(.white)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                        } else {
                            ProgressView()
                                .tint(.white)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                        }
                    }
                    .pipeline(ImageLoadingManager.shared.pipeline)
                }
                .onTapGesture {
                    isPresented = false
                }
                .id("viewer-\(imageUrl)")
#endif
            } else {
                VStack {
                    Text("No image available")
                        .foregroundColor(.white)
                    Button("Close") {
                        isPresented = false
                    }
                    .padding()
                    .background(Color.gray.opacity(0.5))
                    .cornerRadius(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.8))
            }
        }
    }
}
