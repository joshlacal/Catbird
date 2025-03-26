//
//  ViewImagesGridView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 6/30/24.
//

import Nuke
import NukeUI
import Petrel
import SwiftUI
import OSLog

#if os(iOS)
  import LazyPager
#endif

// MARK: - Logging Setup
//private let logger = Logger(subsystem: "com.catbird.app", category: "ViewImageGridView")

// MARK: - ViewImageGridView Implementation
struct ViewImageGridView: View {
  let viewImages: [AppBskyEmbedImages.ViewImage]
  let shouldBlur: Bool
  @State private var isBlurred: Bool
  @State private var selectedImage: AppBskyEmbedImages.ViewImage? {
    didSet {
//      logger.debug("🖼️ selectedImage changed: was \(String(describing: oldValue?.id)), now \(String(describing: selectedImage?.id))")
    }
  }
  @State private var currentIndex: Int = 0 {
    didSet {
//      logger.debug("📍 currentIndex changed: was \(oldValue), now \(currentIndex), updating transition ID? \(selectedImage != nil)")
      // Keep transition ID in sync with the current index when the image viewer is shown
      if selectedImage != nil {
        activeTransitionID = viewImages[currentIndex].id
      }
    }
  }
  @Namespace private var imageTransition
  
  // Tracking the transition source ID for debugging
  @State private var activeTransitionID: String? {
    didSet {
//      logger.debug("🔄 activeTransitionID changed: was \(String(describing: oldValue)), now \(String(describing: activeTransitionID))")
    }
  }
  
  // Store the last viewed index for proper transition on dismiss
  @State private var lastViewedIndex: Int = 0 {
    didSet {
//      logger.debug("📌 lastViewedIndex changed: was \(oldValue), now \(lastViewedIndex)")
    }
  }

  init(viewImages: [AppBskyEmbedImages.ViewImage], shouldBlur: Bool) {
    self.viewImages = viewImages
    self.shouldBlur = shouldBlur
    self._isBlurred = State(initialValue: shouldBlur)
//    logger.debug("⚙️ ViewImageGridView initialized with \(viewImages.count) images")
//    for (index, image) in viewImages.enumerated() {
//      logger.debug("   Image \(index): ID=\(image.id)")
//    }
  }

  var body: some View {
    VStack(spacing: 0) {  // Use VStack with zero spacing to better control dimensions
      if viewImages.count == 1 {
        singleImageLayout(viewImages[0])
      } else {
        GeometryReader { geometry in
          Group {
            switch viewImages.count {
            case 2:
              twoImageLayout(geometry: geometry)
            case 3:
              threeImageLayout(geometry: geometry)
            case 4:
              fourImageLayout(geometry: geometry)
            default:
              EmptyView()
            }
          }
        }
        // Force a max height for multi-image layouts to prevent large layout jumps
        .aspectRatio(1.667, contentMode: .fit)
      }
    }
    // Use fixed sizing to prevent layout jumps
    .fixedSize(horizontal: false, vertical: true)
    .fullScreenCover(item: $selectedImage) { initialImage in
      NavigationStack {
        EnhancedImageViewer(
          images: viewImages,
          initialImageId: initialImage.id,
          // Create a proper binding to ensure we track index changes
          currentIndex: Binding(
            get: { 
//              logger.debug("🔍 EnhancedImageViewer currentIndex getter - returning: \(currentIndex)")
              return currentIndex
            },
            set: { newIndex in 
//              logger.debug("🔄 EnhancedImageViewer currentIndex setter - setting to: \(newIndex)")
              currentIndex = newIndex
              lastViewedIndex = newIndex
              // Store the ID of the current image for transitions
              activeTransitionID = viewImages[newIndex].id
            }
          ),
          isPresented: .init(
            get: { 
              let isPresented = selectedImage != nil
//              logger.debug("👁️ EnhancedImageViewer isPresented getter - returning: \(isPresented)")
              return isPresented
            },
            set: { newValue in 
//              logger.debug("👁️ EnhancedImageViewer isPresented setter - setting to: \(newValue), lastViewedIndex: \(lastViewedIndex)")
              if !newValue { 
                // Remember the current transition ID before dismissal
                activeTransitionID = viewImages[lastViewedIndex].id
//                logger.debug("🚫 Dismissing viewer with transition ID: \(String(describing: activeTransitionID))")
                
                // Delay the dismissal slightly to ensure the transition ID is properly set
                DispatchQueue.main.async {
                  selectedImage = nil
                }
              } 
            }
          ),
          namespace: imageTransition
        )
//        .onAppear {
//          logger.debug("📱 EnhancedImageViewer appeared with initial index: \(currentIndex)")
//        }
//        .onDisappear {
//          logger.debug("🏁 EnhancedImageViewer disappeared. Final index: \(currentIndex)")
//        }
      }
      .ignoresSafeArea()
      // Use the specific transition ID for navigation transitions
      .navigationTransition(.zoom(sourceID: activeTransitionID ?? initialImage.id, in: imageTransition))
      .onAppear {
//        logger.debug("🔄 Setting initial transition ID to \(initialImage.id) on fullScreenCover appear")
        activeTransitionID = initialImage.id
      }
      .onDisappear {
//        logger.debug("🔚 fullScreenCover disappeared. Final transition ID: \(String(describing: activeTransitionID)), lastViewedIndex: \(lastViewedIndex)")
      }
    }
    .onChange(of: selectedImage) { oldValue, newValue in
//      logger.debug("✅ selectedImage onChange: was \(String(describing: oldValue?.id)), now \(String(describing: newValue?.id))")
    }
    .onChange(of: currentIndex) { oldValue, newValue in
//      logger.debug("✅ currentIndex onChange: was \(oldValue), now \(newValue)")
    }
  }

  @ViewBuilder
  private func imageView(
    for viewImage: AppBskyEmbedImages.ViewImage, width: CGFloat, height: CGFloat
  ) -> some View {
    // let aspectRatio: CGFloat = viewImage.aspectRatio.map { CGFloat($0.width) / CGFloat($0.height) } ?? (16/9)

    ZStack {
      RoundedRectangle(cornerRadius: 10)
        .fill(Color.gray.opacity(0.1))
        .frame(width: width, height: height)

      LazyImage(url: URL(string: viewImage.thumb.uriString())) { state in
        if let image = state.image {
          image
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: width, height: height)
            .blur(radius: isBlurred ? 30 : 0)
            .modifier(BlurOverlayModifier(isBlurred: isBlurred))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .matchedTransitionSource(id: viewImage.id, in: imageTransition) { source in
              source
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        } else if state.error != nil {
          Image(systemName: "photo")
            .aspectRatio(contentMode: .fit)
            .frame(width: width * 0.3, height: height * 0.3)
            .foregroundStyle(.secondary)
        } else {
          ProgressView()
            .scaleEffect(0.7)
        }
      }
      .pipeline(ImageLoadingManager.shared.pipeline)
      .priority(.high)
      .processors([
        ImageProcessors.AsyncImageDownscaling(targetSize: CGSize(width: width, height: height))
      ])
    }
    .frame(width: width, height: height)
    .onTapGesture {
      if shouldBlur {
        isBlurred.toggle()
      } else {
        if let index = viewImages.firstIndex(where: { $0.id == viewImage.id }) {
          // Set both currentIndex and selectedImage directly
//          logger.debug("🖱️ Image tapped: ID=\(viewImage.id), setting index to \(index)")
          currentIndex = index
          lastViewedIndex = index
          selectedImage = viewImage
          activeTransitionID = viewImage.id
        }
      }
    }
  }

  @ViewBuilder
  private func singleImageLayout(_ viewImage: AppBskyEmbedImages.ViewImage) -> some View {
    // Use a more consistent aspect ratio with maximum height to avoid large layout jumps
    let aspectRatio =
      viewImage.aspectRatio.map { CGFloat($0.width) / CGFloat($0.height) } ?? (16 / 9)
    let maxHeight: CGFloat = 800  // Maximum height for any image

    GeometryReader { geometry in
      let calculatedHeight = geometry.size.width / aspectRatio
      let height = min(calculatedHeight, maxHeight)  // Limit height

      ZStack {
        RoundedRectangle(cornerRadius: 10)
          .fill(Color.gray.opacity(0.1))
          .frame(maxWidth: .infinity)
          .frame(height: height)

        LazyImage(url: URL(string: viewImage.thumb.uriString())) { state in
          if let image = state.image {
            image
              .resizable()
              .aspectRatio(contentMode: .fill)
              .frame(maxWidth: .infinity)
              .frame(height: height)
              .blur(radius: isBlurred ? 30 : 0)
              .modifier(BlurOverlayModifier(isBlurred: isBlurred))
              .clipShape(RoundedRectangle(cornerRadius: 10))
              .contentShape(Rectangle())
              .matchedTransitionSource(id: viewImage.id, in: imageTransition) { source in
                source
                  .clipShape(RoundedRectangle(cornerRadius: 10))
              }
          } else if state.error != nil {
            Image(systemName: "photo")
              .aspectRatio(contentMode: .fit)
              .frame(width: geometry.size.width * 0.3, height: height * 0.3)
              .foregroundStyle(.secondary)
          } else {
            ProgressView()
              .scaleEffect(0.7)
          }
        }
        .pipeline(ImageLoadingManager.shared.pipeline)
        .priority(.high)
        .processors([
          ImageProcessors.AsyncImageDownscaling(targetSize: CGSize(width: geometry.size.width, height: height))
        ])
      }
      .frame(maxWidth: .infinity)
      .frame(height: height)
      .onTapGesture {
        if shouldBlur {
          isBlurred.toggle()
        } else {
//          logger.debug("🖱️ Single image tapped: ID=\(viewImage.id)")
          currentIndex = 0
          lastViewedIndex = 0
          selectedImage = viewImage
          activeTransitionID = viewImage.id
        }
      }
    }
    .aspectRatio(aspectRatio, contentMode: .fit)
  }

  @ViewBuilder
  private func twoImageLayout(geometry: GeometryProxy) -> some View {
    let columns = [
      GridItem(.flexible(), spacing: 3),
      GridItem(.flexible(), spacing: 3),
    ]

    LazyVGrid(columns: columns, spacing: 3) {
      ForEach(viewImages.prefix(2), id: \.id) { image in
        imageView(
          for: image,
          width: geometry.size.width / 2 - 1.5,
          height: geometry.size.height
        )
      }
    }
    .layoutPriority(1)
  }
  @ViewBuilder
  private func threeImageLayout(geometry: GeometryProxy) -> some View {
    // let leadingColumn = GridItem(.flexible(), spacing: 3)
    let trailingColumns = [
      GridItem(.flexible(), spacing: 3)
    ]

    HStack(spacing: 3) {
      // Leading large image
      imageView(
        for: viewImages[0],
        width: geometry.size.width / 2 - 1.5,
        height: geometry.size.height
      )

      // Trailing column of two images
      LazyVGrid(columns: trailingColumns, spacing: 3) {
        ForEach(viewImages.dropFirst().prefix(2), id: \.id) { image in
          imageView(
            for: image,
            width: geometry.size.width / 2 - 1.5,
            height: geometry.size.height / 2 - 1.5
          )
        }
      }
    }
    .layoutPriority(1)
  }

  @ViewBuilder
  private func fourImageLayout(geometry: GeometryProxy) -> some View {
    let columns = [
      GridItem(.flexible(), spacing: 3),
      GridItem(.flexible(), spacing: 3),
    ]

    LazyVGrid(columns: columns, spacing: 3) {
      ForEach(viewImages.prefix(4), id: \.id) { image in
        imageView(
          for: image,
          width: geometry.size.width / 2 - 1.5,
          height: geometry.size.height / 2 - 1.5
        )
      }
    }
    .layoutPriority(1)
  }
}

// MARK: - EnhancedImageViewer
struct EnhancedImageViewer: View {
  let images: [AppBskyEmbedImages.ViewImage]
  let initialImageId: String // Store the initial image ID
  @Binding var currentIndex: Int
  @Binding var isPresented: Bool
  var namespace: Namespace.ID
  @State private var showAltText = true
  @State private var isAltTextExpanded = false
  @State private var opacity: CGFloat = 1
  // Log for tracking state changes
  private let logger = Logger(subsystem: "com.catbird.app", category: "EnhancedImageViewer")

  init(images: [AppBskyEmbedImages.ViewImage], initialImageId: String, currentIndex: Binding<Int>, isPresented: Binding<Bool>, namespace: Namespace.ID) {
    self.images = images
    self.initialImageId = initialImageId
    self._currentIndex = currentIndex
    self._isPresented = isPresented
    self.namespace = namespace
    
    // Initialize with the correct index based on the initial image ID
    if let initialIndex = images.firstIndex(where: { $0.id == initialImageId }) {
//      logger.debug("⚙️ EnhancedImageViewer initialized with initialIndex: \(initialIndex) for image ID: \(initialImageId)")
    } else {
//      logger.debug("⚠️ EnhancedImageViewer could not find initial image ID: \(initialImageId)")
    }
  }

  var body: some View {
    ZStack {
      Color.black
        .opacity(opacity)
        .ignoresSafeArea()

      LazyPager(data: images, page: $currentIndex) { image in
        GeometryReader { geometry in
          LazyImage(url: URL(string: image.fullsize.uriString())) { state in
            if let fullImage = state.image {
              fullImage
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                .id(image.id) // Use the image ID for proper identification
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
          .priority(.high)
          .processors([
            ImageProcessors.AsyncImageDownscaling(targetSize: CGSize(width: geometry.size.width, height: geometry.size.height))
          ])
        }
      }
      .zoomable(min: 1.0, max: 3.0, doubleTapGesture: .scale(2.0))
      .onDismiss(backgroundOpacity: $opacity) {
//        logger.debug("🚪 LazyPager onDismiss called from gesture. currentIndex: \(currentIndex)")
        isPresented = false
      }
      .onTap {
        withAnimation {
          showAltText.toggle()
          if !showAltText {
            isAltTextExpanded = false
          }
        }
      }
      .settings { config in
        config.dismissVelocity = 1.5
        config.dismissTriggerOffset = 0.2
        config.dismissAnimationLength = 0.3
        config.fullFadeOnDragAt = 0.3
        config.pinchGestureEnableOffset = 15
        config.shouldCancelSwiftUIAnimationsOnDismiss = false
      }
      .id("pager-\(images.count)") // Add ID to ensure proper refresh
      .onChange(of: currentIndex) { oldValue, newValue in
//        logger.debug("🔄 LazyPager currentIndex changed: was \(oldValue), now \(newValue)")
      }

      overlayView
    }
    .background(Color.black)
    // Use a dynamic sourceID based on the current index
    .navigationTransition(.zoom(sourceID: images[currentIndex].id, in: namespace))
    .onChange(of: currentIndex) { oldValue, newValue in
//      logger.debug("🔄 EnhancedImageViewer currentIndex changed: was \(oldValue), now \(newValue), active image ID: \(images[newValue].id)")
    }
    .onAppear {
//      logger.debug("📱 EnhancedImageViewer appeared with index: \(currentIndex), image ID: \(images[currentIndex].id)")
    }
    .onDisappear {
//      logger.debug("🏁 EnhancedImageViewer disappeared with final index: \(currentIndex), image ID: \(images[currentIndex].id)")
    }
    .task {
      await prefetchFullSizeImages()
    }
  }

  private var overlayView: some View {
    VStack {
      HStack {
        Text("\(currentIndex + 1) of \(images.count)")
          .foregroundColor(.white)
          .padding(.leading)
        Spacer()
        Button(action: { 
          logger.debug("❌ Close button pressed. currentIndex: \(currentIndex)")
          isPresented = false 
        }) {
          Image(systemName: "xmark")
            .foregroundColor(.white)
            .font(.title3)
            .padding()
        }
      }
      .background(
        LinearGradient(
          colors: [.black.opacity(0.6), .clear],
          startPoint: .top,
          endPoint: .bottom
        )
      )
      .opacity(opacity)

      Spacer()

      if showAltText,
        !images[currentIndex].alt.isEmpty
      {
        altTextView
          .opacity(opacity)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
  }

  private var altTextView: some View {
    VStack(spacing: 4) {
      Text(images[currentIndex].alt)
        .font(.caption)
        .lineLimit(isAltTextExpanded ? nil : 2)
        .multilineTextAlignment(.leading)

      if !isAltTextExpanded {
        Button(action: {
          withAnimation(.easeInOut(duration: 0.2)) {
            isAltTextExpanded = true
          }
        }) {
          Text("Show More")
            .font(.caption2)
            .foregroundColor(Color.accentColor)
        }
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity)
    .background(Material.ultraThin)
    .cornerRadius(10)
    .padding(.horizontal)
    .padding(.bottom, 8)
    .onTapGesture {
      withAnimation(.easeInOut(duration: 0.2)) {
        isAltTextExpanded.toggle()
      }
    }
  }

  private func prefetchFullSizeImages() async {
    let urls = images.compactMap { URL(string: $0.fullsize.uriString()) }
    let manager = ImageLoadingManager.shared
    await manager.prefetchImages(urls: urls)
  }
}

// MARK: - View Modifiers
struct BlurOverlayModifier: ViewModifier {
  let isBlurred: Bool

  func body(content: Content) -> some View {
    content.overlay(
      Group {
        if isBlurred {
          Text("Sensitive Content")
            .foregroundColor(.white)
            .padding(6)
            .background(Color.black.opacity(0.7))
            .cornerRadius(10)
        }
      }
    )
  }
}

extension AppBskyEmbedImages.ViewImage: @retroactive Identifiable {
  public var id: String {
    fullsize.uriString()
  }
}
